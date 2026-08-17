// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockAlpha } from "./MockAlpha.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";

/// @dev The simulated chain's minimum for unstaking. `vm.etch` copies only code, so every suite
///      that etches this mock must seed both minimums - an unseeded zero silently accepts amounts
///      the chain would reject.
uint256 constant CHAIN_MIN_STAKE = 2e6;

/// @dev The simulated chain's minimum for shifting stake inside a subnet, twenty times lower than
///      the unstake minimum above. Apart, they let a test tell the vault's refusals from the chain's.
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
    /// @dev Floors the unstake rail, and the only minimum the chain exposes a getter for.
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
        if (hotkeyDeleted[hotkey]) {
            _fail("MockStaking: HotKeyAccountNotExists");
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
        if (hotkeyDeleted[destination_hotkey]) {
            _fail("MockStaking: HotKeyAccountNotExists");
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

    /// @dev A full hotkey rename deletes the old key's account on chain, after which any stake
    ///      operation naming it as a destination is rejected.
    mapping(bytes32 => bool) public hotkeyDeleted;

    function setHotkeyDeleted(bytes32 hotkey, bool deleted) external {
        hotkeyDeleted[hotkey] = deleted;
    }

    mapping(bytes32 => mapping(uint256 => bytes32)) private _successor;
    mapping(bytes32 => mapping(uint256 => bool)) private _successorSet;

    function setHotkeySuccessor(bytes32 from, uint256 netuid, bytes32 to) external {
        _successor[from][netuid] = to;
        _successorSet[from][netuid] = true;
    }

    /// @dev Models a chain build that predates the rename getter, where the probe reverts.
    bool public successorGetterReverts;

    function setSuccessorGetterReverts(bool v) external {
        successorGetterReverts = v;
    }

    /// @dev The mock never folds an absent entry to self; the caller does, matching the chain.
    function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool, bytes32) {
        require(!successorGetterReverts, "MockStaking: Unknown selector");
        return (_successorSet[hotkey][netuid], _successor[hotkey][netuid]);
    }

    function getHotkeyOwner(bytes32 hotkey) external view returns (bool, bytes32) {
        require(!successorGetterReverts, "MockStaking: Unknown selector");
        return (!hotkeyDeleted[hotkey], hotkeyDeleted[hotkey] ? bytes32(0) : bytes32(uint256(1)));
    }

    uint256 public taoPerAlpha;
    uint256 public taoPerAlphaDenom;
    bool public removeStakeReverts;
    mapping(bytes32 => bool) public removeStakeRevertsFor;
    uint256 public nominatorMinRequiredStake;
    /// @dev Most alpha one unstake can swap before the pool hits its price floor; 0 is uncapped.
    uint256 public removeStakeCap;

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

    function setRemoveStakeCap(uint256 maxAlpha) external {
        removeStakeCap = maxAlpha;
    }

    function removeStake(bytes32 hotkey, uint256 alphaAmount, uint256 netuid) external payable {
        if (removeStakeReverts || removeStakeRevertsFor[hotkey]) {
            _fail("MockStaking: removeStake reverted");
        }
        uint256 staked = stakes[hotkey][_senderColdkey()][netuid];
        // Unit seam: proceeds are credited 1:1 (rao as wei) for test readability; the real chain
        // credits rao * 1e9 wei. Wei-denominated payouts are asserted by the e2e run.
        // As on the chain, a capped swap leaves the rest of the request staked.
        uint256 consumed = removeStakeCap != 0 && alphaAmount > removeStakeCap ? removeStakeCap : alphaAmount;
        uint256 taoOut = quoteTaoOut(consumed);
        // As on the chain, the floor binds only when stake remains, and is checked before the swap.
        if (alphaAmount != staked && quoteTaoOut(alphaAmount) < _chainMinStakeTao) {
            _fail("MockStaking: AmountTooLow");
        }
        uint256 remainder = staked - consumed;
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
