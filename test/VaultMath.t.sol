// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";

/// @dev Tests the share arithmetic, token-id packing and validator-set helpers that the vault and
///      its lens share.
contract VaultMathTest is Test {
    uint256 internal constant AMOUNT_CEILING = 1e30;
    /// @dev The vault's own domain: chain amounts are 64-bit RAO (STAKE_CEILING covers a full
    ///      64-validator position) and `wrap` refuses any mint that would push supply past the
    ///      cap, so the arithmetic is only ever asked about pairs inside these bounds.
    uint256 internal constant STAKE_CEILING = 64 * uint256(type(uint64).max);
    uint256 internal constant SUPPLY_CAP = VaultMath.TAO_NATIVE_QUANTUM * VaultMath.TAO_INDEX_PRECISION;

    // -------------------- Share arithmetic ---------------------------------------

    /// @dev The inflation-resistance guarantee: whatever the pre-existing stake and supply, a
    ///      deposit's shares can never be worth more than the deposit that minted them.
    function testFuzz_SharesFor_RoundTripNeverCreatesValue(uint256 stake, uint256 supply, uint256 assets) public pure {
        stake = bound(stake, 0, STAKE_CEILING);
        supply = bound(supply, 0, SUPPLY_CAP);
        assets = bound(assets, 0, type(uint64).max);

        uint256 shares = VaultMath.sharesFor(stake, supply, assets);
        if (supply + shares > SUPPLY_CAP) return;

        uint256 back = VaultMath.assetsFor(stake + assets, supply + shares, shares);

        assertLe(back, assets, "a mint-and-burn round trip paid out more than went in");
    }

    /// @dev Burning every real share pays at most the stake: the virtual offsets absorb the
    ///      rounding, never the holders.
    function testFuzz_AssetsFor_FullSupplyNeverExceedsStake(uint256 stake, uint256 supply) public pure {
        stake = bound(stake, 0, STAKE_CEILING);
        supply = bound(supply, 0, SUPPLY_CAP);

        assertLe(VaultMath.assetsFor(stake, supply, supply), stake, "burning all shares overdrew the stake");
    }

    function test_SharesFor_FirstDepositMintsAtVirtualParity() public pure {
        assertEq(VaultMath.sharesFor(0, 0, 5e9), 5e9 * VaultMath.VIRTUAL_SHARES);
    }

    function testFuzz_SharesFor_ZeroAssetsMintNothing(uint256 stake, uint256 supply) public pure {
        stake = bound(stake, 0, AMOUNT_CEILING);
        supply = bound(supply, 0, AMOUNT_CEILING);

        assertEq(VaultMath.sharesFor(stake, supply, 0), 0);
    }

    // -------------------- Token-id packing ---------------------------------------

    function testFuzz_TokenId_PacksAndUnpacks(uint16 netuid, uint64 registrationBlock) public pure {
        uint256 tokenId = (uint256(registrationBlock) << 16) | netuid;

        assertEq(VaultMath.netuidOf(tokenId), netuid);
        assertEq(VaultMath.registrationBlockOf(tokenId), registrationBlock);
    }

    // -------------------- Set helpers --------------------------------------------

    function testFuzz_IndexOf_FindsTheFirstOccurrence(uint256 length, uint256 target) public pure {
        length = bound(length, 1, 64);
        target = bound(target, 0, length - 1);
        bytes32[] memory set = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            set[i] = keccak256(abi.encode("hotkey", i));
        }

        assertEq(VaultMath.indexOf(set, set[target]), target);
        assertTrue(VaultMath.contains(set, set[target]));
    }

    function testFuzz_IndexOf_MissingKeyReturnsSentinel(uint256 length) public pure {
        length = bound(length, 0, 64);
        bytes32[] memory set = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            set[i] = keccak256(abi.encode("hotkey", i));
        }
        bytes32 absent = keccak256("absent");

        assertEq(VaultMath.indexOf(set, absent), type(uint256).max);
        assertFalse(VaultMath.contains(set, absent));
    }

    function test_SumBalances_EmptyArrayTotalsZero() public pure {
        assertEq(VaultMath.sumBalances(new uint256[](0)), 0);
    }

    function testFuzz_SumBalances_MatchesTheManualTotal(uint256[] memory balances) public pure {
        uint256 expected;
        for (uint256 i; i < balances.length; ++i) {
            balances[i] = bound(balances[i], 0, AMOUNT_CEILING);
            expected += balances[i];
        }

        assertEq(VaultMath.sumBalances(balances), expected);
    }

    // -------------------- Saturating helpers -------------------------------------

    function testFuzz_UnreservedTao_FloorsAtZero(uint256 balance, uint256 reserved) public pure {
        assertEq(VaultMath.unreservedTao(balance, reserved), balance - Math.min(balance, reserved));
    }

    function testFuzz_PendingTao_FloorsAtZero(uint256 earned, uint256 debt) public pure {
        assertEq(VaultMath.pendingTao(earned, debt), earned - Math.min(earned, debt));
    }

    function testFuzz_BackedEntitlement_CapsAtTheLiability(uint256 entitlement, uint256 liability) public pure {
        assertEq(VaultMath.backedEntitlement(entitlement, liability), Math.min(entitlement, liability));
    }

    // -------------------- Pro-rata and quantum -----------------------------------

    function testFuzz_ProRata_FullSupplyPaysTheWholePot(uint256 total, uint256 supply) public pure {
        total = bound(total, 0, AMOUNT_CEILING);
        supply = bound(supply, 1, AMOUNT_CEILING);

        assertEq(VaultMath.proRata(total, supply, supply), total);
    }

    function testFuzz_ProRata_NeverExceedsThePot(uint256 total, uint256 shares, uint256 supply) public pure {
        total = bound(total, 0, AMOUNT_CEILING);
        supply = bound(supply, 1, AMOUNT_CEILING);
        shares = bound(shares, 0, supply);

        assertLe(VaultMath.proRata(total, shares, supply), total);
    }

    function testFuzz_ToNativeQuantum_DropsLessThanOneQuantum(uint256 amount) public pure {
        uint256 delivered = VaultMath.toNativeQuantum(amount);

        assertLe(delivered, amount);
        assertEq(delivered % VaultMath.TAO_NATIVE_QUANTUM, 0);
        assertLt(amount - delivered, VaultMath.TAO_NATIVE_QUANTUM);
    }

    // -------------------- Claim-index synchronization ----------------------------

    function test_SyncAmounts_ZeroSupplyRecordsNothing() public pure {
        (uint256 indexIncrease, uint256 liabilityIncrease) = VaultMath.syncAmounts(1e18, 0);

        assertEq(indexIncrease, 0);
        assertEq(liabilityIncrease, 0);
    }

    /// @dev The ceiling-rounded liability moves with every index increase and stays within the
    ///      arrival, so repeated synchronizations can neither recount TAO nor over-reserve it.
    function testFuzz_SyncAmounts_LiabilityTracksTheIndex(uint256 newTao, uint256 supply) public pure {
        newTao = bound(newTao, 0, AMOUNT_CEILING);
        supply = bound(supply, 1, AMOUNT_CEILING);

        (uint256 indexIncrease, uint256 liabilityIncrease) = VaultMath.syncAmounts(newTao, supply);

        assertLe(liabilityIncrease, newTao, "the reservation exceeded the arrival");
        if (indexIncrease > 0) {
            assertGt(liabilityIncrease, 0, "an index increase left no liability behind");
        }
    }

    /// @dev Solvency of the claim index: what a sole holder of the entire supply earns from a
    ///      synchronization is covered by the liability it recorded.
    function testFuzz_SyncAmounts_LiabilityCoversASoleHolder(uint256 newTao, uint256 supply) public pure {
        newTao = bound(newTao, 0, AMOUNT_CEILING);
        supply = bound(supply, 1, AMOUNT_CEILING);

        (uint256 indexIncrease, uint256 liabilityIncrease) = VaultMath.syncAmounts(newTao, supply);

        assertLe(VaultMath.earnedAt(supply, indexIncrease), liabilityIncrease);
    }
}
