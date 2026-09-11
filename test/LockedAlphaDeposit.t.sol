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
    bytes32 internal constant UID = keccak256("random-uid-1");
    bytes32 internal constant NEXT_UID = keccak256("random-uid-2");

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
    }

    function _create(address user, bytes32 uid) private returns (address mailbox, address clone) {
        vm.prank(user);
        return vault.createMailbox(NETUID1, uid);
    }

    /// @dev Mirrors the factory's derivation so a test can poison a candidate before creation.
    function _mailboxCandidate(address user, bytes32 uid) private view returns (address) {
        bytes32 salt = keccak256(abi.encode("mailbox-v1", user, NETUID1, uid));
        return
            Clones.predictDeterministicAddress(vault.cloneFactory().mailboxLogic(), salt, address(vault.cloneFactory()));
    }

    function _cloneCandidate(bytes32 uid) private view returns (address) {
        bytes32 salt = keccak256(abi.encode("subnet-v1", TOKEN1, uid));
        return
            Clones.predictDeterministicAddress(vault.cloneFactory().subnetLogic(), salt, address(vault.cloneFactory()));
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
        (address mailbox, address clone) = _create(alice, UID);
        assertEq(mailbox, _mailboxCandidate(alice, UID));
        assertEq(clone, _cloneCandidate(UID));
        assertEq(vault.getDepositAddress(alice, NETUID1), mailbox);
        assertEq(vault.subnetClone(TOKEN1), clone);
        assertEq(CloneBase(payable(mailbox)).wrapper(), address(vault));
        assertEq(CloneBase(payable(clone)).wrapper(), address(vault));
        _assertProtected(mailbox);
        _assertProtected(clone);
    }

    function test_CreateMailbox_RejectsUnexpectedAcceptFlagWithoutOverwritingIt() public {
        address mailbox = _mailboxCandidate(alice, UID);
        address clone = _cloneCandidate(UID);
        mock.setAcceptsLockedAlpha(_toSubstrate(mailbox), true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneProtectionFailed.selector, mailbox));
        vault.createMailbox(NETUID1, UID);
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

    function test_CreateMailbox_ReusesSharedCloneAndIgnoresLaterUidForExistingAddresses() public {
        (address aliceMailbox, address clone) = _create(alice, UID);
        (address bobMailbox, address shared) = _create(bob, NEXT_UID);
        assertEq(shared, clone);
        assertTrue(aliceMailbox != bobMailbox);
        (address sameMailbox, address sameClone) = _create(alice, NEXT_UID);
        assertEq(sameMailbox, aliceMailbox);
        assertEq(sameClone, clone);
        _assertProtected(bobMailbox);
    }

    function test_CreateMailbox_NewGenerationReusesMailboxButCreatesNewSubnetClone() public {
        (address mailbox, address oldClone) = _create(alice, UID);
        _reregisterSubnet(NETUID1);
        (address sameMailbox, address newClone) = _create(alice, UID);
        assertEq(sameMailbox, mailbox);
        assertTrue(newClone != oldClone);
        assertEq(vault.subnetClone(TOKEN1), oldClone);
        _assertProtected(newClone);
    }

    function test_RevertWhen_WrappingBeforePreparation() public {
        vm.prank(alice);
        vm.expectRevert(SubnetCloneNotPrepared.selector);
        vault.wrap(NETUID1, hotkey1, 0);
        _create(bob, UID);
        vm.prank(alice);
        vm.expectRevert(MailboxNotPrepared.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_CreateMailbox_RevertsOnAPreclaimedMailboxCandidateAndRetriesWithAFreshUid() public {
        address candidate = _mailboxCandidate(alice, UID);
        mock.setHotkeyOwner(_toSubstrate(candidate), _toSubstrate(bob));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneContaminated.selector, candidate));
        vault.createMailbox(NETUID1, UID);
        assertEq(vault.subnetClone(TOKEN1), address(0));
        assertEq(_cloneCandidate(UID).code.length, 0, "failed mailbox rolls back the shared deployment");
        assertEq(vault.getDepositAddress(alice, NETUID1), address(0));
        (address accepted,) = _create(alice, NEXT_UID);
        assertEq(accepted, _mailboxCandidate(alice, NEXT_UID));
        _assertProtected(accepted);
    }

    function test_CreateMailbox_RevertsOnAPreclaimedSubnetCloneCandidate() public {
        address candidate = _cloneCandidate(UID);
        mock.setHotkeyOwner(_toSubstrate(candidate), _toSubstrate(bob));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneContaminated.selector, candidate));
        vault.createMailbox(NETUID1, UID);
        assertEq(vault.totalSupply(TOKEN1), 0);
        (, address accepted) = _create(alice, NEXT_UID);
        assertEq(accepted, _cloneCandidate(NEXT_UID));
    }

    function test_CreateMailbox_RevertsOnASwappedCandidateWithoutCurrentLock() public {
        address candidate = _cloneCandidate(UID);
        mock.setColdkeyRoot(_toSubstrate(candidate), _toSubstrate(bob));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneContaminated.selector, candidate));
        vault.createMailbox(NETUID1, UID);
    }

    function test_CreateMailbox_RevertsOnACandidateOwningOtherHotkeys() public {
        address candidate = _cloneCandidate(UID);
        mock.setHotkeyOwner(hotkey5, _toSubstrate(candidate));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneContaminated.selector, candidate));
        vault.createMailbox(NETUID1, UID);
    }

    /// @dev Stake and conviction may use different hotkeys; neither may enter backing through a poisoned candidate.
    function test_LockOnDifferentHotkey_CannotBecomeTheSubnetClone() public {
        address candidate = _cloneCandidate(UID);
        bytes32 coldkey = _toSubstrate(candidate);
        mock.setStake(hotkey5, coldkey, NETUID1, 40 ether);
        mock.setLockedAlpha(coldkey, NETUID1, hotkey1, 40 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CloneContaminated.selector, candidate));
        vault.createMailbox(NETUID1, UID);
        _create(alice, NEXT_UID);
        _depositAndWrap(alice, NETUID1, 40 ether);
        _depositAndWrap(bob, NETUID1, 1 ether);
        assertEq(lens.totalStake(TOKEN1), 41 ether);
        assertGt(vault.balanceOf(alice, TOKEN1), vault.balanceOf(bob, TOKEN1));
        assertEq(mock.getStake(hotkey5, coldkey, NETUID1), 40 ether, "rejected gift never enters backing");
    }

    function test_PostDeployment_EmptyClonesRejectColdkeySwaps() public {
        (address mailbox, address clone) = _create(alice, UID);
        vm.expectRevert(bytes("MockStaking: NewColdKeyIsHotkey"));
        mock.simulateColdkeySwap(_toSubstrate(bob), _toSubstrate(mailbox), NETUID1, _hotkeys(hotkey1));
        vm.expectRevert(bytes("MockStaking: NewColdKeyIsHotkey"));
        mock.simulateColdkeySwap(_toSubstrate(bob), _toSubstrate(clone), NETUID1, _hotkeys(hotkey1));
    }

    function test_PostDeployment_TaoOnlyAndFullyExitedCloneStaysProtected() public {
        (, address clone) = _create(alice, UID);
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
        (address mailbox, address clone) = _create(alice, UID);
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
        factory.deployMailbox(alice, uint16(NETUID1), UID);
    }
}
