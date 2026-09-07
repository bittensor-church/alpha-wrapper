// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library VaultMath {
    /// @dev Virtual offsets limit first-depositor inflation.
    uint256 internal constant VIRTUAL_SHARES = 1e9;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 internal constant TAO_INDEX_PRECISION = 1e36;
    /// @dev Native transfers truncate EVM wei to whole RAO (1e9 wei).
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

    function contains(bytes32[] memory set, bytes32 hotkey) internal pure returns (bool) {
        for (uint256 i; i < set.length;) {
            if (set[i] == hotkey) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function indexOf(bytes32[] memory set, bytes32 hotkey) internal pure returns (uint256) {
        for (uint256 i; i < set.length;) {
            if (set[i] == hotkey) return i;
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }

    function netuidOf(uint256 tokenId) internal pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(tokenId & 0xFFFF);
    }

    function registrationBlockOf(uint256 tokenId) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(tokenId >> 16);
    }

    function unreservedTao(uint256 balance, uint256 reserved) internal pure returns (uint256) {
        return balance > reserved ? balance - reserved : 0;
    }

    /// @dev A fixed dissolution refund needs no virtual offsets: deposits can no longer inflate it.
    function proRata(uint256 total, uint256 shares, uint256 supply) internal pure returns (uint256) {
        return (total * shares) / supply;
    }

    /// @dev Cap rounding residue at recorded liability so claims cannot consume dissolution backing.
    function backedEntitlement(uint256 entitlement, uint256 liability) internal pure returns (uint256) {
        return entitlement > liability ? liability : entitlement;
    }

    function pendingTao(uint256 earned, uint256 debt) internal pure returns (uint256) {
        return earned > debt ? earned - debt : 0;
    }

    function toNativeQuantum(uint256 amount) internal pure returns (uint256) {
        return amount - amount % TAO_NATIVE_QUANTUM;
    }

    function earnedAt(uint256 balance, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(balance, index, TAO_INDEX_PRECISION);
    }

    /// @dev Round liability up so a tiny index increase cannot leave the same TAO available to index again.
    ///      At zero supply, leave arrivals unassigned until shares exist.
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
