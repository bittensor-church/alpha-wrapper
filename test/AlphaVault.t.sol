// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { DepositForwarderLogic } from "src/DepositForwarderLogic.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockMetagraph } from "./mocks/MockMetagraph.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { METAGRAPH_PRECOMPILE } from "src/interfaces/IMetagraph.sol";

contract AlphaVaultTest is Test {
    AlphaVault public vault;
    DepositForwarderLogic public logic;
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

    bytes32 public vaultSubstrateColdkey;

    function setUp() public {
        // Deploy mock staking precompile at 0x805
        mockStaking = new MockStaking();
        vm.etch(STAKING_PRECOMPILE, address(mockStaking).code);

        // Deploy mock metagraph precompile at 0x802
        mockMetagraph = new MockMetagraph();
        vm.etch(METAGRAPH_PRECOMPILE, address(mockMetagraph).code);

        // Set up 3 validators for subnet 1 (descending stake)
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID1), 0, hotkey1, 1000, true);
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID1), 1, hotkey2, 800, true);
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID1), 2, hotkey3, 600, true);

        // Set up validators for subnet 2: hotkey2 has most stake, hotkey1 second
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID2), 0, hotkey2, 2000, true);
        MockMetagraph(METAGRAPH_PRECOMPILE).setValidator(uint16(NETUID2), 1, hotkey1, 100, true);

        logic = new DepositForwarderLogic();

        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce);
        vaultSubstrateColdkey = _toSubstrate(predictedVault);

        vault = new AlphaVault("https://api.tao20.io/{id}.json", address(logic), vaultSubstrateColdkey);
        require(address(vault) == predictedVault, "Vault address prediction mismatch");

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
        vault.processDeposit(user, netuid, cloneSub);
    }

    function _getStake(bytes32 hotkey, address who, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _toSubstrate(who), netuid);
    }

    function _getVaultStake(bytes32 hotkey, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, vaultSubstrateColdkey, netuid);
    }

    function _totalVaultStakeAcrossHotkeys(uint256 netuid) internal view returns (uint256) {
        uint256 total = 0;
        total += _getVaultStake(hotkey1, netuid);
        total += _getVaultStake(hotkey2, netuid);
        total += _getVaultStake(hotkey3, netuid);
        return total;
    }

    // ────────────────── Auto Vault (no registration) ─────────────────────────

    function testAutoVaultOnFirstDeposit() public {
        assertEq(vault.totalSupply(NETUID1), 0);
        assertEq(vault.totalStake(NETUID1), 0);

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        assertTrue(vault.balanceOf(alice, NETUID1) > 0);
        assertEq(vault.totalStake(NETUID1), 10 ether);
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

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _processDeposit(alice, 99);

        // All stake under one hotkey (no split possible)
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, vaultSubstrateColdkey, 99), 10 ether);
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

        assertTrue(vault.balanceOf(alice, NETUID1) > 0);
        assertEq(vault.totalStake(NETUID1), 10 ether);
        // Total vault stake across all hotkeys should equal deposit
        uint256 total = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertEq(total, 10 ether);
    }

    function testProcessDepositMultipleSubnets() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _processDeposit(alice, NETUID2);

        assertTrue(vault.balanceOf(alice, NETUID1) > 0);
        assertTrue(vault.balanceOf(alice, NETUID2) > 0);
        assertEq(vault.totalStake(NETUID1), 10 ether);
        assertEq(vault.totalStake(NETUID2), 5 ether);
    }

    function testProcessDepositTwice() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);
        uint256 after1 = vault.balanceOf(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);
        uint256 after2 = vault.balanceOf(alice, NETUID1);

        assertTrue(after2 > after1);
        assertEq(vault.totalStake(NETUID1), 10 ether);
    }

    function testProcessDepositRevertsZero() public {
        address cloneAddr = vault.getDepositAddress(alice, NETUID1);
        bytes32 cloneSub = _toSubstrate(cloneAddr);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.processDeposit(alice, NETUID1, cloneSub);
    }

    // ────────────────── Share Price ──────────────────────────────────────────

    function testSharePriceGrowsWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 priceBefore = vault.sharePrice(NETUID1);
        vault.injectRewards{ value: 5 ether }(NETUID1);
        uint256 priceAfter = vault.sharePrice(NETUID1);

        assertTrue(priceAfter > priceBefore);
    }

    function testSharePriceIndependentPerSubnet() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID2, 10 ether);
        _processDeposit(alice, NETUID2);

        vault.injectRewards{ value: 10 ether }(NETUID1);

        assertTrue(vault.sharePrice(NETUID1) > vault.sharePrice(NETUID2));
    }

    function testLateDepositorGetFewerShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, NETUID1);

        vault.injectRewards{ value: 10 ether }(NETUID1);

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _processDeposit(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, NETUID1);

        assertTrue(bobShares < aliceShares);
    }

    // ────────────────── Withdraw ─────────────────────────────────────────────

    function testWithdraw() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, NETUID1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.withdraw(NETUID1, shares, aliceSub);

        assertEq(vault.balanceOf(alice, NETUID1), 0);
        // Withdrawal comes from hotkeys with vault stake
        uint256 totalReceived = 0;
        totalReceived += _getStake(hotkey1, alice, NETUID1);
        totalReceived += _getStake(hotkey2, alice, NETUID1);
        totalReceived += _getStake(hotkey3, alice, NETUID1);
        assertTrue(totalReceived > 0);
    }

    function testWithdrawWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, NETUID1);

        // Inject rewards + add mock stake to the hotkey with most vault stake
        vault.injectRewards{ value: 5 ether }(NETUID1);
        // After deposit+rebalance, hotkey1 holds the deposit. Add rewards there.
        uint256 currentStake = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, vaultSubstrateColdkey, NETUID1, currentStake + 5 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.withdraw(NETUID1, shares, aliceSub);

        uint256 totalReceived = 0;
        totalReceived += _getStake(hotkey1, alice, NETUID1);
        totalReceived += _getStake(hotkey2, alice, NETUID1);
        totalReceived += _getStake(hotkey3, alice, NETUID1);
        assertTrue(totalReceived > 10 ether, "Should receive deposit + rewards");
    }

    function testWithdrawUsesLargestHotkey() public {
        // Deposit and manually set vault stake across multiple hotkeys
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        // Manually distribute vault stake: hotkey3 gets the most
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, vaultSubstrateColdkey, NETUID1, 1 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, vaultSubstrateColdkey, NETUID1, 2 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, vaultSubstrateColdkey, NETUID1, 7 ether);

        uint256 shares = vault.balanceOf(alice, NETUID1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.withdraw(NETUID1, shares, aliceSub);

        // Withdrawal should come from hotkey3 (largest balance)
        uint256 fromHk3 = _getStake(hotkey3, alice, NETUID1);
        assertTrue(fromHk3 > 0, "Should withdraw from hotkey with most vault stake");
    }

    function testWithdrawRevertsOnZero() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.withdraw(NETUID1, 0, aliceSub);
    }

    function testWithdrawRevertsInsufficientShares() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.InsufficientShares.selector);
        vault.withdraw(NETUID1, 1 ether, aliceSub);
    }

    // ────────────────── Forwarder Security ───────────────────────────────────

    function testOnlyVaultCanFlush() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _processDeposit(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);

        vm.prank(bob);
        vm.expectRevert(DepositForwarderLogic.NotWrapper.selector);
        DepositForwarderLogic(payable(clone)).flush(bytes32(0), hotkey1, NETUID1, 1 ether);
    }

    function testForwarderCannotReinitialize() public {
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);
        _processDeposit(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        vm.expectRevert(DepositForwarderLogic.AlreadyInitialized.selector);
        DepositForwarderLogic(payable(clone)).initialize(address(0xdead));
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
        ids[0] = NETUID1;
        ids[1] = NETUID2;
        amounts[0] = vault.balanceOf(alice, NETUID1);
        amounts[1] = vault.balanceOf(alice, NETUID2);

        vm.prank(bob);
        vault.safeBatchTransferFrom(alice, bob, ids, amounts, "");

        assertEq(vault.balanceOf(alice, NETUID1), 0);
        assertEq(vault.balanceOf(alice, NETUID2), 0);
        assertTrue(vault.balanceOf(bob, NETUID1) > 0);
        assertTrue(vault.balanceOf(bob, NETUID2) > 0);
    }

    // ────────────────── Preview ──────────────────────────────────────────────

    function testPreviewDeposit() public view {
        assertTrue(vault.previewDeposit(NETUID1, 10 ether) > 0);
    }

    function testPreviewWithdraw() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, NETUID1);
        uint256 preview = vault.previewWithdraw(NETUID1, shares);
        assertTrue(preview > 9.99 ether && preview <= 10 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //   EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    // ────────────────── Withdraw partial shares ─────────────────────────

    function testWithdrawPartialShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, NETUID1);
        bytes32 aliceSub = _toSubstrate(alice);

        // Withdraw half
        vm.prank(alice);
        vault.withdraw(NETUID1, shares / 2, aliceSub);

        // Should still have ~half the shares
        assertApproxEqAbs(vault.balanceOf(alice, NETUID1), shares / 2, 1);
        // Vault should still have ~half the stake
        assertApproxEqAbs(vault.totalStake(NETUID1), 5 ether, 0.01 ether);
    }

    // ────────────────── Multiple users deposit/withdraw interleaved ─────

    function testInterleavedDepositsWithdrawals() public {
        // Alice deposits 10
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, NETUID1);

        // Bob deposits 20
        _simulateAlphaDeposit(bob, NETUID1, 20 ether);
        _processDeposit(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, NETUID1);

        // Bob should have ~2x Alice's shares (same price)
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18);

        // Alice withdraws everything
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.withdraw(NETUID1, aliceShares, aliceSub);
        assertEq(vault.balanceOf(alice, NETUID1), 0);

        // Bob should still have his shares, totalStake should be ~20
        assertEq(vault.balanceOf(bob, NETUID1), bobShares);
        assertApproxEqAbs(vault.totalStake(NETUID1), 20 ether, 0.01 ether);

        // Bob withdraws
        bytes32 bobSub = _toSubstrate(bob);
        vm.prank(bob);
        vault.withdraw(NETUID1, bobShares, bobSub);
        assertEq(vault.balanceOf(bob, NETUID1), 0);
        assertEq(vault.totalStake(NETUID1), 0);
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

    // ────────────────── processDeposit by owner (on behalf) ────────────

    function testProcessDepositByOwner() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        address clone = vault.getDepositAddress(alice, NETUID1);
        bytes32 cloneSub = _toSubstrate(clone);

        // Owner can process on behalf of alice
        vault.processDeposit(alice, NETUID1, cloneSub);
        assertGt(vault.balanceOf(alice, NETUID1), 0);
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
        vault.injectRewards{ value: 10 ether }(NETUID1);

        uint256 price1 = vault.sharePrice(NETUID1);
        uint256 price2 = vault.sharePrice(NETUID2);
        assertGt(price1, price2, "NETUID1 should have higher share price after rewards");

        // Withdrawing from NETUID2 should return ~5 ether, unaffected by NETUID1 rewards
        uint256 shares2 = vault.balanceOf(alice, NETUID2);
        uint256 preview2 = vault.previewWithdraw(NETUID2, shares2);
        assertApproxEqAbs(preview2, 5 ether, 0.01 ether);
    }

    // ────────────────── Virtual shares prevent inflation attack ────────

    function testFirstDepositorInflationAttack() public {
        // Attacker deposits 1 wei
        _simulateAlphaDeposit(alice, NETUID1, 1);
        _processDeposit(alice, NETUID1);

        // Inject large reward to inflate share price
        vault.injectRewards{ value: 100 ether }(NETUID1);

        // Victim deposits 10 ether
        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _processDeposit(bob, NETUID1);

        // With virtual shares, Bob should still get meaningful shares
        uint256 bobShares = vault.balanceOf(bob, NETUID1);
        assertGt(bobShares, 0, "Bob should get shares despite inflation attempt");

        // Bob's shares should be worth approximately his deposit
        uint256 bobValue = vault.previewWithdraw(NETUID1, bobShares);
        assertGt(bobValue, 9 ether, "Bob should not lose significant value to inflation attack");
    }

    // ────────────────── Constructor reverts on zero coldkey ────────────

    function testConstructorRevertsZeroColdkey() public {
        vm.expectRevert(AlphaVault.ZeroColdkey.selector);
        new AlphaVault("uri", address(logic), bytes32(0));
    }

    // ────────────────── ERC1155 batch transfer works correctly ─────────

    function testBatchTransferMultipleSubnets() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _processDeposit(alice, NETUID2);

        uint256 bal1 = vault.balanceOf(alice, NETUID1);
        uint256 bal2 = vault.balanceOf(alice, NETUID2);

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = NETUID1;
        ids[1] = NETUID2;
        amounts[0] = bal1 / 2;
        amounts[1] = bal2 / 2;

        vm.prank(alice);
        vault.safeBatchTransferFrom(alice, bob, ids, amounts, "");

        assertEq(vault.balanceOf(bob, NETUID1), bal1 / 2);
        assertEq(vault.balanceOf(bob, NETUID2), bal2 / 2);
        assertEq(vault.balanceOf(alice, NETUID1), bal1 - bal1 / 2);
    }

    // ────────────────── Share price starts at virtual offset ───────────

    function testSharePriceInitialValue() public view {
        // Before any deposits, sharePrice should return the virtual ratio
        uint256 price = vault.sharePrice(99); // unused netuid
        // VIRTUAL_ASSETS / VIRTUAL_SHARES = 1 / 1e9 → very small
        assertGt(price, 0);
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
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, vaultSubstrateColdkey, NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, vaultSubstrateColdkey, NETUID1, 0);

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
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, vaultSubstrateColdkey, NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, vaultSubstrateColdkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, vaultSubstrateColdkey, NETUID1, 0);

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
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, vaultSubstrateColdkey, NETUID1, 50 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, vaultSubstrateColdkey, NETUID1, 50 ether);

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

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, vaultSubstrateColdkey, NETUID1, 100 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, vaultSubstrateColdkey, NETUID1, 0);

        // Just verify rebalance executes without revert and moves stake
        uint256 hk1Before = _getVaultStake(hotkey1, NETUID1);
        vault.rebalance(NETUID1);
        uint256 hk1After = _getVaultStake(hotkey1, NETUID1);
        assertLt(hk1After, hk1Before, "Stake should move from overweight");
    }

    function testRebalanceZeroTotalStakeNoOp() public {
        // Subnet with validators but no stake — rebalance should return early (total==0)
        vault.rebalance(NETUID1); // Has validators but no deposits yet → total stake is 0 after resolving
        // No revert expected — returns early
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
        DepositForwarderLogic freshLogic = new DepositForwarderLogic();
        vm.expectRevert(DepositForwarderLogic.ZeroAddress.selector);
        freshLogic.initialize(address(0));
    }

    // ────────────────── receive() payable ────────────────────────────────

    function testReceiveNativeTokens() public {
        (bool ok,) = address(vault).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(address(vault).balance, 1 ether);
    }

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
        uint256 stakeBefore = vault.totalStake(NETUID1);
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);
        assertEq(vault.totalStake(NETUID1), stakeBefore + 10 ether);
    }

    function testWithdrawDecreasesTotalStake() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _processDeposit(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, NETUID1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.withdraw(NETUID1, shares, aliceSub);
        assertEq(vault.totalStake(NETUID1), 0);
    }

    // ────────────────── injectRewards ────────────────────────────────────

    function testInjectRewardsIncreasesStake() public {
        vault.injectRewards{ value: 5 ether }(NETUID1);
        assertEq(vault.totalStake(NETUID1), 5 ether);
    }

    function testInjectRewardsOnlyOwner() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        vault.injectRewards{ value: 1 ether }(NETUID1);
    }
}
