// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CloneBase } from "./CloneBase.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

contract SubnetClone is CloneBase {
    function moveStake(bytes32 fromHotkey, bytes32 toHotkey, uint256 netuid, uint256 amount) external onlyWrapper {
        if (amount > 0) {
            IStaking(STAKING_PRECOMPILE).moveStake(fromHotkey, toHotkey, netuid, netuid, amount);
        }
    }
}
