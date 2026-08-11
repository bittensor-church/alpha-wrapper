// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Exposes the internal ratchet so a test can drive the high-water directly; the ratchet's
///      production call site arrives with the later health check. No production code is made
///      test-only for this.
contract AlphaVaultHarness is AlphaVault {
    constructor(string memory uri, address mailboxLogic_, address subnetLogic_, address validatorRegistry_)
        AlphaVault(uri, mailboxLogic_, subnetLogic_, validatorRegistry_)
    { }

    function ratchetTracked(uint256 tokenId, uint256 slotIdx, uint256 observed) external {
        _ratchetTracked(tokenId, slotIdx, observed);
    }
}

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

        _setVaultStake(hotkey1, netuid, uint256(type(uint128).max) + 1);

        vm.expectRevert(AlphaVault.TrackedOverflow.selector);
        vault.rebalance(netuid);
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
