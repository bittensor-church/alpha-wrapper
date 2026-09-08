// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Test.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { MockStaking, CHAIN_MIN_STAKE, CHAIN_MIN_TRANSFER, CHAIN_NOMINATOR_MIN_STAKE } from "./mocks/MockStaking.sol";
import { MockAddressMapping } from "./mocks/MockAddressMapping.sol";
import { MockSubnetPrecompile } from "./mocks/MockSubnetPrecompile.sol";
import { MockAlpha } from "./mocks/MockAlpha.sol";
import { MockNeuron } from "./mocks/MockNeuron.sol";
import { AttestationHelper } from "./helpers/AttestationHelper.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { ADDRESS_MAPPING_PRECOMPILE } from "src/interfaces/IAddressMapping.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import { NEURON_PRECOMPILE } from "src/interfaces/INeuron.sol";
import { SUBNET_PRECOMPILE } from "src/interfaces/ISubnet.sol";

abstract contract AlphaVaultTestBase is AttestationHelper {
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);
    event BackingShortfallDeclared(uint256 indexed tokenId, uint256 expected, uint256 located);
    event BackingShortfallCleared(uint256 indexed tokenId);
    event BackingWrittenOff(uint256 indexed tokenId, uint256 expected, uint256 located);
    event BackingParked(uint256 indexed tokenId, uint256 backing, uint256 registryNonce);
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed hotkey, uint256 amount);

    AlphaVault public vault;
    AlphaVaultLens public lens;
    DepositMailbox public mailboxLogic;
    SubnetClone public subnetLogic;
    ValidatorRegistry public registry;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public hotkey1 = keccak256("hotkey1");
    bytes32 public hotkey2 = keccak256("hotkey2");
    bytes32 public hotkey3 = keccak256("hotkey3");
    bytes32 public hotkey4 = keccak256("hotkey4");
    bytes32 public hotkey5 = keccak256("hotkey5");

    uint256 internal constant SIGNER_PK_1 = 0xA11CE;
    uint256 internal constant SIGNER_PK_2 = 0xB0B;
    uint256[] internal signerPks;

    string internal constant VAULT_URI = "https://api.tao20.io/{id}.json";
    uint256 internal constant RECOVERY_WINDOW = 3 hours;
    uint256 internal constant BACKING_SLACK_RAO = 1_000;
    bytes32 internal constant PARKING_HOTKEY = keccak256("parking-hotkey");

    uint256 public constant NETUID1 = 1;
    uint256 public constant NETUID2 = 2;

    uint16 public constant NETUID1_BPS_HK1 = 3334;
    uint16 public constant NETUID1_BPS_HK2 = 3333;
    uint16 public constant NETUID1_BPS_HK3 = 3333;

    uint16 public constant NETUID2_BPS_HK2 = 6000;
    uint16 public constant NETUID2_BPS_HK1 = 4000;

    uint16 public constant BPS_BASE = 10_000;

    uint256 internal constant DUST_THRESHOLD = CHAIN_NOMINATOR_MIN_STAKE;

    uint256 public TOKEN1;
    uint256 public TOKEN2;

    /// @dev Every vault claims its own parking hotkey; a second deployment needs an unclaimed one.
    uint256 private _vaultDeployments;

    function setUp() public virtual {
        _etchStakingMock();
        vm.etch(ADDRESS_MAPPING_PRECOMPILE, address(new MockAddressMapping()).code);
        vm.etch(SUBNET_PRECOMPILE, address(new MockSubnetPrecompile()).code);
        vm.etch(ALPHA_PRECOMPILE, address(new MockAlpha()).code);
        vm.etch(NEURON_PRECOMPILE, address(new MockNeuron()).code);
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(uint16(NETUID1), 100);
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(uint16(NETUID2), 200);
        vm.deal(STAKING_PRECOMPILE, 1_000_000 ether);
        // Etching copies code, not constructor storage; seed rates and chain thresholds explicitly.
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(1, 1);
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(CHAIN_MIN_STAKE);
        MockStaking(STAKING_PRECOMPILE).setChainMinTransfer(CHAIN_MIN_TRANSFER);
        MockStaking(STAKING_PRECOMPILE).setNominatorMinRequiredStake(DUST_THRESHOLD);

        mailboxLogic = new DepositMailbox();
        subnetLogic = new SubnetClone();

        // vm.addr(SIGNER_PK_2) < vm.addr(SIGNER_PK_1); registry signatures must be address-sorted.
        signerPks.push(SIGNER_PK_2);
        signerPks.push(SIGNER_PK_1);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(signerPks[0]);
        signers[1] = vm.addr(signerPks[1]);
        registry = new ValidatorRegistry(address(this), signers, 2);

        (vault, lens) = _deployVaultAndLens(address(registry));

        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        _setValidators(NETUID2, _hotkeys(hotkey2, hotkey1), _weights(NETUID2_BPS_HK2, NETUID2_BPS_HK1));

        TOKEN1 = vault.currentTokenId(NETUID1);
        TOKEN2 = vault.currentTokenId(NETUID2);
    }

    function _deployVaultAndLens(address _registry) internal returns (AlphaVault freshVault, AlphaVaultLens freshLens) {
        return _deployVaultAndLens(_registry, RECOVERY_WINDOW);
    }

    function _deployVaultAndLens(address _registry, uint256 recoveryWindow)
        internal
        returns (AlphaVault freshVault, AlphaVaultLens freshLens)
    {
        bytes32 parkingHotkey =
            _vaultDeployments == 0 ? PARKING_HOTKEY : keccak256(abi.encode(PARKING_HOTKEY, _vaultDeployments));
        _vaultDeployments++;
        freshVault = new AlphaVault(
            VAULT_URI, address(mailboxLogic), address(subnetLogic), _registry, recoveryWindow, parkingHotkey
        );
        freshLens = new AlphaVaultLens(freshVault);
    }

    function _setValidators(uint256 netuid, bytes32[] memory hks, uint16[] memory wts) internal {
        _submitAttestation(registry, netuid, hks, wts, signerPks);
    }

    function _hotkeys(bytes32 a) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = a;
    }

    function _hotkeys(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _hotkeys(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    function _weights(uint16 a) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = a;
    }

    function _weights(uint16 a, uint16 b) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _weights(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    /// @dev Salted hotkeys cannot collide with the named hotkey1..4 fixtures.
    function _setValidatorCount(uint256 netuid, uint256 count) internal returns (bytes32[] memory hks) {
        hks = _hotkeysFrom("validator", count);
        _setValidators(netuid, hks, _evenWeights(count));
    }

    function _stakeAcross(bytes32[] memory hks, bytes32 coldkey, uint256 netuid) internal view returns (uint256 total) {
        for (uint256 i; i < hks.length; ++i) {
            total += _getStakeForColdkey(hks[i], coldkey, netuid);
        }
    }

    function _vaultStakeAcross(bytes32[] memory hks, uint256 netuid) internal view returns (uint256) {
        return _stakeAcross(hks, _subnetColdkey(netuid), netuid);
    }

    function _assertEvenSpread(bytes32[] memory hks, uint256 netuid, uint256 total) internal view {
        uint16[] memory wts = _evenWeights(hks.length);
        uint256 assigned;
        for (uint256 i; i + 1 < hks.length; ++i) {
            assertEq(_getVaultStake(hks[i], netuid), _weighted(total, wts[i]), "slot off its weight");
            assigned += _weighted(total, wts[i]);
        }
        assertEq(_getVaultStake(hks[hks.length - 1], netuid), total - assigned, "last slot absorbs the remainder");
    }

    function _countRebalancedLogs(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 sig = keccak256("Rebalanced(uint256,bytes32,bytes32,uint256)");
        for (uint256 i; i < logs.length;) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) count++;
            unchecked {
                ++i;
            }
        }
    }

    function _toSubstrate(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", addr));
    }

    function _simulateAlphaDeposit(address user, uint256 netuid, uint256 amount) internal {
        _simulateAlphaDepositHotkey(user, netuid, amount, lens.getCurrentValidators(netuid)[0]);
    }

    function _simulateAlphaDepositHotkey(address user, uint256 netuid, uint256 amount, bytes32 hotkey) internal {
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneColdkey = _toSubstrate(cloneAddr);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        mock.setStake(hotkey, cloneColdkey, netuid, mock.getStake(hotkey, cloneColdkey, netuid) + amount);
    }

    function _simulateEmissions(uint256 netuid, uint256 extraAlpha) internal {
        uint256 currentStake = _getVaultStake(hotkey1, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, currentStake + extraAlpha);
    }

    function _wrap(address user, uint256 netuid) internal {
        _wrapHotkey(user, netuid, lens.getCurrentValidators(netuid)[0]);
    }

    function _wrapHotkey(address user, uint256 netuid, bytes32 chosenHotkey) internal {
        vm.prank(user);
        vault.wrap(netuid, chosenHotkey, 0);
    }

    function _getStake(bytes32 hotkey, address who, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _toSubstrate(who), netuid);
    }

    function _getStakeForColdkey(bytes32 hotkey, bytes32 coldkey, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, coldkey, netuid);
    }

    function _subnetColdkey(uint256 netuid) internal view returns (bytes32) {
        return _toSubstrate(vault.subnetClone(vault.currentTokenId(netuid)));
    }

    function _getVaultStake(bytes32 hotkey, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _subnetColdkey(netuid), netuid);
    }

    function _plantVaultStake(bytes32 hotkey, uint256 netuid, uint256 amount) internal {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        _plantVaultLayout(netuid, _hotkeys(hotkey), amounts);
    }

    function _plantVaultStakes(uint256 netuid, uint256 a, uint256 b, uint256 c) internal returns (uint256 total) {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = a;
        amounts[1] = b;
        amounts[2] = c;
        _plantVaultLayout(netuid, _hotkeys(hotkey1, hotkey2, hotkey3), amounts);
        return a + b + c;
    }

    /// @dev A mock balance below the record looks like missing backing, and the record only shrinks
    ///      through a write-off that parks the position and spreads it by weight on release. Empty the
    ///      record instead and put the layout back: the vault counts the surplus as backing.
    function _plantVaultLayout(uint256 netuid, bytes32[] memory hotkeys, uint256[] memory amounts) internal {
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        bytes32 cloneColdkey = _subnetColdkey(netuid);
        for (uint256 i; i < hotkeys.length; ++i) {
            mock.setStake(hotkeys[i], cloneColdkey, netuid, amounts[i]);
        }
        uint256 tokenId = vault.currentTokenId(netuid);
        if (lens.isBackingIntact(tokenId)) return;

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        uint256[] memory layout = new uint256[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            layout[i] = mock.getStake(slots[i].active, cloneColdkey, netuid);
            mock.setStake(slots[i].active, cloneColdkey, netuid, 0);
        }
        _catchRecordUpFor(tokenId);
        for (uint256 i; i < slots.length; ++i) {
            mock.setStake(slots[i].active, cloneColdkey, netuid, layout[i]);
        }
    }

    /// @dev Writes off whatever the record cannot find and releases the parked position onto the live
    ///      set; recovery tests must manipulate the mock without this helper.
    function _catchRecordUp(uint256 netuid) internal {
        _catchRecordUpFor(vault.currentTokenId(netuid));
    }

    function _catchRecordUpFor(uint256 tokenId) internal {
        if (lens.isBackingIntact(tokenId)) return;
        _runOutRecoveryWindow(tokenId);
        uint256 netuid = tokenId & 0xFFFF;
        _reattestCurrentSet(netuid);
        vault.rebalance(netuid);
    }

    /// @dev Lands the current set again under a new nonce, releasing a parked position.
    function _reattestCurrentSet(uint256 netuid) internal {
        (bytes32[] memory hks, uint16[] memory wts) = registry.getValidators(netuid);
        _setValidators(netuid, hks, wts);
    }

    function _sharesForExactAssets(uint256 tokenId, uint256 targetAssets, uint256 totalAlpha)
        internal
        view
        returns (uint256 shares)
    {
        uint256 scaledSupply = vault.totalSupply(tokenId) + 1e9;
        shares = (targetAssets * scaledSupply + totalAlpha) / (totalAlpha + 1);
        require((shares * (totalAlpha + 1)) / scaledSupply == targetAssets, "no share count hits target assets");
    }

    function _totalVaultStakeAcrossHotkeys(uint256 netuid) internal view returns (uint256) {
        uint256 total;
        total += _getVaultStake(hotkey1, netuid);
        total += _getVaultStake(hotkey2, netuid);
        total += _getVaultStake(hotkey3, netuid);
        return total;
    }

    function _userStakeAcrossHotkeys(bytes32 coldkey, uint256 netuid) internal view returns (uint256 total) {
        total += _getStakeForColdkey(hotkey1, coldkey, netuid);
        total += _getStakeForColdkey(hotkey2, coldkey, netuid);
        total += _getStakeForColdkey(hotkey3, coldkey, netuid);
        total += _getStakeForColdkey(hotkey4, coldkey, netuid);
    }

    function _userStakeAcrossHotkeys(address user, uint256 netuid) internal view returns (uint256) {
        return _userStakeAcrossHotkeys(_toSubstrate(user), netuid);
    }

    function _setRegBlock(uint256 netuid, uint64 blockNum) internal {
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(uint16(netuid), blockNum);
    }

    function _setDissolving(uint256 netuid, bool value) internal {
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setDissolving(uint16(netuid), value);
    }

    function _registerSubnet(uint256 netuid, bytes32 hotkey) internal {
        _setValidators(netuid, _hotkeys(hotkey), _weights(10_000));
        _setRegBlock(netuid, 300);
    }

    function _simulateTaoAwardedOnDissolution(uint256 tokenId, uint256 taoAmount) internal {
        address clone = vault.subnetClone(tokenId);
        bytes32 cloneColdkey = _toSubstrate(clone);
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        uint256 netuid = tokenId & 0xFFFF;
        mock.setStake(hotkey1, cloneColdkey, netuid, 0);
        mock.setStake(hotkey2, cloneColdkey, netuid, 0);
        mock.setStake(hotkey3, cloneColdkey, netuid, 0);
        mock.setStake(hotkey4, cloneColdkey, netuid, 0);
        vm.deal(clone, clone.balance + taoAmount);
    }

    function _simulateDissolutionCompleted(uint256 netuid) internal {
        _setRegBlock(netuid, 0);
        _setDissolving(netuid, false);
    }

    function _simulateNewNetworkRegistered(uint256 tokenId, uint64 newRegBlock, uint256 taoInClone) internal {
        _simulateTaoAwardedOnDissolution(tokenId, taoInClone);
        _setRegBlock(tokenId & 0xFFFF, newRegBlock);
    }

    /// @dev The registration block survives the start of asynchronous dissolution cleanup.
    function _simulateDissolutionStarted(uint256 netuid) internal {
        _setDissolving(netuid, true);
    }

    function _setAlphaPrice(uint256 netuid, uint256 alphaPriceE18) internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        MockAlpha(ALPHA_PRECOMPILE).setAlphaPrice(uint16(netuid), alphaPriceE18);
    }

    function _alphaPriceRead(uint256 netuid) internal view returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return MockAlpha(ALPHA_PRECOMPILE).getAlphaPrice(uint16(netuid));
    }

    function _setAlphaPriceReadsZero(uint256 netuid) internal {
        // The chain retains a nonzero price below the EVM reader's precision.
        _setAlphaPrice(netuid, 0.5e9);
    }

    function _setRemoveStakeRate(uint256 num, uint256 denom) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(num, denom);
    }

    function _setRemoveStakeCap(uint256 maxAlpha) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeCap(maxAlpha);
    }

    function _setDustThreshold(uint256 thresholdTao) internal {
        MockStaking(STAKING_PRECOMPILE).setNominatorMinRequiredStake(thresholdTao);
    }

    function _depositAndWrap(address user, uint256 netuid, uint256 amount) internal returns (uint256 shares) {
        _simulateAlphaDeposit(user, netuid, amount);
        _wrap(user, netuid);
        shares = vault.balanceOf(user, vault.currentTokenId(netuid));
    }

    function _setRemoveStakeReverts(bool v) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeReverts(v);
    }

    function _setRemoveStakeRevertsFor(bytes32 hotkey, bool v) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRevertsFor(hotkey, v);
    }

    function _disableAlphaTransfers() internal {
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);
    }

    function _donateToClone(address clone, uint256 amount) internal {
        vm.deal(clone, clone.balance + amount);
    }

    function _claimQuotedAmount(address user, uint256 tokenId) internal returns (uint256 delivered) {
        uint256 quoted = lens.claimableTaoOf(user, tokenId);
        if (quoted == 0) {
            vm.expectRevert();
            vm.prank(user);
            vault.claimTao(tokenId, payable(user));
            return 0;
        }
        uint256 balanceBefore = user.balance;
        vm.prank(user);
        vault.claimTao(tokenId, payable(user));
        delivered = user.balance - balanceBefore;
        assertEq(delivered, quoted);
    }

    function _expectedTaoFor(uint256 alpha) internal view returns (uint256) {
        uint256 num = MockStaking(STAKING_PRECOMPILE).taoPerAlpha();
        uint256 denom = MockStaking(STAKING_PRECOMPILE).taoPerAlphaDenom();
        return (alpha * num) / denom;
    }

    function _weighted(uint256 total, uint16 bps) internal pure returns (uint256) {
        return (total * bps) / BPS_BASE;
    }

    function _lastSeen(uint256 tokenId) internal view returns (bytes32[] memory) {
        return lens.lastSeenHotkeys(tokenId);
    }

    /// @dev Makes the ownership precompile report an owner for this hotkey.
    function _simulateHotkeyOwnerPresent(bytes32 hotkey) internal {
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey, false);
        _recordHotkeyOwner(hotkey);
    }

    /// @dev A validator's rename keeps its coldkey, so the successor answers to the attested owner.
    function _simulateSameOwner(bytes32 fromHotkey, bytes32 toHotkey) internal {
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        mock.setHotkeyDeleted(toHotkey, false);
        mock.setHotkeyOwner(toHotkey, mock.ownerOf(fromHotkey));
    }

    /// @dev A stranger claims the hotkey; its owner no longer matches the attested one.
    function _simulateSquatter(bytes32 hotkey) internal {
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwner(hotkey, keccak256(abi.encodePacked("squatter:", hotkey)));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey, false);
    }

    /// @dev Moves mock stake without changing the successor precompile's response.
    function _simulateOffVaultSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        require(fromHotkey != toHotkey, "swap needs distinct hotkeys");
        bytes32 coldkey = _subnetColdkey(netuid);
        uint256 amount = _getStakeForColdkey(fromHotkey, coldkey, netuid);
        uint256 alreadyThere = _getStakeForColdkey(toHotkey, coldkey, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(fromHotkey, coldkey, netuid, 0);
        MockStaking(STAKING_PRECOMPILE).setStake(toHotkey, coldkey, netuid, alreadyThere + amount);
        _simulateSameOwner(fromHotkey, toHotkey);
    }

    /// @dev The precompile reports a successor while the old hotkey still has an owner.
    function _simulatePerSubnetSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        _simulateOffVaultSwap(netuid, fromHotkey, toHotkey);
        MockStaking(STAKING_PRECOMPILE).clearHotkeySuccessor(toHotkey, netuid);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(fromHotkey, netuid, toHotkey);
    }

    /// @dev The precompile reports a successor and no owner for the old hotkey.
    function _simulateFollowedSwap(uint256 netuid, bytes32 fromHotkey, bytes32 toHotkey) internal {
        _simulatePerSubnetSwap(netuid, fromHotkey, toHotkey);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(fromHotkey, true);
    }

    function _buildSwapTrail(uint256 netuid, bytes32 fromHotkey, uint256 hops) internal returns (bytes32 tip) {
        bytes32 previous = fromHotkey;
        for (uint256 i; i < hops; ++i) {
            tip = keccak256(abi.encode("trail-hop", fromHotkey, i));
            MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(previous, netuid, tip);
            previous = tip;
        }
        _simulateOffVaultSwap(netuid, fromHotkey, tip);
    }

    function _wholeRao(uint256 amount) internal pure returns (uint256) {
        return amount / 1e9 * 1e9;
    }

    function _drainTheFirstSlot(address holder, uint256 netuid) internal {
        uint256 tokenId = vault.currentTokenId(netuid);
        bytes32 followed = vault.recordedSlots(tokenId)[0].active;
        uint256 burn =
            (vault.balanceOf(holder, tokenId) * (_getVaultStake(followed, netuid) + 1e15)) / lens.locatedStake(tokenId);
        vm.prank(holder);
        vault.unwrapForTao(tokenId, burn, 0);
        assertEq(_getVaultStake(followed, netuid), 0, "the slot has to be empty for this to mean anything");
    }

    /// @dev Declares the shortfall, waits out the window and writes it off, leaving the token parked.
    function _runOutRecoveryWindow(uint256 tokenId) internal {
        vault.syncBacking(tokenId);
        vm.warp(lens.frozenUntil(tokenId));
        vault.syncBacking(tokenId);
    }

    function _parkedStake(uint256 netuid) internal view returns (uint256) {
        return _getVaultStake(vault.parkingHotkey(), netuid);
    }

    function _sources(bytes32 a) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = a;
    }

    function _sources(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
