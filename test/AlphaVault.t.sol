// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { CloneBase } from "src/CloneBase.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockAddressMapping } from "./mocks/MockAddressMapping.sol";
import { MockStorageQuery } from "./mocks/MockStorageQuery.sol";
import { MockValidatorRegistry } from "./mocks/MockValidatorRegistry.sol";
import { AttestationHelper } from "./helpers/AttestationHelper.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { ADDRESS_MAPPING_PRECOMPILE } from "src/interfaces/IAddressMapping.sol";

address constant STORAGE_QUERY = 0x0000000000000000000000000000000000000807;

contract AlphaVaultTest is AttestationHelper {
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event Rebalanced(uint256 indexed tokenId, bytes32 fromHotkey, bytes32 toHotkey, uint256 amount);
    event MinRebalanceAmtUpdated(uint256 oldValue, uint256 newValue);
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares, bytes32 hotkey);

    AlphaVault public vault;
    DepositMailbox public mailboxLogic;
    SubnetClone public subnetLogic;
    ValidatorRegistry public registry;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public hotkey1 = keccak256("hotkey1");
    bytes32 public hotkey2 = keccak256("hotkey2");
    bytes32 public hotkey3 = keccak256("hotkey3");
    bytes32 public hotkey4 = keccak256("hotkey4");

    uint256 internal constant SIGNER_PK_1 = 0xA11CE;
    uint256 internal constant SIGNER_PK_2 = 0xB0B;
    uint256[] internal signerPks;

    uint256 public constant NETUID1 = 1;
    uint256 public constant NETUID2 = 2;

    uint256 public TOKEN1;
    uint256 public TOKEN2;

    function setUp() public {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        vm.etch(ADDRESS_MAPPING_PRECOMPILE, address(new MockAddressMapping()).code);
        vm.etch(STORAGE_QUERY, address(new MockStorageQuery()).code);
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(NETUID1), 100);
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(NETUID2), 200);

        mailboxLogic = new DepositMailbox();
        subnetLogic = new SubnetClone();
        vault = new AlphaVault("https://api.tao20.io/{id}.json", address(mailboxLogic), address(subnetLogic));

        // vm.addr(SIGNER_PK_2) < vm.addr(SIGNER_PK_1); the registry requires sigs sorted
        // ascending by recovered address, so attestations sign in this order.
        signerPks.push(SIGNER_PK_2);
        signerPks.push(SIGNER_PK_1);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(signerPks[0]);
        signers[1] = vm.addr(signerPks[1]);
        registry = new ValidatorRegistry(address(this), signers, 2);
        vault.setValidatorRegistry(address(registry));

        _setValidators(NETUID1, _hks3(hotkey1, hotkey2, hotkey3), _wts3(3334, 3333, 3333));
        _setValidators(NETUID2, _hks2(hotkey2, hotkey1), _wts2(6000, 4000));

        TOKEN1 = vault.currentTokenId(NETUID1);
        TOKEN2 = vault.currentTokenId(NETUID2);
    }

    function _setValidators(uint256 netuid, bytes32[] memory hks, uint16[] memory wts) internal {
        _submitAttestation(registry, netuid, hks, wts, signerPks);
    }

    function _hks2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory hks) {
        hks = new bytes32[](2);
        hks[0] = a;
        hks[1] = b;
    }

    function _hks3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory hks) {
        hks = new bytes32[](3);
        hks[0] = a;
        hks[1] = b;
        hks[2] = c;
    }

    function _wts2(uint16 a, uint16 b) internal pure returns (uint16[] memory wts) {
        wts = new uint16[](2);
        wts[0] = a;
        wts[1] = b;
    }

    function _wts3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory wts) {
        wts = new uint16[](3);
        wts[0] = a;
        wts[1] = b;
        wts[2] = c;
    }

    function _hks1(bytes32 a) internal pure returns (bytes32[] memory hks) {
        hks = new bytes32[](1);
        hks[0] = a;
    }

    function _wts1(uint16 a) internal pure returns (uint16[] memory wts) {
        wts = new uint16[](1);
        wts[0] = a;
    }

    function _countRebalancedLogs(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 sig = keccak256("Rebalanced(uint256,bytes32,bytes32,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) count++;
        }
    }

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
        _processDepositHotkey(user, netuid, vault.getBestValidator(netuid));
    }

    function _processDepositHotkey(address user, uint256 netuid, bytes32 chosenHotkey) internal {
        vm.prank(user);
        vault.processDeposit(user, netuid, chosenHotkey);
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

    // ────────────────── Best Validator Selection ─────────────────────────────

    function testBestValidatorSelection() public view {
        assertEq(vault.getBestValidator(NETUID1), hotkey1);
        assertEq(vault.getBestValidator(NETUID2), hotkey2);
    }

    function testNoValidatorReverts() public {
        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        vault.getBestValidator(99);
    }

    function testGetBestValidatorsReturnsThree() public view {
        bytes32[3] memory hks = vault.getBestValidators(NETUID1);
        assertEq(hks[0], hotkey1);
        assertEq(hks[1], hotkey2);
        assertEq(hks[2], hotkey3);
    }

    function testSingleValidatorNoSplit() public {
        _setValidators(99, _hks1(hotkey4), _wts1(10_000));
        _setRegBlock(99, 300);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _processDeposit(alice, 99);

        bytes32 cloneColdkey = _toSubstrate(vault.subnetClone(vault.currentTokenId(99)));
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, cloneColdkey, 99), 10 ether);
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
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.processDeposit(alice, NETUID1, hotkey1);
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
        // moveStake can lose 1 RAO to rounding on the real chain; the post-deposit accounting
        // must clamp instead of underflowing when in-set balances sum below the deposited amount.
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

    // ────────────────── Mailbox Security ─────────────────────────────────────

    function testOnlyVaultCanFlush() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(payable(clone)).flush(bytes32(0), hotkey1, NETUID1, 1 ether);
    }

    function testMailboxCannotReinitialize() public {
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

        // Bob (not alice, not owner) should revert
        vm.prank(bob);
        vm.expectRevert(AlphaVault.UnauthorizedCaller.selector);
        vault.processDeposit(alice, NETUID1, hotkey1);
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
        // Smallest D under default weights [3334, 3333, 3333] and minRebalanceAmt = 2e6
        // where every per-slot move (D * 3333 / 10000) clears the floor: D ≥ 6_001_801.
        _simulateAlphaDeposit(alice, NETUID1, 6_001_802);
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
        _setValidators(NETUID1, _hks2(hotkey1, hotkey2), _wts2(6000, 4000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(_getVaultStake(hotkey1, NETUID1), 60 ether, 1);
        assertApproxEqAbs(_getVaultStake(hotkey2, NETUID1), 40 ether, 1);
    }

    function testRebalanceThreeValidators() public {
        _setValidators(NETUID1, _hks3(hotkey1, hotkey2, hotkey3), _wts3(5000, 3000, 2000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, _subnetColdkey(NETUID1), NETUID1, 0);

        vault.rebalance(NETUID1);

        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 100 ether, "Total stake preserved");
        assertApproxEqAbs(_getVaultStake(hotkey1, NETUID1), 50 ether, 1 ether);
        assertApproxEqAbs(_getVaultStake(hotkey2, NETUID1), 30 ether, 1 ether);
        assertApproxEqAbs(_getVaultStake(hotkey3, NETUID1), 20 ether, 1 ether);
    }

    function testRebalanceNoOpWhenAlreadyBalanced() public {
        _setValidators(NETUID1, _hks2(hotkey1, hotkey2), _wts2(5000, 5000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 50 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 50 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 50 ether);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 50 ether);
        assertEq(_getVaultStake(hotkey2, NETUID1), 50 ether);
    }

    function testRebalanceNoOpWhenCloneNotDeployed() public {
        vault.rebalance(NETUID1);
    }

    function testRebalanceEmitsEvent() public {
        _setValidators(NETUID1, _hks2(hotkey1, hotkey2), _wts2(8000, 2000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _processDeposit(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 0);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, false, false, true);
        emit Rebalanced(tokenId, hotkey1, hotkey2, 20 ether);
        vault.rebalance(NETUID1);
    }

    function testMinRebalanceAmtConstructorDefault() public view {
        assertEq(vault.minRebalanceAmt(), 2e6);
    }

    function testSetMinRebalanceAmt() public {
        vm.expectEmit(false, false, false, true);
        emit MinRebalanceAmtUpdated(2e6, 5e9);
        vault.setMinRebalanceAmt(5e9);
        assertEq(vault.minRebalanceAmt(), 5e9);
    }

    function testSetMinRebalanceAmtOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMinRebalanceAmt(0);
    }

    function testRebalanceSkipsMoveBelowMinRebalanceAmt() public {
        _setValidators(NETUID1, _hks2(hotkey1, hotkey2), _wts2(5000, 5000));

        // Bootstrap with a deposit that clears the min-stake floor, then overwrite balances
        // to a 1-RAO imbalance below the rebalance threshold.
        _simulateAlphaDepositHotkey(alice, NETUID1, 4e6, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);
        bytes32 cloneCk = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 500_001);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 500_000);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);

        // No move took place — balances unchanged.
        assertEq(_getVaultStake(hotkey1, NETUID1), 500_001);
        assertEq(_getVaultStake(hotkey2, NETUID1), 500_000);
    }

    function testWithdrawEmitsRebalanced() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.recordLogs();
        vm.prank(alice);
        vault.withdraw(TOKEN1, shares / 2, _toSubstrate(alice));
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 1, "partial withdraw should emit one Rebalanced");
    }

    function testRebalanceMovesAtOrAboveMinRebalanceAmt() public {
        _setValidators(NETUID1, _hks2(hotkey1, hotkey2), _wts2(5000, 5000));

        // Override balances to total 8e6 / 0 with target 4e6 / 4e6, so the move amount of 4e6
        // clears the 2e6 default rebalance threshold.
        _simulateAlphaDepositHotkey(alice, NETUID1, 4e6, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);
        bytes32 cloneCk = _subnetColdkey(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneCk, NETUID1, 8e6);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneCk, NETUID1, 0);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, false, false, true);
        emit Rebalanced(tokenId, hotkey1, hotkey2, 4e6);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 4e6);
        assertEq(_getVaultStake(hotkey2, NETUID1), 4e6);
    }

    // ────────────────── setValidatorRegistry ────────────────────────────

    function testSetValidatorRegistry() public {
        assertTrue(address(vault.validatorRegistry()) != address(0));

        address[] memory s = new address[](2);
        s[0] = vm.addr(SIGNER_PK_1);
        s[1] = vm.addr(SIGNER_PK_2);
        ValidatorRegistry fresh = new ValidatorRegistry(address(this), s, 2);

        vault.setValidatorRegistry(address(fresh));
        assertEq(address(vault.validatorRegistry()), address(fresh));
    }

    function testSetValidatorRegistryRevertsOnZeroAddress() public {
        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        vault.setValidatorRegistry(address(0));
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

    // ────────────────── DepositMailbox: ZeroAddress revert ──────────────────

    function testMailboxInitializeRevertsZeroAddress() public {
        address clone = Clones.clone(address(mailboxLogic));
        vm.expectRevert(CloneBase.ZeroAddress.selector);
        CloneBase(payable(clone)).initialize(address(0));
    }

    function testRegistryRevertsWhenNoValidatorsSet() public {
        address[] memory s = new address[](2);
        s[0] = vm.addr(SIGNER_PK_1);
        s[1] = vm.addr(SIGNER_PK_2);
        vault.setValidatorRegistry(address(new ValidatorRegistry(address(this), s, 2)));

        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        vault.getBestValidators(NETUID1);
    }

    // ────────────────── Validator count boundaries ───────────────────────────

    /// @dev Counts of 1, 2, 3 must all flow through deposit without revert and produce a
    ///      totalStake that matches the deposited alpha.
    function test_activeCount_derivedFromWeights() public {
        _setValidators(91, _hks1(hotkey4), _wts1(10_000));
        _setRegBlock(91, 91);
        _simulateAlphaDepositHotkey(alice, 91, 30 ether, hotkey4);
        _processDeposit(alice, 91);
        assertEq(vault.totalStake(vault.currentTokenId(91)), 30 ether);
        assertEq(_getVaultStake(hotkey4, 91), 30 ether);

        _simulateAlphaDeposit(alice, NETUID2, 100 ether);
        _processDeposit(alice, NETUID2);
        assertEq(vault.totalStake(vault.currentTokenId(NETUID2)), 100 ether);

        _simulateAlphaDeposit(alice, NETUID1, 90 ether);
        _processDeposit(alice, NETUID1);
        assertEq(vault.totalStake(vault.currentTokenId(NETUID1)), 90 ether);
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 90 ether);
    }

    // ────────────────── _resolveValidators sentinel ──────────────────────────

    /// @dev `weights[0] == 0` is the "subnet not configured" sentinel. `_resolveValidators`
    ///      must revert `NoValidatorFound` whether the registry returns all-zeros or just
    ///      slot-0-zero with non-zero entries elsewhere (a corrupt-but-not-honest case).
    /// @dev `weights[0] == 0` is the "subnet not configured" sentinel. `_resolveValidators`
    ///      must revert `NoValidatorFound` whether the registry returns all-zeros or just
    ///      slot-0-zero with non-zero entries elsewhere. The corrupt-but-not-honest case
    ///      cannot be produced by the real registry, so this test swaps in the mock.
    function test_resolveValidators_revertsWhenWeightZero() public {
        MockValidatorRegistry mock = new MockValidatorRegistry();
        vault.setValidatorRegistry(address(mock));

        _setRegBlock(91, 91);
        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        vault.getBestValidators(91);

        bytes32[3] memory corruptHks;
        uint16[3] memory corruptWts;
        corruptHks[1] = hotkey1;
        corruptHks[2] = hotkey2;
        corruptWts[1] = 5_000;
        corruptWts[2] = 5_000;
        mock.setRaw(92, corruptHks, corruptWts);
        _setRegBlock(92, 92);
        vm.expectRevert(AlphaVault.NoValidatorFound.selector);
        vault.getBestValidators(92);
    }

    // ────────────────── Defensive break on zero hotkey ────────────────────────

    function test_loop_breaksOnZeroHotkey_corruptRegistry() public {
        MockValidatorRegistry mock = new MockValidatorRegistry();
        vault.setValidatorRegistry(address(mock));

        bytes32[3] memory hks;
        uint16[3] memory wts;
        hks[0] = hotkey4;
        wts[0] = 5_000;
        wts[1] = 5_000;
        mock.setRaw(91, hks, wts);
        _setRegBlock(91, 91);

        // _resolveValidators tolerates the corrupt mid-array entry (slot 0 is non-zero,
        // so the "configured" sentinel passes); getBestValidators surfaces the raw state.
        bytes32[3] memory result = vault.getBestValidators(91);
        assertEq(result[0], hotkey4);
        assertEq(result[1], bytes32(0));
        assertEq(result[2], bytes32(0));
        assertEq(vault.getBestValidator(91), hotkey4);
    }

    // ────────────────── Deposit/Withdraw verify state changes ─────────

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
        vault.processDeposit(alice, 42, hotkey1);
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
        _setValidators(50, _hks1(hotkey1), _wts1(10_000));

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

    // ══════════════════════════════════════════════════════════════════════
    //   processDeposit — single-hotkey + on-deposit distribution
    // ══════════════════════════════════════════════════════════════════════

    /// @dev NETUID1 set is [hotkey1, hotkey2, hotkey3] with weights [3334, 3333, 3333].
    ///      For a 30e18 deposit those weights divide exactly: 10.002 / 9.999 / 9.999 — no dust.
    function test_processDeposit_chosenInSet_distributesProportionally() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 30 ether * 3334 / 10_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 30 ether * 3333 / 10_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 30 ether * 3333 / 10_000);
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 30 ether);
        assertEq(vault.totalStake(TOKEN1), 30 ether);
    }

    /// @dev hotkey4 is not in NETUID1's attested set. All of D is moved to in-set hotkeys.
    ///      With 30e18 and weights [3334, 3333, 3333] there's no division dust either way.
    function test_processDeposit_chosenOutOfSet_movesAllAway() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey4);
        _processDepositHotkey(alice, NETUID1, hotkey4);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "chosen hotkey should be drained (no dust at this amount)");
        assertEq(_getVaultStake(hotkey1, NETUID1), 30 ether * 3334 / 10_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 30 ether * 3333 / 10_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 30 ether * 3333 / 10_000);
        assertEq(vault.totalStake(TOKEN1), 30 ether);
    }

    /// @dev Realistic-amount dust check. With D = 10_000_001 RAO and weights [3334, 3333, 3333],
    ///      each move clears subtensor's DefaultMinStake floor (~2e6 RAO) — we enable that floor
    ///      on the mock to make sure the assertion reflects on-chain behaviour. 1 RAO of dust ends
    ///      up stranded on the out-of-set chosen.
    function test_processDeposit_chosenOutOfSet_strandedDustExcludedFromAccounting() public {
        MockStaking(STAKING_PRECOMPILE).setMinStake(2e6);

        _simulateAlphaDepositHotkey(alice, NETUID1, 10_000_001, hotkey4);
        _processDepositHotkey(alice, NETUID1, hotkey4);

        assertEq(_getVaultStake(hotkey4, NETUID1), 1, "1 RAO of dust stranded on out-of-set chosen");
        assertEq(_getVaultStake(hotkey1, NETUID1), uint256(10_000_001) * 3334 / 10_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), uint256(10_000_001) * 3333 / 10_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), uint256(10_000_001) * 3333 / 10_000);
        assertEq(vault.totalStake(TOKEN1), 10_000_000, "totalStake counts in-set hotkeys only");
    }

    /// @dev count=1, chosen == the only validator: zero moves, all stake stays on chosen.
    function test_processDeposit_count1_chosenIsValidator_noMoves() public {
        _setValidators(99, _hks1(hotkey4), _wts1(10_000));
        _setRegBlock(99, 300);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _processDepositHotkey(alice, 99, hotkey4);

        bytes32 cloneCk = _toSubstrate(vault.subnetClone(vault.currentTokenId(99)));
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, cloneCk, 99), 10 ether);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, cloneCk, 99), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey2, cloneCk, 99), 0);
    }

    /// @dev count=1, chosen != the only validator: exactly one move, chosen ends with 0.
    function test_processDeposit_count1_chosenNotValidator_singleMove() public {
        _setValidators(99, _hks1(hotkey4), _wts1(10_000));
        _setRegBlock(99, 300);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey1);
        _processDepositHotkey(alice, 99, hotkey1);

        bytes32 cloneCk = _toSubstrate(vault.subnetClone(vault.currentTokenId(99)));
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, cloneCk, 99), 10 ether);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, cloneCk, 99), 0);
    }

    function test_processDeposit_revertsZeroChosenHotkey() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroHotkey.selector);
        vault.processDeposit(alice, NETUID1, bytes32(0));
    }

    /// @dev D below `minRebalanceAmt` reverts (the transferStake flush itself would fall under
    ///      subtensor's `AmountTooLow` floor).
    function test_processDeposit_revertsWhenDepositBelowMinRebalanceAmt() public {
        // minRebalanceAmt defaults to 2e6 — stake one RAO under it.
        _simulateAlphaDepositHotkey(alice, NETUID1, 1_999_999, hotkey1);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.processDeposit(alice, NETUID1, hotkey1);
    }

    /// @dev D clears the flush floor but at least one per-slot move falls below it.
    ///      Weights [3334, 3333, 3333] → smallest mover slice = D * 3333 / 10000. For D = 3e6,
    ///      slice = 999_900 < 2e6 (default minRebalanceAmt). Reverts before any precompile call.
    function test_processDeposit_revertsWhenPerSlotMoveBelowMinRebalanceAmt() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 3_000_000, hotkey4);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.processDeposit(alice, NETUID1, hotkey4);
    }

    /// @dev Boundary: deposit exactly at minRebalanceAmt clears the flush check. With
    ///      count=1 chosen-is-validator, no moves happen, so the per-slot check doesn't apply.
    function test_processDeposit_acceptsExactlyMinRebalanceAmt_count1() public {
        _setValidators(99, _hks1(hotkey4), _wts1(10_000));
        _setRegBlock(99, 300);

        _simulateAlphaDepositHotkey(alice, 99, 2e6, hotkey4);
        _processDepositHotkey(alice, 99, hotkey4);

        bytes32 cloneCk = _toSubstrate(vault.subnetClone(vault.currentTokenId(99)));
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, cloneCk, 99), 2e6);
    }

    /// @dev Even if mailbox holds stake under a different hotkey, processDeposit reverts when
    ///      the chosen hotkey itself has no stake — we never sweep across hotkeys anymore.
    function test_processDeposit_revertsWhenChosenHasZeroStake_evenIfOtherHotkeyFunded() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.processDeposit(alice, NETUID1, hotkey2);
    }

    function test_processDeposit_emitsDepositedWithChosenHotkey() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey2);
        vm.expectEmit(true, true, false, false);
        emit Deposited(alice, TOKEN1, 0, 0, hotkey2);
        vm.prank(alice);
        vault.processDeposit(alice, NETUID1, hotkey2);
    }

    function test_processDeposit_derivesMailboxColdkeyFromUserClone() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        _simulateAlphaDepositHotkey(bob, NETUID1, 5 ether, hotkey1);

        address aliceClone = vault.getDepositAddress(alice, NETUID1);
        address bobClone = vault.getDepositAddress(bob, NETUID1);

        _processDepositHotkey(alice, NETUID1, hotkey1);

        // Alice's mailbox drained, bob's mailbox untouched.
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(aliceClone), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(bobClone), NETUID1), 5 ether);
        // Only alice's 10 ether ended up in the vault accounting.
        assertEq(vault.totalStake(TOKEN1), 10 ether);
    }

    /// @dev Second deposit doesn't touch the first deposit's distribution — existing balances
    ///      are left alone, only the freshly-deposited delta is distributed.
    function test_processDeposit_preservesPriorBalances() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);
        uint256 hk1After1 = _getVaultStake(hotkey1, NETUID1);
        uint256 hk2After1 = _getVaultStake(hotkey2, NETUID1);
        uint256 hk3After1 = _getVaultStake(hotkey3, NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _processDepositHotkey(bob, NETUID1, hotkey1);

        // Each slot grew by the same proportional slice the first deposit added.
        assertEq(_getVaultStake(hotkey1, NETUID1), 2 * hk1After1);
        assertEq(_getVaultStake(hotkey2, NETUID1), 2 * hk2After1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 2 * hk3After1);
        assertEq(vault.totalStake(TOKEN1), 60 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   validateDeposit — wallet-facing pre-flight
    // ══════════════════════════════════════════════════════════════════════

    function test_validateDeposit_happyPath_doesNotRevert() public view {
        // Smallest D under default weights/threshold that clears every per-slot check.
        vault.validateDeposit(NETUID1, hotkey1, 6_001_802);
    }

    function test_validateDeposit_surfacesDepositTooSmall() public {
        vm.expectRevert(AlphaVault.DepositTooSmall.selector);
        vault.validateDeposit(NETUID1, hotkey4, 3_000_000);
    }

    function test_validateDeposit_revertsSubnetNotRegistered() public {
        vm.expectRevert(AlphaVault.SubnetNotRegistered.selector);
        vault.validateDeposit(42, hotkey1, 10 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   Validator-set rotation: orphan sweep
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Replace registry's NETUID1 set with [a, b, c] / equal weights.
    function _setNetuid1Set(bytes32 a, bytes32 b, bytes32 c) internal {
        _setValidators(NETUID1, _hks3(a, b, c), _wts3(3334, 3333, 3333));
    }

    function test_rotation_snapshotInitializedOnFirstDeposit() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);
        bytes32[3] memory snapshot = vault.lastSeenHotkeys(TOKEN1);
        assertEq(snapshot[0], hotkey1);
        assertEq(snapshot[1], hotkey2);
        assertEq(snapshot[2], hotkey3);
    }

    function test_rotation_sweptOnRebalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);
        uint256 hk3Before = _getVaultStake(hotkey3, NETUID1);
        assertGt(hk3Before, vault.minRebalanceAmt());

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "orphan must be drained");
        assertGe(_countRebalancedLogs(logs), 1, "sweep must emit Rebalanced");

        bytes32[3] memory snapshot = vault.lastSeenHotkeys(TOKEN1);
        assertEq(snapshot[2], hotkey4, "snapshot must be refreshed to current set");
    }

    function test_rotation_sweptOnNextDeposit() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _processDepositHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "orphan swept before second deposit");
        assertApproxEqAbs(vault.totalStake(TOKEN1), 60 ether, 10);
    }

    function test_rotation_sweptOnWithdraw() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.withdraw(TOKEN1, shares, aliceSub);

        uint256 received = _getStake(hotkey1, alice, NETUID1) + _getStake(hotkey2, alice, NETUID1)
            + _getStake(hotkey3, alice, NETUID1) + _getStake(hotkey4, alice, NETUID1);
        assertApproxEqAbs(received, 30 ether, 10, "user must receive full deposit incl. orphan");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "orphan drained as part of withdraw");
    }

    function test_rotation_multipleBacklog_allOrphansSwept() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);
        uint256 hk2Before = _getVaultStake(hotkey2, NETUID1);
        uint256 hk3Before = _getVaultStake(hotkey3, NETUID1);
        assertGt(hk2Before, vault.minRebalanceAmt());
        assertGt(hk3Before, vault.minRebalanceAmt());

        // Two rotations in a row, no rebalance in between: drop hk3 then drop hk2.
        _setNetuid1Set(hotkey1, hotkey2, hotkey4);
        _setNetuid1Set(hotkey1, hotkey4, hotkey3); // hk3 is back, hk2 dropped
        // Now snapshot still holds the original [hk1, hk2, hk3]; current = [hk1, hk4, hk3].
        // hk2 should be orphaned. hk3 is back in set so its prior balance should NOT be swept.

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "hk2 orphan swept");
        assertApproxEqAbs(_getVaultStake(hotkey3, NETUID1), hk3Before, 1, "hk3 stays - back in current set");
    }

    function test_rotation_orphanBelowThreshold_skipped() public {
        _setValidators(NETUID1, _hks3(hotkey1, hotkey2, hotkey3), _wts3(4999, 4999, 2));

        // Smallest deposit where every slice clears the 2e6 floor.
        // hk3 slice = D * 2 / 10000. Need D * 2 / 10000 >= 2e6 → D >= 1e10. Use 1e10.
        // After deposit hk3 has exactly 2e6 RAO (at minRebalanceAmt).
        _simulateAlphaDepositHotkey(alice, NETUID1, 1e10, hotkey1);
        _processDepositHotkey(alice, NETUID1, hotkey1);
        uint256 hk3Bal = _getVaultStake(hotkey3, NETUID1);
        assertEq(hk3Bal, 2e6, "hk3 exactly at floor");

        // Now drop hk3 to under the floor by manually shaving 1 RAO.
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, _subnetColdkey(NETUID1), NETUID1, 2e6 - 1);
        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vault.rebalance(NETUID1);

        // Below-threshold orphan is left stranded; snapshot still refreshes.
        assertEq(_getVaultStake(hotkey3, NETUID1), 2e6 - 1, "sub-threshold orphan not swept");
        bytes32[3] memory snapshot = vault.lastSeenHotkeys(TOKEN1);
        assertEq(snapshot[2], hotkey4, "snapshot refreshed regardless");
    }

    function test_rotation_noChange_syncIsCheapNoOp() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);
        uint256 hk3 = _getVaultStake(hotkey3, NETUID1);

        // Second op with no rotation between them.
        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // No rebalanced events expected since balances were already at target post-deposit.
        // (Sweep skipped because snapshot == current set.)
        assertEq(_countRebalancedLogs(logs), 0, "no-op rebalance emits nothing");
        assertEq(_getVaultStake(hotkey3, NETUID1), hk3);
    }

    function test_rotation_emitsRebalancedFromSweep() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _processDeposit(alice, NETUID1);
        uint256 hk3Bal = _getVaultStake(hotkey3, NETUID1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vm.expectEmit(true, false, false, true);
        emit Rebalanced(TOKEN1, hotkey3, hotkey1, hk3Bal);
        vault.rebalance(NETUID1);
    }
}
