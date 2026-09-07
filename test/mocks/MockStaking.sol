// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MockAlpha } from "./MockAlpha.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";

/// @dev Fixtures must seed minimums after `vm.etch`, which copies code but not storage.
uint256 constant CHAIN_MIN_STAKE = 2e6;

uint256 constant CHAIN_MIN_TRANSFER = 1e5;

uint256 constant CHAIN_NOMINATOR_MIN_STAKE = 20e6;

/// @dev Uses keccak256, not Frontier's blake2b; amounts are simplified for unit tests.
contract MockStaking {
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stakes;
    uint256 public moveStakeRoundingLoss;
    uint256 public transferStakeRoundingLoss;
    bool public transferStakeReverts;
    bool public consumeAllGasOnFailure;
    bool public nativeTaoUnits;
    uint256 private _chainMinStakeTao;

    uint256 private _chainMinTransferTao;

    function setTransferStakeReverts(bool v) external {
        transferStakeReverts = v;
    }

    function setConsumeAllGasOnFailure(bool v) external {
        consumeAllGasOnFailure = v;
    }

    /// @dev Enable the precompile's RAO-to-EVM conversion without changing the quote's RAO units.
    function setNativeTaoUnits(bool enabled) external {
        nativeTaoUnits = enabled;
    }

    // Real precompile rejection consumes forwarded gas; plain Solidity revert would refund it.
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

    // Chain minimums use full-precision prices even when the EVM reader rounds to zero.
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
            _fail("MockStaking: hotkey has no owner");
        }
        if (_belowMinTransfer(amount, origin_netuid)) {
            _fail("MockStaking: AmountTooLow");
        }
        stakes[hotkey][_senderColdkey()][origin_netuid] -= amount;
        uint256 credited = amount > transferStakeRoundingLoss ? amount - transferStakeRoundingLoss : 0;
        stakes[hotkey][destination_coldkey][destination_netuid] += credited;
    }

    function setTransferStakeRoundingLoss(uint256 loss) external {
        transferStakeRoundingLoss = loss;
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
        if (hotkeyDeleted[origin_hotkey] || hotkeyDeleted[destination_hotkey]) {
            _fail("MockStaking: hotkey has no owner");
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

    /// @dev Models a missing owner record, not deletion of the hotkey identifier or its stake.
    mapping(bytes32 => bool) public hotkeyDeleted;

    function setHotkeyDeleted(bytes32 hotkey, bool deleted) external {
        hotkeyDeleted[hotkey] = deleted;
    }

    /// @dev Seed owner presence separately from balances so tests can model ownerless stake.
    mapping(bytes32 => bool) private _hotkeyOwned;

    function setHotkeyOwned(bytes32 hotkey, bool owned) external {
        _hotkeyOwned[hotkey] = owned;
    }

    function getHotkeyOwner(bytes32 hotkey) external view returns (bool, bytes32) {
        bool exists = _hotkeyOwned[hotkey] && !hotkeyDeleted[hotkey];
        return (exists, exists ? keccak256(abi.encodePacked("owner:", hotkey)) : bytes32(0));
    }

    mapping(bytes32 => mapping(uint256 => bytes32)) private _successor;
    mapping(bytes32 => mapping(uint256 => bool)) private _successorSet;

    function setHotkeySuccessor(bytes32 from, uint256 netuid, bytes32 to) external {
        _successor[from][netuid] = to;
        _successorSet[from][netuid] = true;
    }

    function clearHotkeySuccessor(bytes32 hotkey, uint256 netuid) external {
        delete _successor[hotkey][netuid];
        delete _successorSet[hotkey][netuid];
    }

    function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool, bytes32) {
        return (_successorSet[hotkey][netuid], _successor[hotkey][netuid]);
    }

    uint256 public taoPerAlpha;
    uint256 public taoPerAlphaDenom;
    bool public removeStakeReverts;
    mapping(bytes32 => bool) public removeStakeRevertsFor;
    uint256 public nominatorMinRequiredStake;
    /// @dev Zero means uncapped.
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
        if (hotkeyDeleted[hotkey]) {
            _fail("MockStaking: hotkey has no owner");
        }
        uint256 staked = stakes[hotkey][_senderColdkey()][netuid];
        // Legacy arithmetic fixtures credit one wei per TAO RAO. Native-unit campaigns enable 1e9 below.
        uint256 consumed = removeStakeCap != 0 && alphaAmount > removeStakeCap ? removeStakeCap : alphaAmount;
        uint256 taoOut = quoteTaoOut(consumed);
        if (alphaAmount != staked && quoteTaoOut(alphaAmount) < _chainMinStakeTao) {
            _fail("MockStaking: AmountTooLow");
        }
        uint256 remainder = staked - consumed;
        // A dust remainder is force-sold into this payout; standalone fixtures may omit the alpha mock
        // when the threshold is zero.
        if (remainder != 0 && nominatorMinRequiredStake != 0) {
            if (_belowTaoValue(remainder, netuid, nominatorMinRequiredStake)) {
                taoOut += quoteTaoOut(remainder);
                remainder = 0;
            }
        }
        stakes[hotkey][_senderColdkey()][netuid] = remainder;
        (bool ok,) = msg.sender.call{ value: nativeTaoUnits ? taoOut * 1e9 : taoOut }("");
        require(ok, "MockStaking: TAO credit failed");
    }
}
