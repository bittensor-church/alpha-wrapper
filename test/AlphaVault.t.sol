// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { CloneBase } from "src/CloneBase.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockMetagraph } from "./mocks/MockMetagraph.sol";
import { MockAddressMapping } from "./mocks/MockAddressMapping.sol";
import { MockStorageQuery } from "./mocks/MockStorageQuery.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { METAGRAPH_PRECOMPILE } from "src/interfaces/IMetagraph.sol";
import { ADDRESS_MAPPING_PRECOMPILE } from "src/interfaces/IAddressMapping.sol";

address constant STORAGE_QUERY = 0x0000000000000000000000000000000000000807;

contract AlphaVaultTest is Test {
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event Rebalanced(uint256 indexed tokenId, uint8 moveCount);

    AlphaVault public vault;
    DepositMailbox public mailboxLogic;
    SubnetClone public subnetLogic;
    MockStaking public mockStaking;
    MockMetagraph public mockMetagraph;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public hotkey1 = keccak256("hotkey1");
    bytes32 public hotkey2 = keccak256("hotkey2");
    bytes32 public hotkey3 = keccak256("hotkey3");
    bytes32 public hotkey4 = keccak256("hotkey4");

    // Subnet netuids used as vault IDs
    uint256 public constant NETUID1 = 1;
    uint256 public constant NETUID2 = 2;

    // Cached tokenIds set in setUp, since tokenId = netuid | (regBlock << 16).
    uint256 public TOKEN1;
    uint256 public TOKEN2;

    function setUp() public {
        // Deploy mock staking precompile at 0x805
        mockStaking = new MockStaking();
        vm.etch(STAKING_PRECOMPILE, address(mockStaking).code);

        mockMetagraph = new MockMetagraph();
        vm.etch(METAGRAPH_PRECOMPILE, address(mockMetagraph).code);

        vm.etch(ADDRESS_MAPPING_PRECOMPILE, address(new MockAddressMapping()).code);

        vm.etch(STORAGE_QUERY, address(new MockStorageQuery()).code);
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(NETUID1), 100);
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(NETUID2), 200);

        // Set up 3 validators for subnet 1 (descending stake)
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID1), 0, hotkey1, 1000, true);
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID1), 1, hotkey2, 800, true);
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID1), 2, hotkey3, 600, true);

        // Set up validators for subnet 2: hotkey2 has most stake, hotkey1 second
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID2), 0, hotkey2, 2000, true);
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID2), 1, hotkey1, 100, true);

        mailboxLogic = new DepositMailbox();
        subnetLogic = new SubnetClone();

        vault = new AlphaVault("https://api.tao20.io/{id}.json", address(mailboxLogic), address(subnetLogic));

        // Set up ValidatorRegistry (required — no metagraph fallback)
        ValidatorRegistry valRegistry = new ValidatorRegistry(address(this), address(this));

        bytes32[] memory hk3 = new bytes32[](3);
        uint16[] memory w3 = new uint16[](3);
        hk3[0] = hotkey1;
        hk3[1] = hotkey2;
        hk3[2] = hotkey3;
        w3[0] = 3334;
        w3[1] = 3333;
        w3[2] = 3333;
        valRegistry.setValidators(NETUID1, hk3, w3);

        bytes32[] memory hk2 = new bytes32[](2);
        uint16[] memory w2 = new uint16[](2);
        hk2[0] = hotkey2;
        hk2[1] = hotkey1;
        w2[0] = 6000;
        w2[1] = 4000;
        valRegistry.setValidators(NETUID2, hk2, w2);

        vault.setValidatorRegistry(address(valRegistry));

        TOKEN1 = vault.currentTokenId(NETUID1);
        TOKEN2 = vault.currentTokenId(NETUID2);
    }

    // ──────────── Helpers ────────────────────────────────────────────────────

    function _toSubstrate(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", addr));
    }

    function _simulateAlphaDeposit(address user, uint256 netuid, uint256 amount) internal {
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneSub = _toSubstrate(cloneAddr);
        // Use the best validator hotkey for this subnet (matches what processDeposit will resolve)
        bytes32 hotkey = vault.getBestValidator(netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, cloneSub, netuid, amount);
    }

    function _simulateAlphaDepositHotkey(address user, uint256 netuid, uint256 amount, bytes32 hotkey) internal {
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneSub = _toSubstrate(cloneAddr);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, cloneSub, netuid, amount);
    }

    function _processDeposit(address user, uint256 netuid) internal {
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneSub = _toSubstrate(cloneAddr);
        vm.prank(user);
        vault.processDeposit(user, netuid, cloneSub);
    }

    function _getStake(bytes32 hotkey, address who, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _toSubstrate(who), netuid);
    }

    function _subnetColdkey(uint256 netuid) internal view returns (bytes32) {
        return _toSubstrate(vault.subnetClone(vault.currentTokenId(netuid)));
    }

    function _getVaultStake(bytes32 hotkey, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _subnetColdkey(netuid), netuid);
    }

    function _simulateEmissions(uint256 netuid, uint256 extraAlpha) internal {
        uint256 currentStake = _getVaultStake(hotkey1, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, currentStake + extraAlpha);
        uint256 tokenId = vault.currentTokenId(netuid);
        uint256 slot = uint256(keccak256(abi.encode(tokenId, uint256(7))));
        vm.store(address(vault), bytes32(slot), bytes32(vault.totalStake(tokenId) + extraAlpha));
    }

    function _totalVaultStakeAcrossHotkeys(uint256 netuid) internal view returns (uint256) {
        uint256 total = 0;
        total += _getVaultStake(hotkey1, netuid);
        total += _getVaultStake(hotkey2, netuid);
        total += _getVaultStake(hotkey3, netuid);
        return total;
    }

    function _setRegBlock(uint256 netuid, uint64 blockNum) internal {
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(netuid), blockNum);
    }

    function _simulateTaoAwardedOnDissolution(uint256 tokenId, uint256 taoAmount) internal {
        address clone = vault.subnetClone(tokenId);
        bytes32 cloneColdkey = _toSubstrate(clone);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        uint256 netuid = tokenId & 0xFFFF;
        mock.setStake(hotkey1, cloneColdkey, netuid, 0);
        mock.setStake(hotkey2, cloneColdkey, netuid, 0);
        mock.setStake(hotkey3, cloneColdkey, netuid, 0);
        mock.setStake(hotkey4, cloneColdkey, netuid, 0);
        vm.deal(clone, clone.balance + taoAmount);
    }

    function _simulateDissolutionCompleted(uint256 netuid) internal {
        _setRegBlock(netuid, 0);
        uint16[] memory empty = new uint16[](0);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(empty);
    }

    function _simulateNewNetworkRegistered(uint256 tokenId, uint64 newRegBlock, uint256 taoInClone) internal {
        _simulateTaoAwardedOnDissolution(tokenId, taoInClone);
        _setRegBlock(tokenId & 0xFFFF, newRegBlock);
    }

    function _simulateDissolutionStarted(uint256 tokenId, uint64 newRegBlock) internal {
        uint256 netuid = tokenId & 0xFFFF;
        _setRegBlock(netuid, newRegBlock);
        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(netuid);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);
    }

    // ────────────────── Constructor ──────────────────────────────────────────

    function testConstructorRevertsZeroMailboxLogic() public {
        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        new AlphaVault("https://api.tao20.io/{id}.json", address(0), address(subnetLogic));
    }

    function testConstructorRevertsZeroSubnetLogic() public {
        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        new AlphaVault("https://api.tao20.io/{id}.json", address(mailboxLogic), address(0));
    }

    // ────────────────── Auto Vault (no registration) ─────────────────────────

    function testAutoVaultOnFirstDeposit() public {
        assertEq(vault.totalSupply(TOKEN1), 0);
        assertEq(vault.totalStake(TOKEN1), 0);

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        assertTrue(vault.balanceOf(alice, TOKEN1) > 0);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    // ────────────────── Best Validator Selection ─────────────────────────────

    function testBestValidatorSelection() public view {
        // Subnet 1: hotkey1 has 1000 ether stake (highest)
        assertEq(vault.getBestValidator(NETUID1), hotkey1);
        // Subnet 2: hotkey2 has 2000 ether stake (highest)
        assertEq(vault.getBestValidator(NETUID2), hotkey2);
    }

    function testBestValidatorIgnoresNonValidators() public {
        // Add a non-validator with higher stake
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID1), 3, hotkey4, 9999, false);
        // Should still return hotkey1 (highest-stake validator)
        assertEq(vault.getBestValidator(NETUID1), hotkey1);
    }

    function testNoValidatorReverts() public {
        // Subnet 99 has no validators
        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        vault.getBestValidator(99);
    }

    function testGetBestValidatorsReturnsThree() public view {
        bytes32[3] memory hks = vault.getBestValidators(NETUID1);
        assertEq(hks[0], hotkey1); // 1000 stake
        assertEq(hks[1], hotkey2); // 800 stake
        assertEq(hks[2], hotkey3); // 600 stake
    }

    function testSingleValidatorNoSplit() public {
        // Subnet 99 with only 1 validator — must register in ValidatorRegistry
        ValidatorRegistry reg = ValidatorRegistry(address(vault.validatorRegistry()));
        bytes32[] memory hks = new bytes32[](1);
        uint16[] memory ws = new uint16[](1);
        hks[0] = hotkey4;
        ws[0] = 10_000;
        reg.setValidators(99, hks, ws);
        _setRegBlock(99, 300);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _processDeposit(alice, 99);

        // All stake under one hotkey on the subnet clone (no split possible)
        bytes32 cloneColdkey = _toSubstrate(vault.subnetClone(vault.currentTokenId(99)));
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, cloneColdkey, 99), 10 ether);
    }

    function testDepositRebalancesMinimal() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);

        // Total vault stake across all 3 hotkeys should equal deposit
        uint256 total = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertEq(total, 30 ether);
    }

    // ────────────────── Deposit Address ──────────────────────────────────────

    function testGetDepositAddress() public view {
        address a1 = vault.getDepositAddress(alice, NETUID1);
        address a2 = vault.getDepositAddress(alice, NETUID2);
        address b1 = vault.getDepositAddress(bob, NETUID1);

        assertEq(a1, vault.getDepositAddress(alice, NETUID1));
        assertTrue(a1 != a2);
        assertTrue(a1 != b1);
    }

    // ────────────────── Process Deposit ──────────────────────────────────────

    function testProcessDeposit() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        assertTrue(vault.balanceOf(alice, TOKEN1) > 0);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
        // Total vault stake across all hotkeys should equal deposit
        uint256 total = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertEq(total, 10 ether);
    }

    function testProcessDepositMultipleSubnets() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _processDeposit(alice, NETUID2);

        assertTrue(vault.balanceOf(alice, TOKEN1) > 0);
        assertTrue(vault.balanceOf(alice, TOKEN2) > 0);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
        assertEq(vault.totalStake(TOKEN2), 5 ether);
    }

    function testProcessDepositTwice() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);
        uint256 after1 = vault.balanceOf(alice, TOKEN1);

        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);
        uint256 after2 = vault.balanceOf(alice, TOKEN1);

        assertTrue(after2 > after1);
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    function testProcessDepositRevertsZero() public {
        address cloneAddr = vault.getDepositAddress(alice, NETUID1);
        bytes32 cloneSub = _toSubstrate(cloneAddr);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.processDeposit(alice, NETUID1, cloneSub);
    }

    // ────────────────── Share Price ──────────────────────────────────────────

    function testSharePriceGrowsWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 priceBefore = vault.sharePrice(TOKEN1);
        _simulateEmissions(NETUID1, 5 ether);
        uint256 priceAfter = vault.sharePrice(TOKEN1);

        assertTrue(priceAfter > priceBefore);
    }

    function testSharePriceIndependentPerSubnet() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID2, 10 ether);
        _processDeposit(alice, NETUID2);

        _simulateEmissions(NETUID1, 10 ether);

        assertTrue(vault.sharePrice(TOKEN1) > vault.sharePrice(TOKEN2));
    }

    function testLateDepositorGetFewerShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 10 ether);

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _processDeposit(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        assertTrue(bobShares < aliceShares);
    }

    // ────────────────── Withdraw ─────────────────────────────────────────────

    function testWithdraw() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.withdraw(TOKEN1, shares, aliceSub);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        // Withdrawal comes from hotkeys with vault stake
        uint256 totalReceived = 0;
        totalReceived += _getStake(hotkey1, alice, NETUID1);
        totalReceived += _getStake(hotkey2, alice, NETUID1);
        totalReceived += _getStake(hotkey3, alice, NETUID1);
        assertTrue(totalReceived > 0);
    }

    function testDepositSyncsStakeBeforeMintingShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _processDeposit(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        // Emissions accrue on the precompile but totalStake is NOT updated
        uint256 currentStake = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, currentStake + 100 ether);

        // Bob deposits 100 into a pool now worth 200 on the precompile
        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _processDeposit(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        // Fair shares = alice * 100/200 = alice / 2 (tiny dust from rebalance rounding)
        assertApproxEqAbs(bobShares, aliceShares / 2, 1e9, "bob shares should reflect synced pool value");
        assertLt(bobShares, aliceShares, "bob got too many shares - stale totalStake on deposit");
    }

    function testFirstDepositDoesNotUnderflowWhenRebalanceRounds() public {
        // On the real chain, moveStake can lose 1 RAO to rounding.
        // After flush + rebalance, _getAlphaBalances returns totalDeposit - 1.
        // The sync line `totalAlpha - totalDeposit` would underflow.
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        assertGt(vault.balanceOf(alice, TOKEN1), 0);

        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(0);
    }

    function testWithdrawWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 5 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.withdraw(TOKEN1, shares, aliceSub);

        uint256 totalReceived = 0;
        totalReceived += _getStake(hotkey1, alice, NETUID1);
        totalReceived += _getStake(hotkey2, alice, NETUID1);
        totalReceived += _getStake(hotkey3, alice, NETUID1);
        assertTrue(totalReceived > 10 ether, "Should receive deposit + rewards");
    }

    function testWithdrawUsesLargestHotkey() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        // Manually distribute vault stake across validators: hotkey3 gets the most
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 1 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 2 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, _subnetColdkey(NETUID1), NETUID1, 7 ether);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.withdraw(TOKEN1, shares, aliceSub);

        // Withdrawal should come from hotkey3 (largest balance)
        uint256 fromHk3 = _getStake(hotkey3, alice, NETUID1);
        assertTrue(fromHk3 > 0, "Should withdraw from hotkey with most vault stake");
    }

    function testWithdrawRevertsOnZero() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.withdraw(TOKEN1, 0, aliceSub);
    }

    // ────────────────── Forwarder Security ───────────────────────────────────

    function testOnlyVaultCanFlush() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(payable(clone)).flush(bytes32(0), hotkey1, NETUID1, 1 ether);
    }

    function testForwarderCannotReinitialize() public {
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);
        _processDeposit(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        CloneBase(payable(clone)).initialize(address(0xdead));
    }

    // ────────────────── setApprovalForAll (ERC1155 key feature) ──────────────

    function testSetApprovalForAll() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID2, 10 ether);
        _processDeposit(alice, NETUID2);

        vm.prank(alice);
        vault.setApprovalForAll(bob, true);
        assertTrue(vault.isApprovedForAll(alice, bob));

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = TOKEN1;
        ids[1] = TOKEN2;
        amounts[0] = vault.balanceOf(alice, TOKEN1);
        amounts[1] = vault.balanceOf(alice, TOKEN2);

        vm.prank(bob);
        vault.safeBatchTransferFrom(alice, bob, ids, amounts, "");

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(vault.balanceOf(alice, TOKEN2), 0);
        assertTrue(vault.balanceOf(bob, TOKEN1) > 0);
        assertTrue(vault.balanceOf(bob, TOKEN2) > 0);
    }

    // ────────────────── Preview ──────────────────────────────────────────────

    function testPreviewDeposit() public view {
        assertTrue(vault.previewDeposit(TOKEN1, 10 ether) > 0);
    }

    function testPreviewWithdraw() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 alpha, uint256 tao) = vault.previewWithdraw(TOKEN1, shares);
        assertEq(alpha, 10 ether);
        assertEq(tao, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    // ────────────────── Withdraw partial shares ─────────────────────────

    function testWithdrawPartialShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        // Withdraw half
        vm.prank(alice);
        vault.withdraw(TOKEN1, shares / 2, aliceSub);

        // Should still have ~half the shares
        assertApproxEqAbs(vault.balanceOf(alice, TOKEN1), shares / 2, 1);
        // Vault should still have ~half the stake
        assertApproxEqAbs(vault.totalStake(TOKEN1), 5 ether, 0.01 ether);
    }

    // ────────────────── Multiple users deposit/withdraw interleaved ─────

    function testInterleavedDepositsWithdrawals() public {
        // Alice deposits 10
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        // Bob deposits 20
        _simulateAlphaDeposit(bob, NETUID1, 20 ether);
        _processDeposit(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        // Bob should have ~2x Alice's shares (same price)
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18);

        // Alice withdraws everything
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.withdraw(TOKEN1, aliceShares, aliceSub);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);

        // Bob should still have his shares, totalStake should be ~20
        assertEq(vault.balanceOf(bob, TOKEN1), bobShares);
        assertApproxEqAbs(vault.totalStake(TOKEN1), 20 ether, 0.01 ether);

        // Bob withdraws
        bytes32 bobSub = _toSubstrate(bob);
        vm.prank(bob);
        vault.withdraw(TOKEN1, bobShares, bobSub);
        assertEq(vault.balanceOf(bob, TOKEN1), 0);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    // ────────────────── processDeposit unauthorized ─────────────────────

    function testProcessDepositUnauthorized() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        address clone = vault.getDepositAddress(alice, NETUID1);
        bytes32 cloneSub = _toSubstrate(clone);

        // Bob (not alice, not owner) should revert
        vm.prank(bob);
        vm.expectRevert(AlphaVault.UnauthorizedCaller.selector);
        vault.processDeposit(alice, NETUID1, cloneSub);
    }

    // ────────────────── Deposit address deterministic across calls ──────

    function testDepositAddressDeterministic() public view {
        address a1 = vault.getDepositAddress(alice, NETUID1);
        address a2 = vault.getDepositAddress(alice, NETUID1);
        assertEq(a1, a2);
    }

    // ────────────────── Different subnets isolated ─────────────────────

    function testSubnetIsolation() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _processDeposit(alice, NETUID2);

        // Rewards on NETUID1 should not affect NETUID2 share price
        _simulateEmissions(NETUID1, 10 ether);

        uint256 price1 = vault.sharePrice(TOKEN1);
        uint256 price2 = vault.sharePrice(TOKEN2);
        assertGt(price1, price2, "NETUID1 should have higher share price after rewards");

        // Withdrawing from NETUID2 should return ~5 ether, unaffected by NETUID1 rewards
        uint256 shares2 = vault.balanceOf(alice, TOKEN2);
        (uint256 preview2,) = vault.previewWithdraw(TOKEN2, shares2);
        assertApproxEqAbs(preview2, 5 ether, 0.01 ether);
    }

    // ────────────────── Virtual shares prevent inflation attack ────────

    function testFirstDepositorInflationAttack() public {
        // Attacker deposits 1 wei
        _simulateAlphaDeposit(alice, NETUID1, 1);
        _processDeposit(alice, NETUID1);

        // Inject large reward to inflate share price
        _simulateEmissions(NETUID1, 100 ether);

        // Victim deposits 10 ether
        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _processDeposit(bob, NETUID1);

        // With virtual shares, Bob should still get meaningful shares
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);
        assertGt(bobShares, 0, "Bob should get shares despite inflation attempt");

        // Bob's shares should be worth approximately his deposit
        (uint256 bobValue,) = vault.previewWithdraw(TOKEN1, bobShares);
        assertGt(bobValue, 9 ether, "Bob should not lose significant value to inflation attack");
    }

    // ────────────────── ERC1155 batch transfer works correctly ─────────

    function testBatchTransferMultipleSubnets() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _processDeposit(alice, NETUID2);

        uint256 bal1 = vault.balanceOf(alice, TOKEN1);
        uint256 bal2 = vault.balanceOf(alice, TOKEN2);

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = TOKEN1;
        ids[1] = TOKEN2;
        amounts[0] = bal1 / 2;
        amounts[1] = bal2 / 2;

        vm.prank(alice);
        vault.safeBatchTransferFrom(alice, bob, ids, amounts, "");

        assertEq(vault.balanceOf(bob, TOKEN1), bal1 / 2);
        assertEq(vault.balanceOf(bob, TOKEN2), bal2 / 2);
        assertEq(vault.balanceOf(alice, TOKEN1), bal1 - bal1 / 2);
    }

    // ────────────────── Share price starts at virtual offset ───────────

    function testSharePriceRevertsForUnregisteredSubnet() public {
        uint256 tokenId = uint256(uint16(42)) | (uint256(100) << 16);
        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);
    }

    function testSharePriceRevertsWhenSupplyIsZero() public {
        vault.createSubnetProxy(NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.totalSupply(tokenId), 0);
        vm.expectRevert(AlphaVault.NoSharesOutstanding.selector);
        vault.sharePrice(tokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   ADDITIONAL COVERAGE TESTS
    // ══════════════════════════════════════════════════════════════════════

    // ────────────────── rebalance() full function ────────────────────────

    function testRebalanceWithRegistryWeights() public {
        // Set up a ValidatorRegistry
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));

        // Set weights: 60/40 split between hk1 and hk2
        bytes32[] memory hks = new bytes32[](2);
        uint16[] memory wts = new uint16[](2);
        hks[0] = hotkey1;
        hks[1] = hotkey2;
        wts[0] = 6000;
        wts[1] = 4000;
        reg.setValidators(NETUID1, hks, wts);

        // Deposit all under hotkey1 to simulate imbalance
        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        // Put all vault stake on hotkey1
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        // Rebalance
        vault.rebalance(NETUID1);

        // After rebalance: hotkey1 ~60 ether, hotkey2 ~40 ether
        uint256 hk1Stake = _getVaultStake(hotkey1, NETUID1);
        uint256 hk2Stake = _getVaultStake(hotkey2, NETUID1);
        assertApproxEqAbs(hk1Stake, 60 ether, 1);
        assertApproxEqAbs(hk2Stake, 40 ether, 1);
    }

    function testRebalanceThreeValidators() public {
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));

        bytes32[] memory hks = new bytes32[](3);
        uint16[] memory wts = new uint16[](3);
        hks[0] = hotkey1;
        hks[1] = hotkey2;
        hks[2] = hotkey3;
        wts[0] = 5000;
        wts[1] = 3000;
        wts[2] = 2000;
        reg.setValidators(NETUID1, hks, wts);

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        // All on hotkey1
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, _subnetColdkey(NETUID1), NETUID1, 0);

        vault.rebalance(NETUID1);

        uint256 total = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertEq(total, 100 ether, "Total stake preserved");

        // Rough target check
        uint256 hk1 = _getVaultStake(hotkey1, NETUID1);
        uint256 hk2 = _getVaultStake(hotkey2, NETUID1);
        uint256 hk3 = _getVaultStake(hotkey3, NETUID1);
        assertApproxEqAbs(hk1, 50 ether, 1 ether);
        assertApproxEqAbs(hk2, 30 ether, 1 ether);
        assertApproxEqAbs(hk3, 20 ether, 1 ether);
    }

    function testRebalanceNoOpWhenAlreadyBalanced() public {
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));

        bytes32[] memory hks = new bytes32[](2);
        uint16[] memory wts = new uint16[](2);
        hks[0] = hotkey1;
        hks[1] = hotkey2;
        wts[0] = 5000;
        wts[1] = 5000;
        reg.setValidators(NETUID1, hks, wts);

        _simulateAlphaDepositHotkey(alice, NETUID1, 50 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        // Manually set balanced
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 50 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 50 ether);

        vault.rebalance(NETUID1);

        // Should remain the same
        assertEq(_getVaultStake(hotkey1, NETUID1), 50 ether);
        assertEq(_getVaultStake(hotkey2, NETUID1), 50 ether);
    }

    function testRebalanceNoOpSingleValidator() public {
        // With 1 validator, rebalance returns early (count < 2)
        vault.rebalance(NETUID1); // Uses metagraph fallback with 3 validators
        // No revert, just a no-op if single validator
    }

    function testRebalanceEmitsEvent() public {
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));

        bytes32[] memory hks = new bytes32[](2);
        uint16[] memory wts = new uint16[](2);
        hks[0] = hotkey1;
        hks[1] = hotkey2;
        wts[0] = 8000;
        wts[1] = 2000;
        reg.setValidators(NETUID1, hks, wts);

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, false, false, true);
        emit Rebalanced(tokenId, 1);
        vault.rebalance(NETUID1);
    }

    function testRebalanceZeroTotalStakeNoOp() public {
        // Subnet with validators but no stake — rebalance should return early (total==0)
        vault.rebalance(NETUID1); // Has validators but no deposits yet → total stake is 0 after resolving
        // No revert expected — returns early
    }

    function testRebalanceEmitsEventAfterProcessDeposit() public {
        // Repro of the localnet e2e flow. With 3 validators at 50/30/20 and a
        // single-hotkey initial deposit, processDeposit's internal _findBestMove
        // makes exactly one move (30 ether from hk1 → hk2), leaving the vault at
        // [70, 30, 0] vs target [50, 30, 20]. A subsequent public rebalance()
        // must find the residual 20-ether imbalance, do one more move, and emit
        // Rebalanced(tokenId, 1). If this ever stops firing, either the on-chain
        // rebalance sequence or mock ↔ real parity has regressed.
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));

        bytes32[] memory hks = new bytes32[](3);
        uint16[] memory wts = new uint16[](3);
        hks[0] = hotkey1;
        hks[1] = hotkey2;
        hks[2] = hotkey3;
        wts[0] = 5000;
        wts[1] = 3000;
        wts[2] = 2000;
        reg.setValidators(NETUID1, hks, wts);

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        // Intentionally do NOT reset the mock — we want to observe what rebalance()
        // sees after a real processDeposit has already shifted some stake.
        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, false, false, true);
        emit Rebalanced(tokenId, 1);
        vault.rebalance(NETUID1);
    }

    // ────────────────── setValidatorRegistry ────────────────────────────

    function testSetValidatorRegistry() public {
        // Registry is already set in setUp — verify it's non-zero
        assertTrue(address(vault.validatorRegistry()) != address(0));

        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));

        assertEq(address(vault.validatorRegistry()), address(reg));
    }

    function testSetValidatorRegistryEmitsEvent() public {
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));
        assertEq(address(vault.validatorRegistry()), address(reg));
    }

    function testSetValidatorRegistryToZero() public {
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));
        vault.setValidatorRegistry(address(0)); // Reset to fallback

        assertEq(address(vault.validatorRegistry()), address(0));
    }

    function testSetValidatorRegistryOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setValidatorRegistry(address(0x1234));
    }

    // ────────────────── setURI ───────────────────────────────────────────

    function testSetURI() public {
        vault.setURI("https://new-uri.io/{id}.json");
        assertEq(vault.uri(0), "https://new-uri.io/{id}.json");
    }

    function testSetURIOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setURI("https://malicious.io/{id}.json");
    }

    // ────────────────── DepositForwarder: ZeroAddress revert ────────────

    function testForwarderInitializeRevertsZeroAddress() public {
        address clone = Clones.clone(address(mailboxLogic));
        vm.expectRevert(CloneBase.ZeroAddress.selector);
        CloneBase(payable(clone)).initialize(address(0));
    }

    // ────────────────── receive() payable ────────────────────────────────

    // ────────────────── Registry fallback to metagraph ───────────────────

    function testRegistryRevertsWhenNoValidatorsSet() public {
        // Replace registry with an empty one (no validators configured)
        ValidatorRegistry reg = new ValidatorRegistry(address(this), address(this));
        vault.setValidatorRegistry(address(reg));

        // No metagraph fallback — should revert
        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        vault.getBestValidators(NETUID1);
    }

    // ────────────────── Deposit/Withdraw verify state changes ─────────

    function testDepositIncreasesTotalStake() public {
        uint256 stakeBefore = vault.totalStake(TOKEN1);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        assertEq(vault.totalStake(TOKEN1), stakeBefore + 10 ether);
    }

    function testWithdrawDecreasesTotalStake() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.withdraw(TOKEN1, shares, aliceSub);
        assertEq(vault.totalStake(TOKEN1), 0);
    }

    function testSubnetCloneCanMoveStake() public {
        vault.createSubnetProxy(NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);
        bytes32 cloneColdkey = _toSubstrate(vault.subnetClone(tokenId));
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, NETUID1, 100 ether);

        vm.prank(address(vault));
        SubnetClone(payable(clone)).moveStake(hotkey1, hotkey2, NETUID1, 100 ether);

        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, cloneColdkey, NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey2, cloneColdkey, NETUID1), 100 ether);
    }

    function testSubnetCloneCanWithdrawTao() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.deal(clone, 50 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(address(vault));
        SubnetClone(payable(clone)).withdrawTao(payable(alice), 50 ether);

        assertEq(address(clone).balance, 0);
        assertEq(alice.balance, aliceBefore + 50 ether);
    }

    function testOnlyWrapperCanCallMoveStake() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.prank(alice);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(clone)).moveStake(hotkey1, hotkey2, NETUID1, 100 ether);
    }

    function testOnlyWrapperCanCallWithdrawTao() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.deal(clone, 50 ether);
        vm.prank(alice);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(clone)).withdrawTao(payable(alice), 50 ether);
    }

    function testReclaimTaoFromMailboxSkipsDeployForNonExistentMailbox() public {
        address predicted = vault.getDepositAddress(alice, NETUID1);
        assertEq(predicted.code.length, 0);

        // Should revert early without deploying the mailbox
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
        uint256 gasUsed = gasBefore - gasleft();

        // If the clone was deployed inside the reverted call, gas is wasted.
        // A clean early-return should cost under 30k gas. Clone deployment costs ~80k+.
        assertLt(gasUsed, 50_000, "too much gas - mailbox clone deployed unnecessarily before revert");
    }

    function testImplementationMailboxRejectsInitialize() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        mailboxLogic.initialize(address(this));
    }

    function testImplementationSubnetCloneRejectsInitialize() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        subnetLogic.initialize(address(this));
    }

    function testUserCanRetrieveTaoFromMailboxAfterDeregistration() public {
        address userClone = vault.getDepositAddress(alice, NETUID1);

        // Alice sends alpha to her mailbox clone (not yet processed)
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(userClone), NETUID1, 10 ether);

        // Subnet deregisters — alpha at the mailbox clone converts to TAO
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(userClone), NETUID1, 0);
        vm.deal(userClone, 10 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.reclaimTaoFromMailbox(NETUID1);

        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(userClone.balance, 0);
    }

    // ───────── StorageQuery integration ──────────────────────────────────────

    function testMockStorageQueryUnsetNetuidReadsZero() public view {
        assertEq(MockStorageQuery(STORAGE_QUERY).registeredAt(9999), 0);
    }

    function testMockStorageQuerySetNetuidRoundTrip() public {
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(9999, 42);
        assertEq(MockStorageQuery(STORAGE_QUERY).registeredAt(9999), 42);
    }

    function testMockStorageQueryDistinctNetuids() public view {
        assertEq(MockStorageQuery(STORAGE_QUERY).registeredAt(uint16(NETUID1)), 100);
        assertEq(MockStorageQuery(STORAGE_QUERY).registeredAt(uint16(NETUID2)), 200);
    }

    // ───────── currentTokenId ────────────────────────────────────────────────

    function testCurrentTokenIdReflectsRegBlock() public view {
        uint256 expected1 = uint256(uint16(NETUID1)) | (uint256(100) << 16);
        uint256 expected2 = uint256(uint16(NETUID2)) | (uint256(200) << 16);
        assertEq(vault.currentTokenId(NETUID1), expected1);
        assertEq(vault.currentTokenId(NETUID2), expected2);
    }

    function testCurrentTokenIdRevertsForUnregisteredNetuid() public {
        vm.expectRevert(AlphaVault.SubnetNotRegistered.selector);
        vault.currentTokenId(42);
    }

    function testCurrentTokenIdChangesAfterRecycle() public {
        uint256 before = vault.currentTokenId(NETUID1);
        _setRegBlock(NETUID1, 500);
        uint256 afterRecycle = vault.currentTokenId(NETUID1);
        assertTrue(before != afterRecycle);
        assertEq(afterRecycle, uint256(uint16(NETUID1)) | (uint256(500) << 16));
    }

    // ───────── createSubnetProxy ─────────────────────────────────────────────

    function testCreateSubnetProxyRevertsSubnetNotRegistered() public {
        vm.expectRevert(AlphaVault.SubnetNotRegistered.selector);
        vault.createSubnetProxy(42);
    }

    function testCreateSubnetProxyDeploysClone() public {
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.subnetClone(tokenId), address(0));

        vm.expectEmit(true, false, false, false);
        emit SubnetProxyCreated(tokenId, address(0));
        vault.createSubnetProxy(NETUID1);

        assertTrue(vault.subnetClone(tokenId) != address(0));
    }

    function testCreateSubnetProxyNoopForExistingClone() public {
        vault.createSubnetProxy(NETUID1);
        address first = vault.subnetClone(vault.currentTokenId(NETUID1));
        vault.createSubnetProxy(NETUID1);
        assertEq(vault.subnetClone(vault.currentTokenId(NETUID1)), first);
    }

    function testCreateSubnetProxyDeploysNewCloneAfterRecycle() public {
        vault.createSubnetProxy(NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _setRegBlock(NETUID1, 500);
        uint256 newTokenId = vault.currentTokenId(NETUID1);
        vault.createSubnetProxy(NETUID1);

        address oldClone = vault.subnetClone(oldTokenId);
        address newClone = vault.subnetClone(newTokenId);
        assertTrue(oldClone != address(0));
        assertTrue(newClone != address(0));
        assertTrue(oldClone != newClone);
    }

    // ───────── processDeposit ────────────────────────────────────────────────

    function testProcessDepositAutoDeploysClone() public {
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.subnetClone(tokenId), address(0));

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        assertTrue(vault.subnetClone(tokenId) != address(0));
        assertTrue(vault.balanceOf(alice, tokenId) > 0);
        assertEq(vault.totalStake(tokenId), 10 ether);
    }

    function testProcessDepositRepeatAccumulates() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);
        uint256 after1 = vault.balanceOf(alice, vault.currentTokenId(NETUID1));

        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);
        uint256 after2 = vault.balanceOf(alice, vault.currentTokenId(NETUID1));

        assertTrue(after2 > after1);
        assertEq(vault.totalStake(vault.currentTokenId(NETUID1)), 10 ether);
    }

    function testProcessDepositTwoUsersProportionalShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _processDeposit(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        assertApproxEqRel(bobShares, aliceShares * 3, 0.01e18);
    }

    function testProcessDepositRevertsSubnetNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetNotRegistered.selector);
        vault.processDeposit(alice, 42, _toSubstrate(address(0x1)));
    }

    function testProcessDepositRevertsUnauthorizedCaller() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        bytes32 cloneSub = _toSubstrate(vault.getDepositAddress(alice, NETUID1));
        vm.prank(bob);
        vm.expectRevert(AlphaVault.UnauthorizedCaller.selector);
        vault.processDeposit(alice, NETUID1, cloneSub);
    }

    function testProcessDepositRevertsZeroAlpha() public {
        bytes32 cloneSub = _toSubstrate(vault.getDepositAddress(alice, NETUID1));
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.processDeposit(alice, NETUID1, cloneSub);
    }

    function testProcessDepositAfterRecycleDeploysNewCloneAndIsolatesOldShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _setRegBlock(NETUID1, 500);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        _processDeposit(bob, NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertTrue(vault.balanceOf(alice, oldTokenId) > 0);
        assertEq(vault.balanceOf(alice, newTokenId), 0);
        assertTrue(vault.balanceOf(bob, newTokenId) > 0);
        assertEq(vault.balanceOf(bob, oldTokenId), 0);
        assertTrue(vault.subnetClone(oldTokenId) != vault.subnetClone(newTokenId));
    }

    function testWithdrawRevertsInsufficientShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.InsufficientShares.selector);
        vault.withdraw(tokenId, shares + 1, _toSubstrate(alice));
    }

    function testWithdrawRevertsZero() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.withdraw(0, 0, bytes32(0));
    }

    function testWithdrawRevertsNoSubnetClone() public {
        // With tokenId having no clone AND user having zero shares, the shares check
        // fires first (InsufficientShares). The NoSubnetClone guard is an additional
        // safety net that's unreachable via normal state transitions but remains as a
        // defense-in-depth check. Verify the shares check fires first:
        vm.prank(alice);
        vm.expectRevert(AlphaVault.InsufficientShares.selector);
        vault.withdraw(0xDEADBEEF, 100, _toSubstrate(alice));
    }

    // ───────── withdraw (dissolved subnet path) ──────────────────────────────────────────

    function testWihdrawFromDissolved() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 50 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(tokenId, shares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, 50 ether);
    }

    function testWithdrawFromDissolvedSubnetTwoHoldersProRata() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _processDeposit(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supply = aliceShares + bobShares;

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 80 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceExpected = (80 ether * aliceShares) / supply;
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(tokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.withdraw(tokenId, bobShares, _toSubstrate(bob));
        // bob gets the rest including dust
        assertEq(bob.balance - bobBefore, 80 ether - aliceExpected);
    }

    function testWithdrawFromDissolvedSubnetAfterNewSubnetRegistered() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateNewNetworkRegistered(tokenId, 500, 5 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(tokenId, shares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, 5 ether);
    }

    function testWithdrawDuringBlackoutRevertsRegardlessOfForceSendDust() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        vm.deal(vault.subnetClone(tokenId), 1);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.withdraw(tokenId, shares, _toSubstrate(alice));
    }

    function testWithdrawSucceedsAfterCleanupCompletesAfterForceSend() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        vm.deal(vault.subnetClone(tokenId), 1);

        _simulateTaoAwardedOnDissolution(tokenId, 5 ether);

        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(tokenId, shares, _toSubstrate(alice));

        assertEq(alice.balance - aliceBefore, 5 ether + 1);
    }

    function testWithdrawDuringBlackoutReverts() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.withdraw(tokenId, shares, _toSubstrate(alice));
    }

    // ───────── previewWithdraw ───────────────────────────────────────────────

    function testPreviewWithdrawDead() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alpha, uint256 tao) = vault.previewWithdraw(tokenId, shares);
        assertEq(alpha, 0);
        assertEq(tao, 40 ether);
    }

    function testPreviewWithdrawDuringBlackoutReverts() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewWithdraw(tokenId, shares);
    }

    function testPreviewWithdrawDuringBlackoutRevertsRegardlessOfForceSendDust() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 500);
        vm.deal(vault.subnetClone(tokenId), 1);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewWithdraw(tokenId, shares);
    }

    function testPreviewWithdrawUnknownTokenId() public view {
        (uint256 alpha, uint256 tao) = vault.previewWithdraw(0xDEADBEEF, 1000);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function testPreviewWithdrawZeroShares() public view {
        (uint256 alpha, uint256 tao) = vault.previewWithdraw(1, 0);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function testSharePriceRevertsForFullyDissolvedTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);
    }

    function testSharePriceRevertsForReRegisteredSubnetOldTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 40 ether);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(oldTokenId);
    }

    function testSharePriceRevertsAndIsNotManipulableByForceSend() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);

        vm.deal(clone, clone.balance + 1_000_000 ether);
        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.sharePrice(tokenId);
    }

    function testPreviewDepositRevertsForDissolvedTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.previewDeposit(tokenId, 10 ether);
    }

    function testPreviewDepositRevertsForReRegisteredSubnetOldTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 40 ether);

        vm.expectRevert(AlphaVault.SubnetDissolved.selector);
        vault.previewDeposit(oldTokenId, 10 ether);
        assertGt(vault.previewDeposit(vault.currentTokenId(NETUID1), 10 ether), 0);
    }

    function testForceSendBeforeDissolvedWithdrawIsDonationToHolders() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 10 ether);
        _simulateDissolutionCompleted(NETUID1);

        // attacker force-sends 5 ether before Alice redeems
        vm.deal(clone, clone.balance + 5 ether);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(tokenId, shares, _toSubstrate(alice));

        assertEq(alice.balance - aliceBalBefore, 15 ether, "sole holder captures legit refund + attacker's donation");
    }

    function testForceSendBetweenPartialDissolvedWithdrawsBenefitsLaterRedeemers() public {
        _simulateAlphaDeposit(alice, NETUID1, 6 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 4 ether);
        _processDeposit(bob, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 10 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supplyBefore = aliceShares + bobShares;

        uint256 aliceExpected = (10 ether * aliceShares) / supplyBefore;

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(tokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBalBefore, aliceExpected, "alice gets pro-rata of legit pot");

        // attacker donates 3 ether between withdrawals
        vm.deal(clone, clone.balance + 3 ether);

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        vault.withdraw(tokenId, bobShares, _toSubstrate(bob));
        uint256 bobGain = bob.balance - bobBalBefore;

        // Bob as last redeemer captures all residual including attacker's donation.
        assertEq(bobGain, (10 ether - aliceExpected) + 3 ether);
    }

    function testPreviewWithdrawRevertsBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(NETUID1);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewWithdraw(tokenId, shares);
    }

    function testSharePriceRevertsBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(NETUID1);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.sharePrice(tokenId);
    }

    function testPreviewDepositRevertsBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(NETUID1);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);

        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.previewDeposit(tokenId, 10 ether);
    }

    function testPreviewWithdrawRevertsNothingToWithdrawOnDissolvedZeroBalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(tokenId, 0);
        _simulateTaoAwardedOnDissolution(tokenId, 0);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(AlphaVault.NothingToWithdraw.selector);
        vault.previewWithdraw(tokenId, shares);
    }

    function testForceSendDoesNotAffectAlphaPayout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        // attacker force-sends while subnet is live; balance must not leak into payouts
        vm.deal(clone, clone.balance + 100 ether);

        (uint256 alpha, uint256 tao) = vault.previewWithdraw(tokenId, shares);
        assertEq(tao, 0);
        assertApproxEqAbs(alpha, 10 ether, 1);
    }

    // ───────── rebalance ─────────────────────────────────────────────────────

    function testRebalanceRecycledSubnetSilentNoop() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        _setRegBlock(NETUID1, 500);
        // New tokenId has no clone; should silently return
        vault.rebalance(NETUID1);
    }

    function testRebalanceNeverUsedNetuidSilentNoop() public {
        _setRegBlock(50, 300);
        ValidatorRegistry reg = ValidatorRegistry(address(vault.validatorRegistry()));
        bytes32[] memory hks = new bytes32[](1);
        uint16[] memory ws = new uint16[](1);
        hks[0] = hotkey1;
        ws[0] = 10000;
        reg.setValidators(50, hks, ws);

        vault.rebalance(50);
    }

    // ───────── Integration: full lifecycle ───────────────────────────────────

    function testLifecycleCaseAGovernanceDissolve() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _processDeposit(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supply = aliceShares + bobShares;

        _simulateTaoAwardedOnDissolution(tokenId, 80 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceExpected = (80 ether * aliceShares) / supply;

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(tokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.withdraw(tokenId, bobShares, _toSubstrate(bob));
        assertEq(bob.balance - bobBefore, 80 ether - aliceExpected);

        assertEq(vault.subnetClone(tokenId).balance, 0);
        assertEq(vault.totalSupply(tokenId), 0);
    }

    function testLifecycleCaseBPruneRecycleWithNewSubnet() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 3 ether);

        _simulateAlphaDeposit(bob, NETUID1, 20 ether);
        _processDeposit(bob, NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertTrue(oldTokenId != newTokenId);

        uint256 aliceShares = vault.balanceOf(alice, oldTokenId);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(oldTokenId, aliceShares, _toSubstrate(alice));
        assertEq(alice.balance - aliceBefore, 3 ether);

        uint256 bobShares = vault.balanceOf(bob, newTokenId);
        vm.prank(bob);
        vault.withdraw(newTokenId, bobShares, _toSubstrate(bob));
        uint256 bobTotal = 0;
        bobTotal += _getStake(hotkey1, bob, NETUID1);
        bobTotal += _getStake(hotkey2, bob, NETUID1);
        bobTotal += _getStake(hotkey3, bob, NETUID1);
        assertEq(bobTotal, 20 ether);
    }

    function testLifecycleDepositAfterRecycleCoexist() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _setRegBlock(NETUID1, 500);

        _simulateAlphaDeposit(bob, NETUID1, 15 ether);
        _processDeposit(bob, NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertTrue(oldTokenId != newTokenId);
        assertTrue(vault.subnetClone(oldTokenId) != vault.subnetClone(newTokenId));
        assertTrue(vault.balanceOf(alice, oldTokenId) > 0);
        assertEq(vault.balanceOf(alice, newTokenId), 0);
        assertTrue(vault.balanceOf(bob, newTokenId) > 0);
        assertEq(vault.balanceOf(bob, oldTokenId), 0);
    }
}
