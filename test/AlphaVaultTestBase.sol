// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Test.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { MockStaking, CHAIN_MIN_STAKE, CHAIN_MIN_TRANSFER, CHAIN_NOMINATOR_MIN_STAKE } from "./mocks/MockStaking.sol";
import { MockAddressMapping } from "./mocks/MockAddressMapping.sol";
import { MockSubnetPrecompile } from "./mocks/MockSubnetPrecompile.sol";
import { MockAlpha } from "./mocks/MockAlpha.sol";
import { AttestationHelper } from "./helpers/AttestationHelper.sol";
import { AlphaVaultHarness } from "./AlphaVaultHarness.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { ADDRESS_MAPPING_PRECOMPILE } from "src/interfaces/IAddressMapping.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import { SUBNET_PRECOMPILE } from "src/interfaces/ISubnet.sol";

abstract contract AlphaVaultTestBase is AttestationHelper {
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event Deposited(address indexed user, uint256 indexed tokenId, uint256 assets, uint256 shares);

    AlphaVault public vault;
    DepositMailbox public mailboxLogic;
    SubnetClone public subnetLogic;
    ValidatorRegistry public registry;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public hotkey1 = keccak256("hotkey1");
    bytes32 public hotkey2 = keccak256("hotkey2");
    bytes32 public hotkey3 = keccak256("hotkey3");
    bytes32 public hotkey4 = keccak256("hotkey4");

    uint256 internal constant SIGNER_PK_1 = 0xA11CE;
    uint256 internal constant SIGNER_PK_2 = 0xB0B;
    uint256[] internal signerPks;

    string internal constant VAULT_URI = "https://api.tao20.io/{id}.json";

    uint256 public constant NETUID1 = 1;
    uint256 public constant NETUID2 = 2;

    uint16 public constant NETUID1_BPS_HK1 = 3334;
    uint16 public constant NETUID1_BPS_HK2 = 3333;
    uint16 public constant NETUID1_BPS_HK3 = 3333;

    uint16 public constant NETUID2_BPS_HK2 = 6000;
    uint16 public constant NETUID2_BPS_HK1 = 4000;

    uint16 public constant BPS_BASE = 10_000;

    // The simulated chain's dust threshold; aliased so the two can never drift.
    uint256 internal constant DUST_THRESHOLD = CHAIN_NOMINATOR_MIN_STAKE;

    uint256 public TOKEN1;
    uint256 public TOKEN2;

    function setUp() public virtual {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        vm.etch(ADDRESS_MAPPING_PRECOMPILE, address(new MockAddressMapping()).code);
        vm.etch(SUBNET_PRECOMPILE, address(new MockSubnetPrecompile()).code);
        vm.etch(ALPHA_PRECOMPILE, address(new MockAlpha()).code);
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(uint16(NETUID1), 100);
        MockSubnetPrecompile(SUBNET_PRECOMPILE).setRegisteredAt(uint16(NETUID2), 200);
        // Pre-fund so the staking precompile mock can credit native TAO back to callers.
        vm.deal(STAKING_PRECOMPILE, 1_000_000 ether);
        // etch copies code, not storage, so the sell rate starts 0/0 and any un-parameterized sell
        // panics on division; a 1:1 default keeps unrelated tests meaningful. The min-stake floor
        // and the dust-sweep threshold are seeded to the chain's live values for the same reason.
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(1, 1);
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(CHAIN_MIN_STAKE);
        MockStaking(STAKING_PRECOMPILE).setChainMinTransfer(CHAIN_MIN_TRANSFER);
        MockStaking(STAKING_PRECOMPILE).setNominatorMinRequiredStake(DUST_THRESHOLD);

        mailboxLogic = new DepositMailbox();
        subnetLogic = new SubnetClone();

        // vm.addr(SIGNER_PK_2) < vm.addr(SIGNER_PK_1); the registry requires sigs sorted
        // ascending by recovered address, so attestations sign in this order.
        signerPks.push(SIGNER_PK_2);
        signerPks.push(SIGNER_PK_1);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(signerPks[0]);
        signers[1] = vm.addr(signerPks[1]);
        registry = new ValidatorRegistry(address(this), signers, 2);

        // validatorRegistry is immutable, so it must exist before the vault is constructed.
        vault = _deployVault(address(registry));

        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        _setValidators(NETUID2, _hotkeys(hotkey2, hotkey1), _weights(NETUID2_BPS_HK2, NETUID2_BPS_HK1));

        TOKEN1 = vault.currentTokenId(NETUID1);
        TOKEN2 = vault.currentTokenId(NETUID2);
    }

    /// @dev `validatorRegistry` is immutable, so tests that need a different registry construct a
    ///      fresh vault against it rather than swapping it on the shared `vault`.
    function _deployVault(address _registry) internal returns (AlphaVault) {
        return AlphaVault(new AlphaVaultHarness(VAULT_URI, address(mailboxLogic), address(subnetLogic), _registry));
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

    /// @dev The salted hotkeys are disjoint from the named `hotkey1..4` fixtures, so a wide set and
    ///      the fixture set never collide.
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

    /// @dev Asserts the vault's stake on `hks` follows the even split, with the rounding remainder
    ///      on the last slot - the same way the vault assigns targets.
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
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneColdkey = _toSubstrate(cloneAddr);
        // Use the best validator hotkey for this subnet (matches what wrap will resolve)
        bytes32 hotkey = vault.getCurrentValidators(netuid)[0];
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, cloneColdkey, netuid, amount);
    }

    function _simulateAlphaDepositHotkey(address user, uint256 netuid, uint256 amount, bytes32 hotkey) internal {
        address cloneAddr = vault.getDepositAddress(user, netuid);
        bytes32 cloneColdkey = _toSubstrate(cloneAddr);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, cloneColdkey, netuid, amount);
    }

    function _simulateEmissions(uint256 netuid, uint256 extraAlpha) internal {
        uint256 currentStake = _getVaultStake(hotkey1, netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(netuid), netuid, currentStake + extraAlpha);
    }

    function _wrap(address user, uint256 netuid) internal {
        _wrapHotkey(user, netuid, vault.getCurrentValidators(netuid)[0]);
    }

    function _wrapHotkey(address user, uint256 netuid, bytes32 chosenHotkey) internal {
        vm.prank(user);
        vault.wrap(netuid, chosenHotkey);
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

    /// @dev Arranges a stake as settled history, resyncing the recorded expectations to match.
    ///      Tests modeling an off-record move set the mock stakes directly instead.
    function _setVaultStake(bytes32 hotkey, uint256 netuid, uint256 amount) internal {
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey, _subnetColdkey(netuid), netuid, amount);
        _resyncTracked(netuid);
    }

    function _setVaultStakes(uint256 netuid, uint256 a, uint256 b, uint256 c) internal returns (uint256 total) {
        bytes32 cloneColdkey = _subnetColdkey(netuid);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, netuid, a);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, cloneColdkey, netuid, b);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey3, cloneColdkey, netuid, c);
        total = a + b + c;
        _resyncTracked(netuid);
    }

    function _resyncTracked(uint256 netuid) internal {
        uint256 tokenId = vault.currentTokenId(netuid);
        AlphaVaultHarness(address(vault)).resyncTracked(tokenId, _subnetColdkey(netuid));
    }

    // Smallest share count whose pro-rata assets equal `targetAssets` under the share-price cushion.
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
        // The chain sold the position itself; the record treats that as settled history.
        AlphaVaultHarness(address(vault)).resyncTracked(tokenId, cloneColdkey);
    }

    function _simulateDissolutionCompleted(uint256 netuid) internal {
        _setRegBlock(netuid, 0);
        _setDissolving(netuid, false);
    }

    function _simulateNewNetworkRegistered(uint256 tokenId, uint64 newRegBlock, uint256 taoInClone) internal {
        _simulateTaoAwardedOnDissolution(tokenId, taoInClone);
        _setRegBlock(tokenId & 0xFFFF, newRegBlock);
    }

    /// @dev Dissolve leaves the registration block untouched; subtensor removes it only
    ///      partway through the asynchronous cleanup.
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
        // A sub-quantum chain price rounds to 0 at the EVM boundary while the chain floor still
        // binds at full precision - the real shape of a sub-1e-9 subnet.
        _setAlphaPrice(netuid, 0.5e9);
    }

    function _setRemoveStakeRate(uint256 num, uint256 denom) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(num, denom);
    }

    /// @dev Caps what one sell can swap; the rest of the request stays staked.
    function _setRemoveStakeCap(uint256 maxAlpha) internal {
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeCap(maxAlpha);
    }

    /// @dev Zero disables the chain's force-sweep of a sub-threshold remainder.
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

    function _simulateTransferToggleOn() internal {
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);
    }

    function _donateToClone(address clone, uint256 amount) internal {
        vm.deal(clone, clone.balance + amount);
    }

    // The claimable-TAO quote is a commitment: a nonzero quote pays exactly, a zero quote means
    // the claim reverts.
    function _claimQuotedAmount(address user, uint256 tokenId) internal returns (uint256 delivered) {
        uint256 quoted = vault.claimableTaoOf(user, tokenId);
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
}
