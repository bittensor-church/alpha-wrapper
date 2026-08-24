// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultMath
/// @notice Share arithmetic, token-id packing and validator-set logic shared by `AlphaVault` and
///         the read-only `AlphaVaultLens`, so a quote and the call it quotes can never drift.
library VaultMath {
    /// @dev Virtual shares/assets to prevent inflation attacks (ERC4626 pattern).
    uint256 internal constant VIRTUAL_SHARES = 1e9;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    /// @dev Claim-index scale.
    uint256 internal constant TAO_INDEX_PRECISION = 1e36;
    /// @dev Native TAO carries 9 decimals behind the 18-decimal EVM interface, so a value transfer
    ///      delivers only whole multiples of this quantum.
    uint256 internal constant TAO_NATIVE_QUANTUM = 1e9;

    function sharesFor(uint256 stake, uint256 supply, uint256 assets) internal pure returns (uint256) {
        return Math.mulDiv(assets, supply + VIRTUAL_SHARES, stake + VIRTUAL_ASSETS);
    }

    function assetsFor(uint256 stake, uint256 supply, uint256 shares) internal pure returns (uint256) {
        return (shares * (stake + VIRTUAL_ASSETS)) / (supply + VIRTUAL_SHARES);
    }

    function sumBalances(uint256[] memory balances) internal pure returns (uint256 total) {
        for (uint256 i; i < balances.length;) {
            total += balances[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Position of `hotkey` in `set`, or `type(uint256).max`.
    function indexOf(bytes32[] memory set, bytes32 hotkey) internal pure returns (uint256) {
        for (uint256 i; i < set.length;) {
            if (set[i] == hotkey) return i;
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }

    function keysHold(bytes32[] memory keys, uint256 from, uint256 to, bytes32 hotkey) internal pure returns (bool) {
        for (uint256 i = from; i < to;) {
            if (keys[i] == hotkey) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Shrinks an array its caller allocated by rewriting only its length word.
    function truncate(bytes32[] memory keys, uint256 size) internal pure {
        assembly ("memory-safe") {
            mstore(keys, size)
        }
    }

    function contains(bytes32[] memory set, bytes32 hotkey) internal pure returns (bool) {
        for (uint256 i; i < set.length;) {
            if (set[i] == hotkey) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Every slot the position may hold alpha on: the remembered set, then any current
    ///      validator not already in it.
    function unionSlots(bytes32[] memory lastSeen, bytes32[] memory current)
        internal
        pure
        returns (bytes32[] memory slots)
    {
        slots = new bytes32[](lastSeen.length + current.length);
        uint256 size = lastSeen.length;
        for (uint256 i; i < size;) {
            slots[i] = lastSeen[i];
            unchecked {
                ++i;
            }
        }
        // Both lists are individually duplicate-free: the registry rejects duplicate hotkeys within
        // a validator set, and the remembered set is a past copy of such a set. Only the overlap
        // between the two lists needs removing.
        for (uint256 i; i < current.length;) {
            if (!contains(lastSeen, current[i])) {
                slots[size] = current[i];
                unchecked {
                    ++size;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Only the length word of an array this function allocated is written, so no memory outside
        // it is touched.
        assembly ("memory-safe") {
            mstore(slots, size)
        }
    }

    function netuidOf(uint256 tokenId) internal pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(tokenId & 0xFFFF);
    }

    function registrationBlockOf(uint256 tokenId) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(tokenId >> 16);
    }

    /// @dev The part of a clone's `balance` not yet promised through the claim index:
    ///      assignable to the index while the subnet is live, and the redemption backing once it
    ///      is dissolved.
    function unreservedTao(uint256 balance, uint256 reserved) internal pure returns (uint256) {
        return balance > reserved ? balance - reserved : 0;
    }

    /// @dev A holder's share of a fixed pot, with none of the virtual offsets the live path
    ///      needs: a dissolved position's TAO refund cannot be inflated, so it divides plainly.
    function proRata(uint256 total, uint256 shares, uint256 supply) internal pure returns (uint256) {
        return (total * shares) / supply;
    }

    /// @dev A claim pays only what the recorded liability backs. Per-holder accruals floor
    ///      against a ceiling-rounded allocation, so summed entitlements can overstate the
    ///      liability by stray wei, and anything beyond it would draw on the dissolution backing.
    function backedEntitlement(uint256 entitlement, uint256 liability) internal pure returns (uint256) {
        return entitlement > liability ? liability : entitlement;
    }

    /// @dev Earned-but-unrecorded TAO: what the index credits an account above the level its debt
    ///      was last anchored at.
    function pendingTao(uint256 earned, uint256 debt) internal pure returns (uint256) {
        return earned > debt ? earned - debt : 0;
    }

    /// @dev Rounded down to what a native transfer can actually deliver. The remainder stays
    ///      reserved for the account instead of drifting back into the index.
    function toNativeQuantum(uint256 amount) internal pure returns (uint256) {
        return amount - amount % TAO_NATIVE_QUANTUM;
    }

    /// @dev TAO an account holding `balance` has earned in total at the given index level.
    function earnedAt(uint256 balance, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(balance, index, TAO_INDEX_PRECISION);
    }

    /// @dev The index and liability increases that folding `newTao` in at `supply` records.
    ///      Nothing is recorded at zero supply: with no holders there is no one to attribute the
    ///      arrival to, so it stays unreserved until shares exist again.
    ///      The liability is rounded up so every index increase moves it: a floored-to-zero
    ///      allocation would leave the same arrival re-countable on every later synchronization.
    ///      The product never exceeds newTao times the scale, so the ceiling cannot over-reserve.
    function syncAmounts(uint256 newTao, uint256 supply)
        internal
        pure
        returns (uint256 indexIncrease, uint256 liabilityIncrease)
    {
        if (supply == 0) return (0, 0);
        indexIncrease = Math.mulDiv(newTao, TAO_INDEX_PRECISION, supply);
        liabilityIncrease = Math.mulDiv(indexIncrease, supply, TAO_INDEX_PRECISION, Math.Rounding.Ceil);
    }
}
