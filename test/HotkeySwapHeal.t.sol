// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultHarness } from "./AlphaVaultHarness.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Covers the per-slot `tracked` high-water: it mirrors the vault's own stake after every
///      signed move (wrap, unwrap, sell, authorized rotation), only ever ratchets upward on
///      emissions, and refuses a value that cannot fit the slot's width.
contract HotkeySwapHealTest is AlphaVaultTestBase {
    AlphaVaultHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new AlphaVaultHarness(VAULT_URI, address(mailboxLogic), address(subnetLogic), address(registry));
    }

    function test_Wrap_SetsTrackedToStaked() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        AlphaVault.Slot[3] memory slots = vault.slots(TOKEN1);
        assertEq(slots[0].hotkey, hotkey1, "slot 0 remembers hotkey1");
        assertEq(uint256(slots[0].tracked), _getVaultStake(hotkey1, NETUID1), "slot 0 tracked mirrors staked alpha");
        assertEq(uint256(slots[1].tracked), _getVaultStake(hotkey2, NETUID1), "slot 1 tracked mirrors staked alpha");
        assertEq(uint256(slots[2].tracked), _getVaultStake(hotkey3, NETUID1), "slot 2 tracked mirrors staked alpha");
    }

    /// @dev Emissions land on a hotkey without any vault move; the ratchet lifts the expectation to
    ///      the new stake and a later smaller reading never pulls it back down.
    function testFuzz_Emission_RatchetsTrackedUp(uint256 raw) public {
        uint256 extra = bound(raw, 1, 1e15);

        // A single-validator subnet keeps the whole deposit on one hotkey, so `tracked` is exact.
        uint256 netuid = 7;
        _registerSubnet(netuid, hotkey1);
        uint256 base = 10 ether;
        uint256 tokenId = _harnessWrap(alice, netuid, base, hotkey1);

        bytes32 cloneColdkey = _toSubstrate(harness.subnetClone(tokenId));
        uint256 baseline = uint256(harness.slots(tokenId)[0].tracked);
        assertEq(baseline, base, "tracked seeded from the wrapped stake");

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, netuid, base + extra);
        harness.ratchetTracked(tokenId, 0, base + extra);
        assertEq(uint256(harness.slots(tokenId)[0].tracked), base + extra, "ratchet lifts tracked to the emission");

        harness.ratchetTracked(tokenId, 0, baseline);
        assertEq(uint256(harness.slots(tokenId)[0].tracked), base + extra, "tracked never falls");
    }

    function test_Unwrap_LowersTrackedToPostBalance() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 ether);
        uint256 trackedBefore = uint256(vault.slots(TOKEN1)[0].tracked);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));

        AlphaVault.Slot[3] memory slots = vault.slots(TOKEN1);
        assertLt(uint256(slots[0].tracked), trackedBefore, "tracked drops after the partial exit");
        assertEq(uint256(slots[0].tracked), _getVaultStake(hotkey1, NETUID1), "slot 0 tracked mirrors reduced stake");
        assertEq(uint256(slots[1].tracked), _getVaultStake(hotkey2, NETUID1), "slot 1 tracked mirrors reduced stake");
        assertEq(uint256(slots[2].tracked), _getVaultStake(hotkey3, NETUID1), "slot 2 tracked mirrors reduced stake");
    }

    /// @dev An attester rotation swaps hotkey1 out for hotkey4; the consolidation rolls the backing
    ///      onto the new set and the high-water resets to the consolidated stake, carrying no trace
    ///      of hotkey1's old expectation.
    function test_AuthorizedRotation_ResetsTracked() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        AlphaVault.Slot[3] memory slots = vault.slots(TOKEN1);
        assertEq(slots[0].hotkey, hotkey4, "slot 0 remembers the rotated-in hotkey");
        assertEq(
            uint256(slots[0].tracked), _getVaultStake(hotkey4, NETUID1), "slot 0 tracked mirrors consolidated stake"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "rotated-out hotkey holds no backing");
        assertTrue(
            slots[0].hotkey != hotkey1 && slots[1].hotkey != hotkey1 && slots[2].hotkey != hotkey1,
            "no slot still remembers the rotated-out hotkey"
        );
    }

    /// @dev A stake reading wider than the slot's `uint128` cannot be recorded, so the refresh
    ///      reverts rather than silently truncate the expectation.
    function test_RevertWhen_TrackedOverflow() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _simulateAlphaDepositHotkey(alice, netuid, 10 ether, hotkey1);
        _wrapHotkey(alice, netuid, hotkey1);

        // Seed the oversized stake directly (no resync) so the narrowing fires inside the op's own
        // tracked refresh, not during setup.
        MockStaking(STAKING_PRECOMPILE)
            .setStake(hotkey1, _subnetColdkey(netuid), netuid, uint256(type(uint128).max) + 1);

        vm.expectRevert(AlphaVault.TrackedOverflow.selector);
        vault.rebalance(netuid);
    }

    function test_Wrap_RevertsWhenBackingShort() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        vm.prank(bob);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.wrap(NETUID1, hotkey1);
    }

    function test_Unwrap_RevertsWhenBackingShort() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
    }

    function test_UnwrapForTao_RevertsWhenBackingShort() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.prank(alice);
        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);
    }

    function test_Rebalance_RevertsWhenBackingShort() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        vm.expectPartialRevert(AlphaVault.BackingShortfall.selector);
        vault.rebalance(NETUID1);
    }

    /// @dev Views never mask the shortfall: backing reads not-intact and NAV honestly undercounts,
    ///      so an off-chain consumer sees the same world the mutating path fails closed on.
    function test_Views_ReportShortfallHonestly() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        uint256 navBefore = vault.totalStake(TOKEN1);

        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        assertFalse(vault.isBackingIntact(TOKEN1), "off-vault move reports backing not intact");
        assertLt(vault.totalStake(TOKEN1), navBefore, "NAV honestly reflects the undercount");
    }

    /// @dev Emissions raise a hotkey's stake without a vault move; the check reads at or above the
    ///      mark, so the op proceeds and the backing simply grows.
    function test_Emission_DoesNotBreakSlot() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        _simulateEmissions(NETUID1, 5 ether);
        vault.rebalance(NETUID1);

        assertGt(vault.totalStake(TOKEN1), 30 ether, "emission counted into NAV, no false break");
    }

    /// @dev Moving the whole position onto one recorded validator keeps the union total, so the
    ///      check does not fire - only stake leaving the counted set is a shortfall.
    function test_Redistribution_IsNotShortfall() public {
        _depositAndWrap(alice, NETUID1, 30 ether);

        bytes32 coldkey = _subnetColdkey(NETUID1);
        uint256 whole =
            _getVaultStake(hotkey1, NETUID1) + _getVaultStake(hotkey2, NETUID1) + _getVaultStake(hotkey3, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, coldkey, NETUID1, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, coldkey, NETUID1, whole);

        vault.rebalance(NETUID1);
        assertTrue(vault.isBackingIntact(TOKEN1), "redistribution kept backing intact");
    }

    /// @dev The gate is the fingerprint of an off-vault move, not the registry set changing: once
    ///      attesters re-attest the moved-to hotkey, it leaves the recorded set and consolidation
    ///      adopts the new one, so the op recovers without any vault-held recovery path.
    function test_AttesterReattest_RecoversAfterBroken() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        AlphaVault.Slot[3] memory slots = vault.slots(TOKEN1);
        assertEq(slots[0].hotkey, hotkey4, "slot 0 adopts the re-attested hotkey");
        assertGt(uint256(slots[0].tracked), 0, "tracked re-established on the new hotkey");

        uint256 recoveredNav =
            _getVaultStake(hotkey4, NETUID1) + _getVaultStake(hotkey2, NETUID1) + _getVaultStake(hotkey3, NETUID1);
        assertEq(vault.totalStake(TOKEN1), recoveredNav, "NAV counts the re-attested hotkey");
        assertApproxEqAbs(recoveredNav, 30 ether, 0.01 ether, "backing whole after recovery");
    }

    /// @dev The dissolution guard runs before the health check, so a dissolving subnet reverts on the
    ///      blackout, never on a broken slot.
    function test_Dissolving_SkipsHealthCheck() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(AlphaVault.SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice));
    }

    /// @dev Moves the clone's whole backing off `fromHotkey` onto `toHotkey` with no vault call,
    ///      standing in for a validator coldkey renaming its hotkey out from under the position.
    function _simulateOffVaultSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        bytes32 coldkey = _subnetColdkey(netuid);
        uint256 amount = _getStakeForColdkey(fromHotkey, coldkey, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(fromHotkey, coldkey, netuid, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(toHotkey, coldkey, netuid, amount);
    }

    function _harnessWrap(address user, uint256 netuid, uint256 amount, bytes32 hotkey)
        internal
        returns (uint256 tokenId)
    {
        address cloneAddr = harness.getDepositAddress(user, netuid);
        bytes32 cloneColdkey = _toSubstrate(cloneAddr);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, cloneColdkey, netuid, amount);
        vm.prank(user);
        harness.wrap(netuid, hotkey);
        tokenId = harness.currentTokenId(netuid);
    }
}
