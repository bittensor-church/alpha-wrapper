// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { SUBNET_PRECOMPILE } from "src/interfaces/ISubnet.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockSubnetPrecompile } from "./mocks/MockSubnetPrecompile.sol";
import { MockValidatorRegistry } from "./mocks/MockValidatorRegistry.sol";
import { BackingShortfall, NoValidatorFound, ValidatorSetMalformed } from "src/VaultErrors.sol";

/// @dev Tests the chain-read helpers the vault and its lens share: stake and validator-set
///      lookups, the recovery-window arithmetic, and the dissolution checks.
contract VaultReadsTest is Test {
    uint16 internal constant NETUID = 7;
    uint64 internal constant REGISTRATION_BLOCK = 100;
    uint256 internal constant TOKEN_ID = (uint256(REGISTRATION_BLOCK) << 16) | NETUID;

    bytes32 internal constant COLDKEY = keccak256("coldkey");
    bytes32 internal constant HOTKEY_A = keccak256("hotkey-a");
    bytes32 internal constant HOTKEY_B = keccak256("hotkey-b");
    bytes32 internal constant HOTKEY_C = keccak256("hotkey-c");

    MockValidatorRegistry internal registry;

    function setUp() public {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        vm.etch(SUBNET_PRECOMPILE, address(new MockSubnetPrecompile()).code);
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(NETUID, REGISTRATION_BLOCK);
        registry = new MockValidatorRegistry();
    }

    /// @dev External indirection so `vm.expectRevert` sees a call frame for the internal library
    ///      functions under test.
    function callResolveValidators(IValidatorRegistry _registry, uint16 netuid)
        external
        view
        returns (bytes32[] memory, uint16[] memory)
    {
        return VaultReads.resolveValidators(_registry, netuid);
    }

    function callRequireIntact(VaultReads.Slot[] memory slots, VaultReads.Backing memory backing, uint16 netuid)
        external
        pure
    {
        VaultReads.requireIntact(slots, backing, netuid);
    }

    /// @dev The optimizer may fold repeated `block.timestamp` reads within one frame, which a
    ///      `vm.warp` between them cannot break; a fresh frame per read keeps the clock honest.
    function callIsWindowStanding(uint64 shortSince, uint256 window) external view returns (bool) {
        return VaultReads.isWindowStanding(shortSince, window);
    }

    // -------------------- Tracked-balance comparison -----------------------------

    function testFuzz_CoversTracked_AllowsTheSlack(uint256 stake, uint256 tracked) public pure {
        stake = bound(stake, 0, 1e30);
        tracked = bound(tracked, 0, 1e30);

        assertEq(VaultReads.coversTracked(stake, tracked), stake + VaultReads.TRACKED_SLACK_RAO >= tracked);
    }

    function test_CoversTracked_BoundaryAtTheSlack() public pure {
        uint256 tracked = 1e9;

        assertTrue(VaultReads.coversTracked(tracked - VaultReads.TRACKED_SLACK_RAO, tracked));
        assertFalse(VaultReads.coversTracked(tracked - VaultReads.TRACKED_SLACK_RAO - 1, tracked));
    }

    // -------------------- Recovery-window arithmetic -----------------------------

    function testFuzz_IsWindowStanding_TracksTheDeadline(uint64 shortSince, uint256 window, uint256 at) public {
        shortSince = uint64(bound(shortSince, 0, type(uint64).max / 2));
        window = bound(window, 1, 365 days);
        at = bound(at, 1, type(uint128).max);
        vm.warp(at);

        bool expected = shortSince == 0 || at < uint256(shortSince) + window;
        assertEq(VaultReads.isWindowStanding(shortSince, window), expected);
    }

    function test_IsWindowStanding_EndsExactlyAtTheDeadline() public {
        uint64 shortSince = 1000;
        uint256 window = 3 hours;

        vm.warp(uint256(shortSince) + window - 1);
        assertTrue(this.callIsWindowStanding(shortSince, window));
        vm.warp(uint256(shortSince) + window);
        assertFalse(this.callIsWindowStanding(shortSince, window));
    }

    function test_IsWindowStanding_UnrecordedLossHasNoDeadline() public {
        vm.warp(type(uint128).max);

        assertTrue(VaultReads.isWindowStanding(0, 1));
    }

    // -------------------- Shortfall reporting ------------------------------------

    function test_FirstShortOf_ReportsTheFirstShortSlot() public pure {
        bool[] memory short = new bool[](3);
        short[1] = true;
        short[2] = true;

        assertEq(VaultReads.firstShortOf(short), 1);
    }

    function test_FirstShortOf_CoveredRecordReturnsSentinel() public pure {
        assertEq(VaultReads.firstShortOf(new bool[](3)), type(uint256).max);
        assertEq(VaultReads.firstShortOf(new bool[](0)), type(uint256).max);
    }

    function test_RequireIntact_PassesACoveredRecord() public view {
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _recordOfTwo();

        this.callRequireIntact(slots, backing, NETUID);
    }

    function test_RevertWhen_TheRecordHoldsAShortSlot() public {
        (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) = _recordOfTwo();
        backing.short[1] = true;

        vm.expectRevert(abi.encodeWithSelector(BackingShortfall.selector, NETUID, slots[1].active, slots[1].tracked));
        this.callRequireIntact(slots, backing, NETUID);
    }

    // -------------------- Validator-set resolution -------------------------------

    function test_ResolveValidators_ReturnsTheRegistrySet() public {
        bytes32[] memory hotkeys = new bytes32[](2);
        hotkeys[0] = HOTKEY_A;
        hotkeys[1] = HOTKEY_B;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        registry.setRaw(NETUID, hotkeys, weights);

        (bytes32[] memory outHotkeys, uint16[] memory outWeights) = this.callResolveValidators(registry, NETUID);

        assertEq(outHotkeys.length, 2);
        assertEq(outHotkeys[0], HOTKEY_A);
        assertEq(outWeights[1], 4000);
    }

    function test_RevertWhen_TheRegistryHasNoSet() public {
        vm.expectRevert(NoValidatorFound.selector);
        this.callResolveValidators(registry, NETUID);
    }

    function test_RevertWhen_TheRegistryReturnsMismatchedLengths() public {
        bytes32[] memory hotkeys = new bytes32[](2);
        hotkeys[0] = HOTKEY_A;
        hotkeys[1] = HOTKEY_B;
        registry.setRaw(NETUID, hotkeys, new uint16[](1));

        vm.expectRevert(ValidatorSetMalformed.selector);
        this.callResolveValidators(registry, NETUID);
    }

    // -------------------- Successor edges and balances ---------------------------

    function test_HotkeySuccessor_ReturnsTheRecordedEdge() public {
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(HOTKEY_A, NETUID, HOTKEY_B);

        assertEq(VaultReads.hotkeySuccessor(HOTKEY_A, NETUID), HOTKEY_B);
    }

    function test_HotkeySuccessor_MissingEdgeReadsAsNone() public view {
        assertEq(VaultReads.hotkeySuccessor(HOTKEY_A, NETUID), bytes32(0));
    }

    function test_HotkeySuccessor_SelfEdgeReadsAsNone() public {
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(HOTKEY_A, NETUID, HOTKEY_A);

        assertEq(VaultReads.hotkeySuccessor(HOTKEY_A, NETUID), bytes32(0));
    }

    function test_FetchBalances_ReadsEachHotkeysStake() public {
        MockStaking(STAKING_PRECOMPILE).setStake(HOTKEY_A, COLDKEY, NETUID, 5e9);
        MockStaking(STAKING_PRECOMPILE).setStake(HOTKEY_C, COLDKEY, NETUID, 7e9);
        bytes32[] memory hotkeys = new bytes32[](3);
        hotkeys[0] = HOTKEY_A;
        hotkeys[1] = HOTKEY_B;
        hotkeys[2] = HOTKEY_C;

        uint256[] memory balances = VaultReads.fetchBalances(hotkeys, COLDKEY, NETUID);

        assertEq(balances[0], 5e9);
        assertEq(balances[1], 0);
        assertEq(balances[2], 7e9);
    }

    // -------------------- Dissolution state --------------------------------------

    function test_IsIssuedForDissolvedSubnet_MatchingRegistrationReadsLive() public view {
        assertFalse(VaultReads.isIssuedForDissolvedSubnet(TOKEN_ID));
    }

    function test_IsIssuedForDissolvedSubnet_ReregisteredNetuidReadsDissolved() public {
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(NETUID, REGISTRATION_BLOCK + 1);
        assertTrue(VaultReads.isIssuedForDissolvedSubnet(TOKEN_ID));

        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(NETUID, 0);
        assertTrue(VaultReads.isIssuedForDissolvedSubnet(TOKEN_ID));
    }

    function test_IndexableTao_LiveSubnetYieldsTheUnreservedBalance() public view {
        assertEq(VaultReads.indexableTao(TOKEN_ID, 10e9, 4e9), 6e9);
        assertEq(VaultReads.indexableTao(TOKEN_ID, 4e9, 10e9), 0);
    }

    function test_IndexableTao_DissolvingSubnetYieldsNothing() public {
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setDissolving(NETUID, true);

        assertEq(VaultReads.indexableTao(TOKEN_ID, 10e9, 0), 0);
    }

    function test_IndexableTao_DissolvedTokenYieldsNothing() public {
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(NETUID, REGISTRATION_BLOCK + 1);

        assertEq(VaultReads.indexableTao(TOKEN_ID, 10e9, 0), 0);
    }

    function _recordOfTwo() private pure returns (VaultReads.Slot[] memory slots, VaultReads.Backing memory backing) {
        slots = new VaultReads.Slot[](2);
        slots[0] = VaultReads.Slot({ logical: HOTKEY_A, active: HOTKEY_A, tracked: 5e9, shortSince: 0 });
        slots[1] = VaultReads.Slot({ logical: HOTKEY_B, active: HOTKEY_C, tracked: 7e9, shortSince: 0 });
        backing.keys = VaultReads.activesOf(slots);
        backing.balances = new uint256[](2);
        backing.balances[0] = 5e9;
        backing.balances[1] = 7e9;
        backing.short = new bool[](2);
        backing.total = 12e9;
    }
}
