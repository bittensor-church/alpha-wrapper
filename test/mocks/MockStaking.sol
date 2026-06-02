// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMockAlphaPrice {
    function getAlphaPrice(uint16 netuid) external view returns (uint256);
}

/// @dev Uses keccak256("evm:", h160) for coldkey derivation instead of the real
///      blake2b, matching the test helper `_toSubstrate`.
contract MockStaking {
    address private constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
    uint256 private constant MIN_STAKE = 2e6;

    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stakes;
    uint256 public moveStakeRoundingLoss;
    bool public transferStakeReverts;

    function setTransferStakeReverts(bool v) external {
        transferStakeReverts = v;
    }

    function setStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) external {
        stakes[hotkey][coldkey][netuid] = amount;
    }

    function _senderColdkey() private view returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", msg.sender));
    }

    // Mirrors subtensor transfer_stake_within_subnet: tao_equivalent = alpha * price, no bypass.
    function _belowMinStake(uint256 amount, uint256 netuid) private view returns (bool) {
        uint256 priceE18 = IMockAlphaPrice(ALPHA_PRECOMPILE).getAlphaPrice(uint16(netuid));
        return (amount * priceE18) / 1e18 < MIN_STAKE;
    }

    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        if (transferStakeReverts) {
            revert("MockStaking: transferStake reverted");
        }
        if (_belowMinStake(amount, origin_netuid)) {
            revert("MockStaking: AmountTooLow");
        }
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
        if (_belowMinStake(amount, origin_netuid)) {
            revert("MockStaking: AmountTooLow");
        }
        stakes[origin_hotkey][_senderColdkey()][origin_netuid] -= amount;
        stakes[destination_hotkey][_senderColdkey()][destination_netuid] += amount - moveStakeRoundingLoss;
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return stakes[hotkey][coldkey][netuid];
    }

    uint256 public taoPerAlpha;
    uint256 public taoPerAlphaDenom;
    bool public removeStakeReverts;

    function setRemoveStakeRate(uint256 num, uint256 denom) external {
        taoPerAlpha = num;
        taoPerAlphaDenom = denom;
    }

    function setRemoveStakeReverts(bool v) external {
        removeStakeReverts = v;
    }

    function removeStake(bytes32 hotkey, uint256 alphaAmount, uint256 netuid) external payable {
        if (removeStakeReverts) {
            revert("MockStaking: removeStake reverted");
        }
        stakes[hotkey][_senderColdkey()][netuid] -= alphaAmount;
        uint256 taoOut = (alphaAmount * taoPerAlpha) / taoPerAlphaDenom;
        (bool ok,) = msg.sender.call{ value: taoOut }("");
        require(ok, "MockStaking: TAO credit failed");
    }
}
