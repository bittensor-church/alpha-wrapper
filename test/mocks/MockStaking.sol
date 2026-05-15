// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Uses keccak256("evm:", h160) for coldkey derivation instead of the real
///      blake2b, matching the test helper `_toSubstrate`.
contract MockStaking {
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stakes;
    uint256 public moveStakeRoundingLoss;
    uint256 public minStake;

    error AmountTooLow(uint256 amount, uint256 floor);

    function setStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) external {
        stakes[hotkey][coldkey][netuid] = amount;
    }

    function setMinStake(uint256 floor) external {
        minStake = floor;
    }

    function _senderColdkey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", msg.sender));
    }

    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        if (minStake > 0 && amount < minStake) revert AmountTooLow(amount, minStake);
        stakes[hotkey][_senderColdkey()][origin_netuid] -= amount;
        stakes[hotkey][destination_coldkey][destination_netuid] += amount;
    }

    function setMoveStakeRoundingLoss(uint256 loss) external {
        moveStakeRoundingLoss = loss;
    }

    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        if (minStake > 0 && amount < minStake) revert AmountTooLow(amount, minStake);
        stakes[origin_hotkey][_senderColdkey()][origin_netuid] -= amount;
        stakes[destination_hotkey][_senderColdkey()][destination_netuid] += amount - moveStakeRoundingLoss;
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return stakes[hotkey][coldkey][netuid];
    }
}
