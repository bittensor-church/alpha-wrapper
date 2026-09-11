// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { CloneBase } from "src/CloneBase.sol";
import { CloneFactory } from "src/CloneFactory.sol";
import { IAlpha, ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import {
    CloneContaminated,
    CloneProtectionFailed,
    LockedDeposit,
    LockedBacking,
    MailboxNotPrepared,
    SubnetCloneNotPrepared
} from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract LockedAlphaDepositTest is AlphaVaultTestBase {
    MockStaking internal mock;
    uint256 internal constant MAX_CANDIDATES = 4;

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
    }

    function _create(address user) private returns (address mailbox, address clone) {
        vm.prank(user);
        return vault.createMailbox(NETUID1);
    }

    /// @dev Mirrors the factory's derivation so a test can poison a candidate before creation.
    function _candidate(address implementation, bytes32 family, uint256 index) private view returns (address) {
        bytes32 salt = keccak256(abi.encode(family, blockhash(block.number - 1), index));
        return Clones.predictDeterministicAddress(implementation, salt, address(vault.cloneFactory()));
    }

    function _mailboxCandidate(address user, uint256 index) private view returns (address) {
        bytes32 family = keccak256(abi.encode("mailbox-v1", user, NETUID1));
        return _candidate(vault.cloneFactory().mailboxLogic(), family, index);
    }

    function _cloneCandidate(uint256 index) private view returns (address) {
        bytes32 family = keccak256(abi.encode("subnet-v1", TOKEN1));
        return _candidate(vault.cloneFactory().subnetLogic(), family, index);
    }

    function _assertProtected(address clone) private view {
        bytes32 coldkey = _toSubstrate(clone);
        (bool exists, bytes32 owner) = mock.getHotkeyOwner(coldkey);
        assertTrue(exists);
        assertEq(owner, coldkey, "a clone owns its own account as a hotkey");
        assertTrue(mock.getRejectLockedAlpha(coldkey));
        assertEq(mock.rejectLockedAlphaCalls(coldkey), 0, "creation must not dispatch a redundant flag write");
        bytes32[] memory owned = mock.getOwnedHotkeys(coldkey);
        assertEq(owned.length, 1);
        assertEq(owned[0], coldkey);
    }

    function test_CreateMailbox_PreparesBothBeforePublishingAddresses() public {
        assertEq(vault.getDepositAddress(alice, NETUID1), address(0));
        assertEq(vault.subnetClone(TOKEN1), address(0));
        (address mailbox, address clone) = _create(alice);
        assertEq(mailbox, _mailboxCandidate(alice, 0));
        assertEq(clone, _cloneCandidate(0));
        assertEq(vault.getDepositAddress(alice, NETUID1), mailbox);
        assertEq(vault.subnetClone(TOKEN1), clone);
        assertEq(CloneBase(payable(mailbox)).wrapper(), address(vault));
        assertEq(CloneBase(payable(clone)).wrapper(), address(vault));
        _assertProtected(mailbox);
        _assertProtected(clone);
    }

    function test_CreateMailbox_RejectsUnexpectedAcceptFlagWithoutOverwritingIt() public {
        address mailbox = _mailboxCandidate(alice, 0);
        address clone = _cloneCandidate(0);
        mock.setAcceptsLockedAlpha(_toSubstrate(mailbox), true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneProtectionFailed.selector, mailbox));
        vault.createMailbox(NETUID1);
        assertEq(mailbox.code.length, 0);
        assertEq(clone.code.length, 0, "failed protection rolls back both deployments");
        assertEq(vault.getDepositAddress(alice, NETUID1), address(0));
        assertEq(vault.subnetClone(TOKEN1), address(0));
        assertFalse(mock.getRejectLockedAlpha(_toSubstrate(mailbox)));
    }

    function test_Wrap_ReadsAlphaPriceOnce() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        vm.expectCall(ALPHA_PRECOMPILE, abi.encodeCall(IAlpha.getAlphaPrice, (uint16(NETUID1))), 1);
        _wrap(alice, NETUID1);
        assertGt(vault.balanceOf(alice, TOKEN1), 0);
    }

    function test_CreateMailbox_ReusesSharedCloneAndExistingAddresses() public {
        (address aliceMailbox, address clone) = _create(alice);
        (address bobMailbox, address shared) = _create(bob);
        assertEq(shared, clone);
        assertTrue(aliceMailbox != bobMailbox);
        (address sameMailbox, address sameClone) = _create(alice);
        assertEq(sameMailbox, aliceMailbox);
        assertEq(sameClone, clone);
        _assertProtected(bobMailbox);
    }

    function test_CreateMailbox_NewGenerationReusesMailboxButCreatesNewSubnetClone() public {
        (address mailbox, address oldClone) = _create(alice);
        _reregisterSubnet(NETUID1);
        (address sameMailbox, address newClone) = _create(alice);
        assertEq(sameMailbox, mailbox);
        assertTrue(newClone != oldClone);
        assertEq(vault.subnetClone(TOKEN1), oldClone);
        _assertProtected(newClone);
    }

    function test_RevertWhen_WrappingBeforePreparation() public {
        vm.prank(alice);
        vm.expectRevert(SubnetCloneNotPrepared.selector);
        vault.wrap(NETUID1, hotkey1, 0);
        _create(bob);
        vm.prank(alice);
        vm.expectRevert(MailboxNotPrepared.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_CreateMailbox_SkipsAPreclaimedMailboxCandidate() public {
        address poisoned = _mailboxCandidate(alice, 0);
        mock.setHotkeyOwner(_toSubstrate(poisoned), _toSubstrate(bob));
        (address mailbox, address clone) = _create(alice);
        assertEq(mailbox, _mailboxCandidate(alice, 1));
        assertEq(clone, _cloneCandidate(0));
        assertEq(poisoned.code.length, 0);
        _assertProtected(mailbox);
    }

    function test_CreateMailbox_SkipsAPreclaimedSubnetCloneCandidate() public {
        address poisoned = _cloneCandidate(0);
        mock.setHotkeyOwner(_toSubstrate(poisoned), _toSubstrate(bob));
        (, address clone) = _create(alice);
        assertEq(clone, _cloneCandidate(1));
        assertEq(poisoned.code.length, 0);
        _assertProtected(clone);
    }

    function test_CreateMailbox_SkipsASwappedCandidateWithoutCurrentLock() public {
        mock.setColdkeyRoot(_toSubstrate(_cloneCandidate(0)), _toSubstrate(bob));
        (, address clone) = _create(alice);
        assertEq(clone, _cloneCandidate(1));
    }

    function test_CreateMailbox_SkipsACandidateOwningOtherHotkeys() public {
        mock.setHotkeyOwner(hotkey5, _toSubstrate(_cloneCandidate(0)));
        (, address clone) = _create(alice);
        assertEq(clone, _cloneCandidate(1));
    }

    function test_CreateMailbox_RevertsWhenEveryFreshCandidateIsPoisoned() public {
        for (uint256 index; index < MAX_CANDIDATES; ++index) {
            mock.setHotkeyOwner(_toSubstrate(_cloneCandidate(index)), _toSubstrate(bob));
        }
        address last = _cloneCandidate(MAX_CANDIDATES - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneContaminated.selector, last));
        vault.createMailbox(NETUID1);
        address stale = _cloneCandidate(0);
        vm.roll(block.number + 1);
        assertTrue(_cloneCandidate(0) != stale, "candidates change with the block hash");
        (, address clone) = _create(alice);
        assertEq(clone, _cloneCandidate(0));
        _assertProtected(clone);
    }

    /// @dev Stake and conviction may use different hotkeys; neither may enter backing through a poisoned candidate.
    function test_LockOnDifferentHotkey_CannotBecomeTheSubnetClone() public {
        bytes32 coldkey = _toSubstrate(_cloneCandidate(0));
        mock.setStake(hotkey5, coldkey, NETUID1, 40 ether);
        mock.setLockedAlpha(coldkey, NETUID1, hotkey1, 40 ether);
        (, address clone) = _create(alice);
        assertEq(clone, _cloneCandidate(1));
        _depositAndWrap(alice, NETUID1, 40 ether);
        _depositAndWrap(bob, NETUID1, 1 ether);
        assertEq(lens.totalStake(TOKEN1), 41 ether);
        assertGt(vault.balanceOf(alice, TOKEN1), vault.balanceOf(bob, TOKEN1));
        assertEq(mock.getStake(hotkey5, coldkey, NETUID1), 40 ether, "skipped gift never enters backing");
    }

    function test_PostDeployment_EmptyClonesRejectColdkeySwaps() public {
        (address mailbox, address clone) = _create(alice);
        vm.expectRevert(bytes("MockStaking: NewColdKeyIsHotkey"));
        mock.simulateColdkeySwap(_toSubstrate(bob), _toSubstrate(mailbox), NETUID1, _hotkeys(hotkey1));
        vm.expectRevert(bytes("MockStaking: NewColdKeyIsHotkey"));
        mock.simulateColdkeySwap(_toSubstrate(bob), _toSubstrate(clone), NETUID1, _hotkeys(hotkey1));
    }

    function test_PostDeployment_TaoOnlyAndFullyExitedCloneStaysProtected() public {
        (, address clone) = _create(alice);
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.deal(clone, 1 ether);
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 0);
        vm.expectRevert(bytes("MockStaking: NewColdKeyIsHotkey"));
        mock.simulateColdkeySwap(_toSubstrate(bob), _toSubstrate(clone), NETUID1, _hotkeys(hotkey1));
        _assertProtected(clone);
    }

    function test_PostDeployment_LockedTransfersToEitherCloneAreRefused() public {
        (address mailbox, address clone) = _create(alice);
        bytes32 donor = _toSubstrate(bob);
        mock.setStake(hotkey1, donor, NETUID1, 10 ether);
        mock.setLockedAlpha(donor, NETUID1, hotkey1, 10 ether);
        vm.startPrank(bob);
        vm.expectRevert(bytes("MockStaking: AccountRejectsLockedAlpha"));
        mock.transferStake(_toSubstrate(mailbox), hotkey1, NETUID1, NETUID1, 10 ether);
        vm.expectRevert(bytes("MockStaking: AccountRejectsLockedAlpha"));
        mock.transferStake(_toSubstrate(clone), hotkey1, NETUID1, NETUID1, 10 ether);
        vm.stopPrank();
    }

    function test_UnexpectedMailboxLock_RefusesWrapBeforeStakeMoves() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        mock.setLockedAlpha(_mailboxColdkey(alice, NETUID1), NETUID1, hotkey5, 1);
        vm.expectCall(STAKING_PRECOMPILE, abi.encodeWithSelector(IStaking.transferStake.selector), 0);
        vm.prank(alice);
        vm.expectRevert(LockedDeposit.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_UnexpectedBackingLock_RefusesPricingInsteadOfDiscounting() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 40 ether);
        _simulateAlphaDeposit(bob, NETUID1, 1 ether);
        mock.setLockedAlpha(_subnetColdkey(NETUID1), NETUID1, hotkey5, 1);
        vm.expectRevert(LockedBacking.selector);
        lens.totalStake(TOKEN1);
        vm.prank(bob);
        vm.expectRevert(LockedBacking.selector);
        vault.wrap(NETUID1, hotkey1, 0);
        vm.prank(alice);
        vm.expectRevert(LockedBacking.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        vm.prank(alice);
        vm.expectRevert(LockedBacking.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_FactoryCannotBeUsedToDeployAnotherUsersMailbox() public {
        CloneFactory factory = vault.cloneFactory();
        vm.prank(bob);
        vm.expectRevert(CloneFactory.NotVault.selector);
        factory.deployMailbox(alice, uint16(NETUID1));
    }
}
