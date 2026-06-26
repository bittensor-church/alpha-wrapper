// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm, stdStorage, StdStorage } from "forge-std/Test.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockAddressMapping } from "./mocks/MockAddressMapping.sol";
import { MockStorageQuery } from "./mocks/MockStorageQuery.sol";
import { AttestationHelper } from "./helpers/AttestationHelper.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { ADDRESS_MAPPING_PRECOMPILE } from "src/interfaces/IAddressMapping.sol";

address constant STORAGE_QUERY = 0x0000000000000000000000000000000000000807;

abstract contract AlphaVaultTestBase is AttestationHelper {
    using stdStorage for StdStorage;

    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event MinRebalanceAmtUpdated(uint256 oldValue, uint256 newValue);
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);

    AlphaVault public vault;
    DepositMailbox public mailboxLogic;
    SubnetClone public subnetLogic;
    ValidatorRegistry public registry;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public hotkey1 = keccak256("hotkey1");
    bytes32 public hotkey2 = keccak256("hotkey2");
    bytes32 public hotkey3 = keccak256("hotkey3");
    bytes32 public hotkey4 = keccak256("hotkey4");

    uint256 internal constant SIGNER_PK_1 = 0xA11CE;
    uint256 internal constant SIGNER_PK_2 = 0xB0B;
    uint256[] internal signerPks;

    uint256 public constant NETUID1 = 1;
    uint256 public constant NETUID2 = 2;

    uint16 public constant NETUID1_BPS_HK1 = 3334;
    uint16 public constant NETUID1_BPS_HK2 = 3333;
    uint16 public constant NETUID1_BPS_HK3 = 3333;

    uint16 public constant NETUID2_BPS_HK2 = 6000;
    uint16 public constant NETUID2_BPS_HK1 = 4000;

    uint16 public constant BPS_BASE = 10_000;

    uint256 public TOKEN1;
    uint256 public TOKEN2;

    function setUp() public virtual {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        vm.etch(ADDRESS_MAPPING_PRECOMPILE, address(new MockAddressMapping()).code);
        vm.etch(STORAGE_QUERY, address(new MockStorageQuery()).code);
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(NETUID1), 100);
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(NETUID2), 200);
        // Pre-fund so the staking precompile mock can credit native TAO back to callers.
        vm.deal(STAKING_PRECOMPILE, 1_000_000 ether);

        mailboxLogic = new DepositMailbox();
        subnetLogic = new SubnetClone();
        vault = new AlphaVault("https://api.tao20.io/{id}.json", address(mailboxLogic), address(subnetLogic));

        // vm.addr(SIGNER_PK_2) < vm.addr(SIGNER_PK_1); the registry requires sigs sorted
        // ascending by recovered address, so attestations sign in this order.
        signerPks.push(SIGNER_PK_2);
        signerPks.push(SIGNER_PK_1);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(signerPks[0]);
        signers[1] = vm.addr(signerPks[1]);
        registry = new ValidatorRegistry(address(this), signers, 2);
        vault.setValidatorRegistry(address(registry));

        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        _setValidators(NETUID2, _hotkeys(hotkey2, hotkey1), _weights(NETUID2_BPS_HK2, NETUID2_BPS_HK1));

        TOKEN1 = vault.currentTokenId(NETUID1);
        TOKEN2 = vault.currentTokenId(NETUID2);
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
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneSub = _toSubstrate(cloneAddr);
        // Use the best validator hotkey for this subnet (matches what wrap will resolve)
        bytes32 hotkey = vault.getBestValidators(netuid)[0];
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, cloneSub, netuid, amount);
    }

    function _simulateAlphaDepositHotkey(address user, uint256 netuid, uint256 amount, bytes32 hotkey) internal {
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneSub = _toSubstrate(cloneAddr);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, cloneSub, netuid, amount);
    }

    /// @dev Simulate validator emissions accruing on the subnet clone's staked alpha: bump the
    ///      on-chain stake under hotkey1 and the vault's cached totalStake[tokenId] by `extraAlpha`.
    function _simulateEmissions(uint256 netuid, uint256 extraAlpha) internal {
        uint256 currentStake = _getVaultStake(hotkey1, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, currentStake + extraAlpha);
        uint256 tokenId = vault.currentTokenId(netuid);
        stdstore.target(address(vault)).sig("totalStake(uint256)").with_key(tokenId)
            .checked_write(vault.totalStake(tokenId) + extraAlpha);
    }

    function _wrap(address user, uint256 netuid) internal {
        _wrapHotkey(user, netuid, vault.getBestValidators(netuid)[0]);
    }

    function _wrapHotkey(address user, uint256 netuid, bytes32 chosenHotkey) internal {
        vm.prank(user);
        vault.wrap(user, netuid, chosenHotkey);
    }

    function _getStake(bytes32 hotkey, address who, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _toSubstrate(who), netuid);
    }

    function _subnetColdkey(uint256 netuid) internal view returns (bytes32) {
        return _toSubstrate(vault.subnetClone(vault.currentTokenId(netuid)));
    }

    function _getVaultStake(bytes32 hotkey, uint256 netuid) internal view returns (uint256) {
        return MockStaking(STAKING_PRECOMPILE).getStake(hotkey, _subnetColdkey(netuid), netuid);
    }

    function _totalVaultStakeAcrossHotkeys(uint256 netuid) internal view returns (uint256) {
        uint256 total;
        total += _getVaultStake(hotkey1, netuid);
        total += _getVaultStake(hotkey2, netuid);
        total += _getVaultStake(hotkey3, netuid);
        return total;
    }

    function _setRegBlock(uint256 netuid, uint64 blockNum) internal {
        MockStorageQuery(STORAGE_QUERY).setRegisteredAt(uint16(netuid), blockNum);
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
        uint16[] memory empty = new uint16[](0);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(empty);
    }

    function _simulateNewNetworkRegistered(uint256 tokenId, uint64 newRegBlock, uint256 taoInClone) internal {
        _simulateTaoAwardedOnDissolution(tokenId, taoInClone);
        _setRegBlock(tokenId & 0xFFFF, newRegBlock);
    }

    function _simulateDissolutionStarted(uint256 tokenId, uint64 newRegBlock) internal {
        uint256 netuid = tokenId & 0xFFFF;
        _setRegBlock(netuid, newRegBlock);
        uint16[] memory queue = new uint16[](1);
        queue[0] = uint16(netuid);
        MockStorageQuery(STORAGE_QUERY).setDissolvedNetworks(queue);
    }

    function _setRemoveStakeRate(uint256 num, uint256 denom) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(num, denom);
    }

    function _setRemoveStakeReverts(bool v) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeReverts(v);
    }

    function _simulateTransferToggleOn() internal {
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);
    }

    function _donateToClone(address clone, uint256 amount) internal {
        vm.deal(clone, clone.balance + amount);
    }

    function _expectedTaoFor(uint256 alpha) internal view returns (uint256) {
        uint256 num = MockStaking(STAKING_PRECOMPILE).taoPerAlpha();
        uint256 denom = MockStaking(STAKING_PRECOMPILE).taoPerAlphaDenom();
        return (alpha * num) / denom;
    }

    function _weighted(uint256 total, uint16 bps) internal pure returns (uint256) {
        return (total * bps) / BPS_BASE;
    }
}
