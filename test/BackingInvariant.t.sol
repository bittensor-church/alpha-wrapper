// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Tests that random sequences of deposits, exits, rebalances, validator hotkey swaps, registry
// rotations and recoveries never leave two record slots leaning on one balance, and never let the
// position report more backing than the chain actually holds under its coldkey.

import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

contract BackingHandler is Test {
    AlphaVault public immutable vault;
    BackingInvariantTest public immutable harness;
    uint256 public immutable tokenId;
    uint256 public immutable netuid;
    address[] public actors;

    /// @dev Every hotkey the run has ever staked under, so the harness can total the position's
    ///      real holding independently of anything the vault records.
    bytes32[] public touchedHotkeys;
    mapping(bytes32 => bool) public touched;

    constructor(
        AlphaVault _vault,
        BackingInvariantTest _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _seedHotkeys
    ) {
        vault = _vault;
        harness = _harness;
        tokenId = _tokenId;
        netuid = _netuid;
        actors = _actors;
        for (uint256 i; i < _seedHotkeys.length; ++i) {
            _remember(_seedHotkeys[i]);
        }
    }

    function _remember(bytes32 hotkey) internal {
        if (touched[hotkey]) return;
        touched[hotkey] = true;
        touchedHotkeys.push(hotkey);
    }

    function knownHotkeys() external view returns (bytes32[] memory) {
        return touchedHotkeys;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _attested(uint256 seed) private view returns (bytes32) {
        bytes32[] memory set = harness.attestedSet();
        return set[bound(seed, 0, set.length - 1)];
    }

    function wrap(uint256 actorSeed, uint256 amount, uint256 hotkeySeed) external {
        harness.wrapFor(_actor(actorSeed), bound(amount, 1 ether, 200 ether), _attested(hotkeySeed));
    }

    function unwrap(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        vm.prank(actor);
        try vault.unwrap(tokenId, bound(shareSeed, 1, balance), keccak256(abi.encode(actor))) { } catch { }
    }

    function unwrapForTao(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, bound(shareSeed, 1, balance), 0) { } catch { }
    }

    function rebalance() external {
        try vault.rebalance(netuid) { } catch { }
    }

    function syncBacking() external {
        try vault.syncBacking(tokenId) { } catch { }
    }

    /// @dev A validator swapping its hotkey, as the chain records it: the stake moves and the
    ///      successor edge points at where it went.
    function swapHotkey(uint256 fromSeed, uint256 toSeed) external {
        bytes32 from = touchedHotkeys[bound(fromSeed, 0, touchedHotkeys.length - 1)];
        bytes32 to = keccak256(abi.encode("swapped", toSeed));
        _remember(to);
        harness.simulateSwap(from, to);
    }

    /// @dev The same move with no edge behind it - the shape a dust sweep and an erased swap trail
    ///      both leave.
    function swapWithoutAnEdge(uint256 fromSeed, uint256 toSeed) external {
        bytes32 from = touchedHotkeys[bound(fromSeed, 0, touchedHotkeys.length - 1)];
        bytes32 to = keccak256(abi.encode("stray", toSeed));
        _remember(to);
        harness.simulateSilentMove(from, to);
    }

    function recoverStray(uint256 sourceSeed) external {
        if (vault.recordedSlots(tokenId).length == 0) return;
        bytes32 source = touchedHotkeys[bound(sourceSeed, 0, touchedHotkeys.length - 1)];
        bool[] memory coveredBefore = harness.coveredSlots();
        try vault.recoverStray(tokenId, source) {
            bool[] memory coveredAfter = harness.coveredSlots();
            bool hadShort;
            bool healedOne;
            for (uint256 i; i < coveredBefore.length; ++i) {
                assertTrue(!coveredBefore[i] || coveredAfter[i], "recovery left a covered slot short");
                if (!coveredBefore[i]) {
                    hadShort = true;
                    if (coveredAfter[i]) healedOne = true;
                }
            }
            assertTrue(!hadShort || healedOne, "a successful recovery healed no slot");
        } catch { }
    }

    function rotateValidators(uint256 seed) external {
        bytes32[] memory set = new bytes32[](bound(seed, 1, 3));
        for (uint256 i; i < set.length; ++i) {
            set[i] = touchedHotkeys[bound(uint256(keccak256(abi.encode(seed, i))), 0, touchedHotkeys.length - 1)];
            // The registry rejects duplicates, so a repeat picks a fresh name instead.
            for (uint256 j; j < i; ++j) {
                if (set[j] == set[i]) set[i] = keccak256(abi.encode("rotated", seed, i));
            }
            _remember(set[i]);
        }
        harness.attest(set);
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 4 hours));
    }
}

contract BackingInvariantTest is AlphaVaultTestBase {
    BackingHandler internal handler;
    bytes32[] internal currentSet;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](2);
        actors[0] = alice;
        actors[1] = bob;
        _depositAndWrap(alice, NETUID1, 50 ether);

        currentSet = _hotkeys(hotkey1, hotkey2, hotkey3);
        bytes32[] memory seeds = _hotkeys(hotkey1, hotkey2, hotkey3);
        handler = new BackingHandler(vault, this, TOKEN1, NETUID1, actors, seeds);
        targetContract(address(handler));
    }

    function attestedSet() external view returns (bytes32[] memory) {
        return currentSet;
    }

    /// @dev Which slots the resolver can currently account for.
    function coveredSlots() external view returns (bool[] memory covered) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        covered = new bool[](slots.length);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        VaultReads.Backing memory backing = VaultReads.resolveBacking(slots, coldkey, uint16(NETUID1));
        for (uint256 i; i < slots.length; ++i) {
            covered[i] = !backing.short[i];
        }
    }

    function wrapFor(address user, uint256 amount, bytes32 hotkey) external {
        _simulateAlphaDepositHotkey(user, NETUID1, amount, hotkey);
        vm.prank(user);
        try vault.wrap(NETUID1, hotkey, 0) { } catch { }
    }

    function simulateSwap(bytes32 from, bytes32 to) external {
        _simulateFollowedSwap(NETUID1, from, to);
    }

    function simulateSilentMove(bytes32 from, bytes32 to) external {
        _simulateOffVaultSwap(NETUID1, from, to);
    }

    function attest(bytes32[] memory set) external {
        uint16[] memory weights = new uint16[](set.length);
        uint16 assigned;
        for (uint256 i; i + 1 < set.length; ++i) {
            weights[i] = uint16(BPS_BASE / set.length);
            assigned += weights[i];
        }
        weights[set.length - 1] = BPS_BASE - assigned;
        _setValidators(NETUID1, set, weights);
        currentSet = set;
    }

    /// @dev The property the record exists to hold: one balance backs one expectation. Two slots
    ///      naming one key would report that balance twice and price exits against backing that is
    ///      not there.
    function invariant_NoTwoSlotsAnswerForOneKey() public view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "two slots answer for one key");
            }
        }
    }

    /// @dev What the position reports can fall short of what the chain holds - that is a loss being
    ///      chased - but it may never exceed it.
    function invariant_ReportedBackingNeverExceedsWhatTheChainHolds() public view {
        uint256 held;
        bytes32[] memory keys = handler.knownHotkeys();
        for (uint256 i; i < keys.length; ++i) {
            held += _getVaultStake(keys[i], NETUID1);
        }
        assertLe(lens.locatedStake(TOKEN1), held, "the position reports backing the chain does not hold");
    }

    /// @dev Every expectation the record still stands behind has to be one the chain could still
    ///      satisfy, or the write-off would give up on more than ever went missing.
    function invariant_NoSlotIsOwedMoreThanTheChainEverHeld() public view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        uint256 owed;
        for (uint256 i; i < slots.length; ++i) {
            owed += slots[i].tracked;
        }
        uint256 held;
        bytes32[] memory keys = handler.knownHotkeys();
        for (uint256 i; i < keys.length; ++i) {
            held += _getVaultStake(keys[i], NETUID1);
        }
        assertLe(owed, held + VaultReads.TRACKED_SLACK_RAO * slots.length, "the record expects more than exists");
    }
}
