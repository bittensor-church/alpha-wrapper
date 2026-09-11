// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { INeuron, NEURON_PRECOMPILE } from "../interfaces/INeuron.sol";
import { CloneBase } from "../CloneBase.sol";
import { SubnetClone } from "../SubnetClone.sol";
import { VaultMath } from "./VaultMath.sol";

/// @dev Stake movement through vault-controlled accounts, and the floor tests that keep an amount the
///      chain would refuse from burning the gas forwarded to it. Compiled into each caller.
library StakeOps {
    function taoValue(uint256 alphaAmount, uint256 alphaPriceE18) internal pure returns (uint256) {
        return (alphaAmount * alphaPriceE18) / VaultMath.ALPHA_PRICE_SCALE;
    }

    /// @dev The only exposed minimum is for unstakes; using it for transfers/moves is conservative.
    function minStakeTao() internal view returns (uint256) {
        return IStaking(STAKING_PRECOMPILE).getDefaultMinStake();
    }

    function hasOwner(bytes32 hotkey) internal view returns (bool exists) {
        (exists,) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
    }

    /// @notice Claims an ownerless hotkey for the caller's own coldkey; an existing owner stays untouched.
    /// @dev The chain refuses to move stake through a hotkey with no owner record.
    function ensureHotkeyHasOwner(bytes32 hotkey) internal {
        if (!hasOwner(hotkey)) INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey);
    }

    function move(address clone, bytes32 fromHotkey, bytes32 toHotkey, uint16 netuid, uint256 amount) internal {
        ensureHotkeyHasOwner(fromHotkey);
        ensureHotkeyHasOwner(toHotkey);
        SubnetClone(payable(clone)).moveStake(fromHotkey, toHotkey, netuid, amount);
    }

    function flush(address holder, bytes32 hotkey, bytes32 destinationColdkey, uint16 netuid, uint256 amount) internal {
        ensureHotkeyHasOwner(hotkey);
        CloneBase(payable(holder)).flush(destinationColdkey, hotkey, netuid, amount);
    }

    function sell(address holder, bytes32 hotkey, uint16 netuid, uint256 amount) internal {
        ensureHotkeyHasOwner(hotkey);
        CloneBase(payable(holder)).sellAlphaForTao(hotkey, netuid, amount);
    }

    /// @dev Use where the amount must clear the floor at the price just read, such as sizing a payout.
    ///      A rounded-down price can reject a valid amount; zero proves nothing and full unstakes bypass this.
    function isBelowFloorAtReadPrice(uint256 alphaAmount, uint256 alphaPriceE18) internal view returns (bool) {
        return alphaPriceE18 != 0 && taoValue(alphaAmount, alphaPriceE18) < minStakeTao();
    }

    /// @dev Use where refusing a movable amount would be worse than attempting it: rejects only an amount
    ///      below the floor even at the upper bound hidden by price rounding.
    function isBelowFloorAtAnyPrice(uint256 alphaAmount, uint256 alphaPriceE18) internal view returns (bool) {
        return
            alphaPriceE18 != 0
                && taoValue(alphaAmount, alphaPriceE18 + VaultMath.ALPHA_PRICE_QUANTUM_E18) < minStakeTao();
    }
}
