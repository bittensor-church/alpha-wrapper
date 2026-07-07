// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockAlpha } from "./MockAlpha.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";

/// @dev Uses keccak256("evm:", h160) for coldkey derivation instead of the real
///      blake2b, matching the test helper `_toSubstrate`.
contract MockStaking {
    /// @dev The chain's DefaultMinStake: exposed via getStakeOperationThreshold() and enforced by
    ///      every operation below, so the reported threshold and the real floor never diverge.
    ///      Etch-safe: vm.etch copies code but not constructor-initialized storage, so a zero
    ///      override reads as the default and the floor binds without a constructor run.
    uint256 private constant DEFAULT_MIN_STAKE = 2e6;
    uint256 public minStakeOverride;
    bool public stakeThresholdReverts;
    bool public stakeThresholdReadsZero;
    bool public stakeThresholdReturnsShort;

    function setStakeOperationThreshold(uint256 v) external {
        minStakeOverride = v;
    }

    /// @dev Model a runtime whose staking precompile predates getStakeOperationThreshold() (the
    ///      selector reverts). The chain still enforces the floor via the operation calls below.
    function setStakeThresholdReverts(bool v) external {
        stakeThresholdReverts = v;
    }

    /// @dev Model the view returning zero, exercising the vault's zero-read fallback while the
    ///      operations still enforce the real floor.
    function setStakeThresholdReadsZero(bool v) external {
        stakeThresholdReadsZero = v;
    }

    /// @dev Model a precompile that answers but returns a non-32-byte payload, exercising the
    ///      vault's length guard: it must fall back rather than let abi.decode revert the operation.
    function setStakeThresholdReturnsShort(bool v) external {
        stakeThresholdReturnsShort = v;
    }

    function _minStake() private view returns (uint256) {
        return minStakeOverride == 0 ? DEFAULT_MIN_STAKE : minStakeOverride;
    }

    function getStakeOperationThreshold() external view returns (uint256) {
        require(!stakeThresholdReverts, "MockStaking: getStakeOperationThreshold unimplemented");
        if (stakeThresholdReturnsShort) {
            // Non-32-byte answer: exercises the caller's length guard, which must fall back rather
            // than let abi.decode revert.
            assembly {
                mstore(0, 1)
                return(0, 4)
            }
        }
        return stakeThresholdReadsZero ? 0 : _minStake();
    }

    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stakes;
    uint256 public moveStakeRoundingLoss;
    bool public transferStakeReverts;
    bool public consumeAllGasOnFailure;

    function setTransferStakeReverts(bool v) external {
        transferStakeReverts = v;
    }

    function setConsumeAllGasOnFailure(bool v) external {
        consumeAllGasOnFailure = v;
    }

    // The real staking precompile surfaces a rejected dispatch as an EVM error, which consumes all
    // gas forwarded to its frame; a plain revert refunds it. Opt in when a test must observe the
    // gas consequences of a rejected call.
    function _fail(string memory reason) private view {
        if (consumeAllGasOnFailure) {
            assembly {
                invalid()
            }
        }
        revert(reason);
    }

    function setStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) external {
        stakes[hotkey][coldkey][netuid] = amount;
    }

    function _senderColdkey() private view returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", msg.sender));
    }

    // The floor is tao-denominated: the chain rejects transfers and moves whose tao value is below
    // MIN_STAKE. Reads the chain-side (full-precision) price, which is unaffected by the EVM
    // getAlphaPrice quantization, so a sub-1e-9 subnet whose EVM price reads 0 still has a binding
    // chain floor. Price is scaled 1e18 to match the precompile.
    function _belowMinStake(uint256 amount, uint256 netuid) private view returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 alphaPriceE18 = MockAlpha(ALPHA_PRECOMPILE).chainAlphaPrice(uint16(netuid));
        return (amount * alphaPriceE18) / 1e18 < _minStake();
    }

    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        if (transferStakeReverts) {
            _fail("MockStaking: transferStake reverted");
        }
        if (_belowMinStake(amount, origin_netuid)) {
            _fail("MockStaking: AmountTooLow");
        }
        stakes[hotkey][_senderColdkey()][origin_netuid] -= amount;
        stakes[hotkey][destination_coldkey][destination_netuid] += amount;
    }

    function setMoveStakeRoundingLoss(uint256 loss) external {
        moveStakeRoundingLoss = loss;
    }

    bool public moveStakeReverts;

    function setMoveStakeReverts(bool v) external {
        moveStakeReverts = v;
    }

    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        if (moveStakeReverts) {
            _fail("MockStaking: moveStake reverted");
        }
        if (_belowMinStake(amount, origin_netuid)) {
            _fail("MockStaking: AmountTooLow");
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
    mapping(bytes32 => bool) public removeStakeRevertsFor;

    function setRemoveStakeRate(uint256 num, uint256 denom) external {
        taoPerAlpha = num;
        taoPerAlphaDenom = denom;
    }

    function setRemoveStakeReverts(bool v) external {
        removeStakeReverts = v;
    }

    function setRemoveStakeRevertsFor(bytes32 hotkey, bool v) external {
        removeStakeRevertsFor[hotkey] = v;
    }

    function removeStake(bytes32 hotkey, uint256 alphaAmount, uint256 netuid) external payable {
        if (removeStakeReverts || removeStakeRevertsFor[hotkey]) {
            _fail("MockStaking: removeStake reverted");
        }
        uint256 staked = stakes[hotkey][_senderColdkey()][netuid];
        // Unit seam: proceeds are credited 1:1 (rao as wei) for test readability; the real chain
        // credits rao * 1e9 wei. Wei-denominated payouts are asserted by the e2e run.
        uint256 taoOut = (alphaAmount * taoPerAlpha) / taoPerAlphaDenom;
        // Mirrors subtensor validate_remove_stake: the floor binds only when stake remains after.
        if (alphaAmount != staked && taoOut < _minStake()) {
            _fail("MockStaking: AmountTooLow");
        }
        stakes[hotkey][_senderColdkey()][netuid] = staked - alphaAmount;
        (bool ok,) = msg.sender.call{ value: taoOut }("");
        require(ok, "MockStaking: TAO credit failed");
    }
}
