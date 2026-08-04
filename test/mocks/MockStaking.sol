// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockAlpha } from "./MockAlpha.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";

/// @dev The simulated chain's minimum for unstaking. `vm.etch` copies only code, so every suite
///      that etches this mock must seed both minimums - an unseeded zero silently accepts amounts
///      the chain would reject.
uint256 constant CHAIN_MIN_STAKE = 2e6;

/// @dev The simulated chain's minimum for shifting stake inside a subnet - twenty times lower than
///      what it floors an unstake at. Keeping the two apart is what lets a test tell a refusal the
///      vault chose from one the chain would really make.
uint256 constant CHAIN_MIN_TRANSFER = 1e5;

/// @dev The simulated chain's nominator dust threshold; aliased by the test base the same way.
uint256 constant CHAIN_NOMINATOR_MIN_STAKE = 20e6;

/// @dev Uses keccak256("evm:", h160) for coldkey derivation instead of the real
///      blake2b, matching the test helper `_toSubstrate`.
contract MockStaking {
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stakes;
    uint256 public moveStakeRoundingLoss;
    bool public transferStakeReverts;
    bool public consumeAllGasOnFailure;
    /// @dev Floors the unstake rail. This is the only one the chain exposes a getter for, so it is
    ///      also the one the vault applies everywhere - deliberately over-refusing on the rails
    ///      below, which clear a much lower bar.
    uint256 private _chainMinStakeTao;

    /// @dev Floors moves and transfers within a subnet.
    uint256 private _chainMinTransferTao;

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

    // Thresholds are tao-denominated: the chain values alpha at the chain-side (full-precision)
    // price, which is unaffected by the EVM getAlphaPrice quantization, so a sub-1e-9 subnet whose
    // EVM price reads 0 still has binding chain thresholds. Price is scaled 1e18 to match the
    // precompile.
    function _belowTaoValue(uint256 amount, uint256 netuid, uint256 thresholdTao) private view returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 alphaPriceE18 = MockAlpha(ALPHA_PRECOMPILE).chainAlphaPrice(uint16(netuid));
        return (amount * alphaPriceE18) / 1e18 < thresholdTao;
    }

    function setChainMinStake(uint256 minStakeTao) external {
        _chainMinStakeTao = minStakeTao;
    }

    function setChainMinTransfer(uint256 minTransferTao) external {
        _chainMinTransferTao = minTransferTao;
    }

    function getDefaultMinStake() external view returns (uint256) {
        return _chainMinStakeTao;
    }

    function _belowMinTransfer(uint256 amount, uint256 netuid) private view returns (bool) {
        return _belowTaoValue(amount, netuid, _chainMinTransferTao);
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
        if (_belowMinTransfer(amount, origin_netuid)) {
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
        if (_belowMinTransfer(amount, origin_netuid)) {
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
    uint256 public nominatorMinRequiredStake;

    function setNominatorMinRequiredStake(uint256 thresholdTao) external {
        nominatorMinRequiredStake = thresholdTao;
    }

    function getNominatorMinRequiredStake() external view returns (uint256) {
        return nominatorMinRequiredStake;
    }

    function setRemoveStakeRate(uint256 num, uint256 denom) external {
        taoPerAlpha = num;
        taoPerAlphaDenom = denom;
    }

    /// @notice The one payout formula behind removeStake, the sweep, and the alpha mock's sim
    ///         quotes, so they cannot drift apart.
    function quoteTaoOut(uint256 alpha) public view returns (uint256) {
        return (alpha * taoPerAlpha) / taoPerAlphaDenom;
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
        uint256 taoOut = quoteTaoOut(alphaAmount);
        // As on the chain, the floor binds only when stake remains after the unstake.
        if (alphaAmount != staked && taoOut < _chainMinStakeTao) {
            _fail("MockStaking: AmountTooLow");
        }
        uint256 remainder = staked - alphaAmount;
        // As on the chain, a remainder spot-valued below the nominator threshold is force-sold and
        // credited to the unstaker within the same call; a zero threshold disables the sweep. The
        // threshold gates first: standalone suites etch this mock alone, and only an armed sweep
        // may reach the alpha mock's price.
        if (remainder != 0 && nominatorMinRequiredStake != 0) {
            if (_belowTaoValue(remainder, netuid, nominatorMinRequiredStake)) {
                taoOut += quoteTaoOut(remainder);
                remainder = 0;
            }
        }
        stakes[hotkey][_senderColdkey()][netuid] = remainder;
        (bool ok,) = msg.sender.call{ value: taoOut }("");
        require(ok, "MockStaking: TAO credit failed");
    }
}
