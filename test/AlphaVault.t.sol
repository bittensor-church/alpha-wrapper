// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import {
    ChosenHotkeyNotInSet,
    ClaimBelowNativePrecision,
    DepositTooSmall,
    InsufficientShares,
    NetuidOutOfRange,
    NoSharesOutstanding,
    NothingToUnwrap,
    NoValidatorFound,
    ParkingHotkeyUnavailable,
    SubnetDissolved,
    SlippageExceeded,
    SubnetInDissolutionBlackoutPeriod,
    SubnetNotRegistered,
    ValidatorSetMalformed,
    WithdrawTooSmall,
    ZeroAddress,
    ZeroAmount,
    ZeroColdkey,
    ZeroHotkey
} from "src/VaultErrors.sol";
import { CloneBase } from "src/CloneBase.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { CHAIN_MIN_STAKE, MockStaking } from "./mocks/MockStaking.sol";
import { MockValidatorRegistry } from "./mocks/MockValidatorRegistry.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultTest is AlphaVaultTestBase {
    event DissolvedSubnetUnwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 taoOut);
    event Unwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 alphaOut);

    function test_RevertWhen_ConstructorZeroMailboxLogic() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVault(VAULT_URI, address(0), address(subnetLogic), address(registry), RECOVERY_WINDOW, PARKING_HOTKEY);
    }

    function test_RevertWhen_ConstructorZeroSubnetLogic() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVault(VAULT_URI, address(mailboxLogic), address(0), address(registry), RECOVERY_WINDOW, PARKING_HOTKEY);
    }

    function test_RevertWhen_ConstructorZeroValidatorRegistry() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVault(
            VAULT_URI, address(mailboxLogic), address(subnetLogic), address(0), RECOVERY_WINDOW, PARKING_HOTKEY
        );
    }

    function test_RevertWhen_ConstructorZeroRecoveryWindow() public {
        vm.expectRevert(ZeroAmount.selector);
        new AlphaVault(VAULT_URI, address(mailboxLogic), address(subnetLogic), address(registry), 0, PARKING_HOTKEY);
    }

    function test_RevertWhen_ConstructorZeroParkingHotkey() public {
        vm.expectRevert(ZeroHotkey.selector);
        new AlphaVault(
            VAULT_URI, address(mailboxLogic), address(subnetLogic), address(registry), RECOVERY_WINDOW, bytes32(0)
        );
    }

    function test_RevertWhen_ConstructorParkingHotkeyIsOwnedByAnotherColdkey() public {
        bytes32 taken = keccak256("taken-parking-hotkey");
        _simulateSquatter(taken);

        vm.expectRevert(ParkingHotkeyUnavailable.selector);
        new AlphaVault(
            VAULT_URI, address(mailboxLogic), address(subnetLogic), address(registry), RECOVERY_WINDOW, taken
        );
    }

    function test_Constructor_ClaimsTheParkingHotkeyForTheVault() public view {
        (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(vault.parkingHotkey());
        assertTrue(exists, "the parking hotkey has an owner record");
        assertEq(owner, _toSubstrate(address(vault)), "held by the vault's own coldkey");
    }

    function test_Uri_ReturnsConstructorValue() public view {
        assertEq(vault.uri(TOKEN1), VAULT_URI);
    }

    function test_GetCurrentValidatorsReturnsThree() public view {
        bytes32[] memory hotkeys = lens.getCurrentValidators(NETUID1);
        assertEq(hotkeys[0], hotkey1);
        assertEq(hotkeys[1], hotkey2);
        assertEq(hotkeys[2], hotkey3);
    }

    function test_SingleValidatorNoSplit() public {
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrap(alice, 99);

        assertEq(_getVaultStake(hotkey4, 99), 10 ether);
    }

    function test_GetDepositAddress() public view {
        address a1 = vault.getDepositAddress(alice, NETUID1);
        address a2 = vault.getDepositAddress(alice, NETUID2);
        address b1 = vault.getDepositAddress(bob, NETUID1);

        assertTrue(a1 != a2);
        assertTrue(a1 != b1);
    }

    function test_Wrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        assertTrue(vault.balanceOf(alice, TOKEN1) > 0);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
        uint256 total = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertEq(total, 10 ether);
    }

    function test_WrapMultipleSubnets() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _wrap(alice, NETUID2);

        assertTrue(vault.balanceOf(alice, TOKEN1) > 0);
        assertTrue(vault.balanceOf(alice, TOKEN2) > 0);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
        assertEq(lens.totalStake(TOKEN2), 5 ether);
    }

    function test_WrapTwice() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _wrap(alice, NETUID1);
        uint256 after1 = vault.balanceOf(alice, TOKEN1);

        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _wrap(alice, NETUID1);
        uint256 after2 = vault.balanceOf(alice, TOKEN1);

        assertTrue(after2 > after1);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
    }

    function test_RevertWhen_WrapZero() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_SharePriceGrowsWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 priceBefore = lens.sharePrice(TOKEN1);
        _simulateEmissions(NETUID1, 5 ether);
        uint256 priceAfter = lens.sharePrice(TOKEN1);

        assertTrue(priceAfter > priceBefore);
    }

    function test_EarlyWrapperCapturesEmissionsOverLateWrapper() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 10 ether);

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        assertLt(bobShares, aliceShares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        uint256 aliceReceived = _userStakeAcrossHotkeys(alice, NETUID1);

        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        uint256 bobReceived = _userStakeAcrossHotkeys(bob, NETUID1);

        assertApproxEqAbs(aliceReceived, 20 ether, 1e12);
        assertApproxEqAbs(bobReceived, 10 ether, 1e12);
        assertGt(aliceReceived, bobReceived);
    }

    function test_Unwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, quotedAlpha);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        uint256 totalReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(totalReceived, 10 ether, 1e9);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_RevertWhen_GatherDeliversLessThanMinAlphaOut() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 backing = lens.totalStake(TOKEN1);
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        bytes32 aliceSub = _toSubstrate(alice);

        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, quotedAlpha - 2));
        vault.unwrap(TOKEN1, shares, aliceSub, quotedAlpha - 1);

        assertEq(vault.balanceOf(alice, TOKEN1), shares, "slippage burned shares");
        assertEq(lens.totalStake(TOKEN1), backing, "slippage moved backing");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 0, "slippage delivered alpha");
    }

    function test_RevertWhen_RecipientCreditIsBelowMinAlphaOut() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 backing = lens.totalStake(TOKEN1);
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        bytes32 aliceSub = _toSubstrate(alice);

        MockStaking(STAKING_PRECOMPILE).setTransferStakeRoundingLoss(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, quotedAlpha - 1));
        vault.unwrap(TOKEN1, shares, aliceSub, quotedAlpha);

        assertEq(vault.balanceOf(alice, TOKEN1), shares, "slippage burned shares");
        assertEq(lens.totalStake(TOKEN1), backing, "slippage moved backing");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 0, "slippage credited alpha");
    }

    function test_UnwrapReportsActualRecipientCredit() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        bytes32 aliceSub = _toSubstrate(alice);
        uint256 creditedAlpha = quotedAlpha - 1;

        MockStaking(STAKING_PRECOMPILE).setTransferStakeRoundingLoss(1);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, shares, creditedAlpha);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, creditedAlpha);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), creditedAlpha);
    }

    function test_WrapSyncsStakeBeforeMintingShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 100 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        uint256 currentStake = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, currentStake + 100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        assertApproxEqAbs(bobShares, aliceShares / 2, 1e9, "bob shares should reflect synced pool value");
        assertLt(bobShares, aliceShares, "bob got too many shares - stale totalStake on deposit");
    }

    function test_FirstWrapDoesNotUnderflowWhenRebalanceRounds() public {
        // Real stake moves can round down; deposited alpha may exceed the final in-set total by a RAO.
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        assertGt(vault.balanceOf(alice, TOKEN1), 0);

        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(0);
    }

    function test_UnwrapWithRewards() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 5 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 totalReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertTrue(totalReceived > 10 ether, "Should receive deposit + rewards");
    }

    function test_RevertWhen_UnwrapOnZero() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrap(TOKEN1, 0, aliceSub, 0);
    }

    function test_RevertWhen_LiveUnwrapToZeroColdkey() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 backing = lens.totalStake(TOKEN1);

        vm.prank(alice);
        vm.expectRevert(ZeroColdkey.selector);
        vault.unwrap(TOKEN1, shares, bytes32(0), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), shares, "zero destination burned shares");
        assertEq(lens.totalStake(TOKEN1), backing, "zero destination moved backing");
    }

    function test_OnlyVaultCanFlush() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 ether);
        _wrap(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(payable(clone)).flush(bytes32(0), hotkey1, NETUID1, 1 ether);
    }

    function test_MailboxCannotReinitialize() public {
        _simulateAlphaDeposit(alice, NETUID1, 1 ether);
        _wrap(alice, NETUID1);

        address clone = vault.getDepositAddress(alice, NETUID1);
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        CloneBase(payable(clone)).initialize(address(0xdead));
    }

    function test_RevertWhen_MailboxInitializeForeignWrapper() public {
        address clone = Clones.clone(address(mailboxLogic));
        vm.expectRevert(CloneBase.UnauthorizedInitializer.selector);
        CloneBase(payable(clone)).initialize(address(0xbeef));
    }

    function testFuzz_PreviewWrapScalesLinearlyOnEmptyVault(uint256 assets) public view {
        assets = bound(assets, 0, type(uint64).max);
        assertEq(lens.previewWrap(TOKEN1, assets), assets * 1e9);
    }

    function test_PreviewUnwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 10 ether);
        assertEq(tao, 0);
    }

    function test_UnwrapPartialShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, aliceSub, 0);

        assertApproxEqAbs(vault.balanceOf(alice, TOKEN1), shares / 2, 1);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 5 ether, 0.01 ether);
    }

    function test_InterleavedWrapsUnwraps() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _simulateAlphaDeposit(bob, NETUID1, 20 ether);
        _wrap(bob, NETUID1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, aliceSub, 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);

        assertEq(vault.balanceOf(bob, TOKEN1), bobShares);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 20 ether, 0.01 ether);

        bytes32 bobSub = _toSubstrate(bob);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobSub, 0);
        assertEq(vault.balanceOf(bob, TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_SubnetIsolation() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 ether);
        _wrap(alice, NETUID2);

        _simulateEmissions(NETUID1, 10 ether);

        uint256 price1 = lens.sharePrice(TOKEN1);
        uint256 price2 = lens.sharePrice(TOKEN2);
        assertGt(price1, price2, "NETUID1 should have higher share price after rewards");

        uint256 shares2 = vault.balanceOf(alice, TOKEN2);
        (uint256 preview2,) = lens.previewUnwrap(TOKEN2, shares2);
        assertApproxEqAbs(preview2, 5 ether, 0.01 ether);
    }

    function test_FirstWrapperInflationAttack() public {
        // Smallest deposit whose 3333-BPS slice clears the 2e6 move floor.
        _simulateAlphaDeposit(alice, NETUID1, 6_001_802);
        _wrap(alice, NETUID1);

        _simulateEmissions(NETUID1, 100 ether);

        _simulateAlphaDeposit(bob, NETUID1, 10 ether);
        _wrap(bob, NETUID1);

        uint256 bobShares = vault.balanceOf(bob, TOKEN1);
        assertGt(bobShares, 0, "Bob should get shares despite inflation attempt");

        (uint256 bobValue,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertGt(bobValue, 9 ether, "Bob should not lose significant value to inflation attack");
    }

    function test_RevertWhen_SharePriceForUnregisteredSubnet() public {
        uint256 tokenId = uint256(uint16(42)) | (uint256(100) << 16);
        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(tokenId);
    }

    function test_RevertWhen_SharePriceWhenSupplyIsZero() public {
        vault.createSubnetProxy(NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.totalSupply(tokenId), 0);
        vm.expectRevert(NoSharesOutstanding.selector);
        lens.sharePrice(tokenId);
    }

    function test_RebalanceWithRegistryWeights() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(6000, 4000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 100 ether, 0, 0);

        vault.rebalance(NETUID1);

        assertApproxEqAbs(_getVaultStake(hotkey1, NETUID1), 60 ether, 1);
        assertApproxEqAbs(_getVaultStake(hotkey2, NETUID1), 40 ether, 1);
    }

    function test_RebalanceThreeValidators() public {
        uint16 bpsHk1 = 5000;
        uint16 bpsHk2 = 3000;
        uint16 bpsHk3 = 2000;
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(bpsHk1, bpsHk2, bpsHk3));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 100 ether, 0, 0);

        vault.rebalance(NETUID1);

        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 100 ether, "Total stake preserved");
        assertEq(_getVaultStake(hotkey1, NETUID1), _weighted(100 ether, bpsHk1));
        assertEq(_getVaultStake(hotkey2, NETUID1), _weighted(100 ether, bpsHk2));
        assertEq(_getVaultStake(hotkey3, NETUID1), _weighted(100 ether, bpsHk3));
    }

    function test_RebalanceNoOpWhenAlreadyBalanced() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 50 ether, hotkey1);
        _wrap(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 50 ether);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 50 ether);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 50 ether);
        assertEq(_getVaultStake(hotkey2, NETUID1), 50 ether);
    }

    function test_RebalanceNoOpWhenCloneNotDeployed() public {
        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
        assertEq(vault.subnetClone(TOKEN1), address(0));
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(_lastSeen(TOKEN1).length, 0);
    }

    function test_RebalanceEmitsEvent() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(8000, 2000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 ether, hotkey1);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 100 ether, 0, 0);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, true, true, true);
        emit Rebalanced(tokenId, hotkey1, hotkey2, 20 ether);
        vault.rebalance(NETUID1);
    }

    function test_RebalanceSkipsMoveBelowMinStake() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 4e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        _plantVaultStakes(NETUID1, 500_001, 500_000, 0);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);

        assertEq(_getVaultStake(hotkey1, NETUID1), 500_001);
        assertEq(_getVaultStake(hotkey2, NETUID1), 500_000);
    }

    function test_RebalanceMovesAtOrAboveMinStake() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 4e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        _plantVaultStakes(NETUID1, 8e6, 0, 0);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        vm.expectEmit(true, true, true, true);
        emit Rebalanced(tokenId, hotkey1, hotkey2, 4e6);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 4e6);
        assertEq(_getVaultStake(hotkey2, NETUID1), 4e6);
    }

    function test_UnwrapEmitsRebalanced() public {
        uint256 deposit = 10 ether;
        _simulateAlphaDepositHotkey(alice, NETUID2, deposit, hotkey2);
        _wrapHotkey(alice, NETUID2, hotkey2);

        uint256 shares = vault.balanceOf(alice, TOKEN2);
        uint256 burned = deposit / 2;
        uint256 expectedMove = _weighted(burned, NETUID2_BPS_HK1);

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(TOKEN2, hotkey1, hotkey2, expectedMove);

        vm.prank(alice);
        vault.unwrap(TOKEN2, shares / 2, _toSubstrate(alice), 0);
    }

    function test_UnwrapEmitsNoRebalancedWhenFullyDrained() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        uint256 tokenId = vault.currentTokenId(99);

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.recordLogs();
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
    }

    function test_ValidatorRegistry_SetAtConstruction() public view {
        assertEq(address(vault.validatorRegistry()), address(registry));
    }

    function test_RevertWhen_RegistryWhenNoValidatorsSet() public {
        address[] memory s = new address[](2);
        s[0] = vm.addr(SIGNER_PK_1);
        s[1] = vm.addr(SIGNER_PK_2);
        (, AlphaVaultLens freshLens) = _deployVaultAndLens(address(new ValidatorRegistry(address(this), s, 2)));

        vm.expectRevert(NoValidatorFound.selector);
        freshLens.getCurrentValidators(NETUID1);
    }

    function test_TotalStakeMatchesDepositAcrossValidatorSetSizes() public {
        _setValidators(91, _hotkeys(hotkey4), _weights(10_000));
        _setRegBlock(91, 91);
        _simulateAlphaDepositHotkey(alice, 91, 30 ether, hotkey4);
        _wrap(alice, 91);
        assertEq(lens.totalStake(vault.currentTokenId(91)), 30 ether);
        assertEq(_getVaultStake(hotkey4, 91), 30 ether);

        _simulateAlphaDeposit(alice, NETUID2, 100 ether);
        _wrap(alice, NETUID2);
        assertEq(lens.totalStake(vault.currentTokenId(NETUID2)), 100 ether);

        _simulateAlphaDeposit(alice, NETUID1, 90 ether);
        _wrap(alice, NETUID1);
        assertEq(lens.totalStake(vault.currentTokenId(NETUID1)), 90 ether);
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 90 ether);
    }

    /// @dev Synthetic malformed sets: only empty arrays mean unconfigured; nonempty zero entries are surfaced.
    function test_RevertWhen_ResolveValidatorsWhenWeightZero() public {
        MockValidatorRegistry mock = new MockValidatorRegistry();
        (, AlphaVaultLens mockLens) = _deployVaultAndLens(address(mock));

        _setRegBlock(91, 91);
        vm.expectRevert(NoValidatorFound.selector);
        mockLens.getCurrentValidators(91);

        bytes32[] memory corruptHks = new bytes32[](3);
        uint16[] memory corruptWts = new uint16[](3);
        corruptHks[1] = hotkey1;
        corruptHks[2] = hotkey2;
        corruptWts[1] = 5_000;
        corruptWts[2] = 5_000;
        mock.setRaw(92, corruptHks, corruptWts);
        _setRegBlock(92, 92);
        bytes32[] memory surfaced = mockLens.getCurrentValidators(92);
        assertEq(surfaced.length, 3);
        assertEq(surfaced[0], bytes32(0));
    }

    function test_RevertWhen_RegistryReturnsMismatchedLengths() public {
        MockValidatorRegistry mock = new MockValidatorRegistry();
        (, AlphaVaultLens mockLens) = _deployVaultAndLens(address(mock));

        bytes32[] memory hotkeys = new bytes32[](1);
        uint16[] memory weights = new uint16[](2);
        hotkeys[0] = hotkey4;
        weights[0] = 5_000;
        weights[1] = 5_000;
        mock.setRaw(91, hotkeys, weights);
        _setRegBlock(91, 91);

        vm.expectRevert(ValidatorSetMalformed.selector);
        mockLens.getCurrentValidators(91);
    }

    function test_UnwrapDecreasesTotalStake() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_SubnetCloneCanMoveStake() public {
        vault.createSubnetProxy(NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);
        _plantVaultStake(hotkey1, NETUID1, 100 ether);

        vm.prank(address(vault));
        SubnetClone(payable(clone)).moveStake(hotkey1, hotkey2, NETUID1, 100 ether);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey2, NETUID1), 100 ether);
    }

    function test_SubnetCloneCanUnwrapTao() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.deal(clone, 50 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(address(vault));
        SubnetClone(payable(clone)).unwrapTao(payable(alice), 50 ether);

        assertEq(address(clone).balance, 0);
        assertEq(alice.balance, aliceBefore + 50 ether);
    }

    function test_OnlyWrapperCanCallMoveStake() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.prank(alice);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(clone)).moveStake(hotkey1, hotkey2, NETUID1, 100 ether);
    }

    function test_OnlyWrapperCanCallUnwrapTao() public {
        vault.createSubnetProxy(NETUID1);
        address clone = vault.subnetClone(vault.currentTokenId(NETUID1));
        vm.deal(clone, 50 ether);
        vm.prank(alice);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(clone)).unwrapTao(payable(alice), 50 ether);
    }

    function test_ReclaimTaoFromMailboxSkipsDeployForNonExistentMailbox() public {
        address predicted = vault.getDepositAddress(alice, NETUID1);
        assertEq(predicted.code.length, 0);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
        uint256 gasUsed = gasBefore - gasleft();

        // The gas bound distinguishes early rejection from deploying and then reverting a mailbox.
        assertLt(gasUsed, 50_000, "too much gas - mailbox clone deployed unnecessarily before revert");
    }

    function test_ImplementationMailboxRejectsInitialize() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        mailboxLogic.initialize(address(this));
    }

    function test_ImplementationSubnetCloneRejectsInitialize() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        subnetLogic.initialize(address(this));
    }

    function test_UserCanRetrieveTaoFromMailboxAfterDeregistration() public {
        address userClone = vault.getDepositAddress(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(userClone), NETUID1, 10 ether);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _toSubstrate(userClone), NETUID1, 0);
        vm.deal(userClone, 10 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.reclaimTaoFromMailbox(NETUID1);

        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(userClone.balance, 0);
    }

    function test_ReclaimAlphaFromMailbox() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey4);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 10 ether);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxZeroHotkey() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(ZeroHotkey.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, bytes32(0), aliceSub);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxNoStake() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxZeroColdkey() public {
        vm.prank(alice);
        vm.expectRevert(ZeroColdkey.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, bytes32(0));
    }

    function test_ReclaimAlphaFromMailboxAcceptsInSetHotkey() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, aliceSub, NETUID1), 10 ether);
    }

    function test_ReclaimAlphaCleansStrandedHotkeyAlongsideValidDeposit() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        _simulateAlphaDepositHotkey(alice, NETUID1, 5 ether, hotkey4);

        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(lens.totalStake(TOKEN1), 10 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 5 ether);
    }

    function test_ReclaimAlphaFromMailboxRecoversAfterSetRotation() public {
        _setNetuid1Set(hotkey1, hotkey2, hotkey4);
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey4);

        _setNetuid1Set(hotkey1, hotkey2, hotkey3);

        vm.prank(alice);
        vm.expectRevert(ChosenHotkeyNotInSet.selector);
        vault.wrap(NETUID1, hotkey4, 0);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 10 ether);

        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
    }

    function test_CurrentTokenIdReflectsRegBlock() public view {
        uint256 expected1 = uint256(uint16(NETUID1)) | (uint256(100) << 16);
        uint256 expected2 = uint256(uint16(NETUID2)) | (uint256(200) << 16);
        assertEq(vault.currentTokenId(NETUID1), expected1);
        assertEq(vault.currentTokenId(NETUID2), expected2);
    }

    function test_RevertWhen_CurrentTokenIdForUnregisteredNetuid() public {
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.currentTokenId(42);
    }

    function testFuzz_CurrentTokenId_RoundTripsAndRejectsAChangedRegistration(uint16 netuid, uint64 regBlock) public {
        netuid = uint16(bound(netuid, 1, type(uint16).max));
        regBlock = uint64(bound(regBlock, 1, type(uint64).max));
        _setRegBlock(netuid, regBlock);

        uint256 tokenId = vault.currentTokenId(netuid);
        assertEq(tokenId, uint256(netuid) | (uint256(regBlock) << 16));
        assertEq(lens.previewWrap(tokenId, 1e9), 1e18);

        _setRegBlock(netuid, regBlock == type(uint64).max ? 1 : type(uint64).max);
        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(tokenId, 1e9);
    }

    function testFuzz_RevertWhen_CurrentTokenIdNetuidOutOfRange(uint256 netuid) public {
        netuid = bound(netuid, uint256(type(uint16).max) + 1, type(uint256).max);

        vm.expectRevert(NetuidOutOfRange.selector);
        vault.currentTokenId(netuid);
    }

    function test_RevertWhen_NetuidOutOfRangeAllEntrypoints() public {
        uint256 oob = uint256(type(uint16).max) + 1;

        vm.expectRevert(NetuidOutOfRange.selector);
        vault.currentTokenId(oob);

        vm.expectRevert(NetuidOutOfRange.selector);
        vault.getDepositAddress(alice, oob);

        vm.expectRevert(NetuidOutOfRange.selector);
        lens.getCurrentValidators(oob);
    }

    function test_CurrentTokenIdChangesAfterRecycle() public {
        uint256 before = vault.currentTokenId(NETUID1);
        _setRegBlock(NETUID1, 500);
        uint256 afterRecycle = vault.currentTokenId(NETUID1);
        assertTrue(before != afterRecycle);
        assertEq(afterRecycle, uint256(uint16(NETUID1)) | (uint256(500) << 16));
    }

    function test_RevertWhen_CreateSubnetProxySubnetNotRegistered() public {
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.createSubnetProxy(42);
    }

    function test_CreateSubnetProxyDeploysClone() public {
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.subnetClone(tokenId), address(0));

        vm.expectEmit(true, false, false, false);
        emit SubnetProxyCreated(tokenId, address(0));
        vault.createSubnetProxy(NETUID1);

        assertTrue(vault.subnetClone(tokenId) != address(0));
    }

    function test_CreateSubnetProxyNoopForExistingClone() public {
        vault.createSubnetProxy(NETUID1);
        address first = vault.subnetClone(vault.currentTokenId(NETUID1));
        vault.createSubnetProxy(NETUID1);
        assertEq(vault.subnetClone(vault.currentTokenId(NETUID1)), first);
    }

    function test_CreateSubnetProxyDeploysNewCloneAfterRecycle() public {
        vault.createSubnetProxy(NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _setRegBlock(NETUID1, 500);
        uint256 newTokenId = vault.currentTokenId(NETUID1);
        vault.createSubnetProxy(NETUID1);

        address oldClone = vault.subnetClone(oldTokenId);
        address newClone = vault.subnetClone(newTokenId);
        assertTrue(oldClone != address(0));
        assertTrue(newClone != address(0));
        assertTrue(oldClone != newClone);
    }

    function test_WrapAutoDeploysClone() public {
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.subnetClone(tokenId), address(0));

        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        assertTrue(vault.subnetClone(tokenId) != address(0));
        assertTrue(vault.balanceOf(alice, tokenId) > 0);
        assertEq(lens.totalStake(tokenId), 10 ether);
    }

    function test_WrapTwoUsersProportionalShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        assertApproxEqRel(bobShares, aliceShares * 3, 0.01e18);
    }

    function test_RevertWhen_WrapSubnetNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.wrap(42, hotkey1, 0);
    }

    function test_WrapAfterRecycleDeploysNewCloneAndIsolatesOldShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _setRegBlock(NETUID1, 500);

        _simulateAlphaDeposit(bob, NETUID1, 5 ether);
        _wrap(bob, NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertTrue(vault.balanceOf(alice, oldTokenId) > 0);
        assertEq(vault.balanceOf(alice, newTokenId), 0);
        assertTrue(vault.balanceOf(bob, newTokenId) > 0);
        assertEq(vault.balanceOf(bob, oldTokenId), 0);
        assertTrue(vault.subnetClone(oldTokenId) != vault.subnetClone(newTokenId));
    }

    function test_RevertWhen_UnwrapInsufficientShares() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        vm.prank(alice);
        vm.expectRevert(InsufficientShares.selector);
        vault.unwrap(tokenId, shares + 1, _toSubstrate(alice), 0);
    }

    function test_UnwrapFromDissolvedSingleHolderDrainsFullPot() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 50 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit DissolvedSubnetUnwrapped(alice, tokenId, shares, 50 ether);

        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 50 ether);
        assertEq(vault.totalSupply(tokenId), 0);
    }

    function test_RevertWhen_DissolvedUnwrapHasPositiveMinAlphaOut() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 50 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 0));
        vault.unwrap(tokenId, shares, bytes32(0), 1);

        assertEq(vault.balanceOf(alice, tokenId), shares, "alpha floor burned dissolved shares");
        assertEq(alice.balance, 0, "alpha floor paid TAO instead");
    }

    function test_UnwrapFromDissolvedSubnetTwoHoldersProRata() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supply = aliceShares + bobShares;

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 80 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceExpected = _wholeRao((80 ether * aliceShares) / supply);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob), 0);
        assertEq(bob.balance - bobBefore, _wholeRao(80 ether - aliceExpected));
    }

    function test_DissolvedUnwrap_PaysWholeRaoAndKeepsTheTail() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 50 ether + 5e8);
        _simulateDissolutionCompleted(NETUID1);

        (, uint256 quoted) = lens.previewUnwrap(tokenId, shares);
        assertEq(quoted, 50 ether, "the quote is what the transfer delivers");

        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit DissolvedSubnetUnwrapped(alice, tokenId, shares, 50 ether);
        vm.prank(alice);
        vault.unwrap(tokenId, shares, bytes32(0), 0);

        assertEq(alice.balance - aliceBefore, 50 ether, "paid in whole RAO");
        assertEq(clone.balance, 5e8, "the sub-RAO tail stays behind");
    }

    function test_RevertWhen_DissolvedSliceIsBelowOneRao() public {
        _simulateAlphaDeposit(alice, NETUID1, 1e7);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 100 ether);
        _wrap(bob, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 1 ether);
        _simulateDissolutionCompleted(NETUID1);

        (, uint256 quoted) = lens.previewUnwrap(tokenId, aliceShares);
        assertEq(quoted, 0, "a slice below one RAO quotes nothing");

        vm.prank(alice);
        vm.expectRevert(ClaimBelowNativePrecision.selector);
        vault.unwrap(tokenId, aliceShares, bytes32(0), 0);
        assertEq(vault.balanceOf(alice, tokenId), aliceShares, "the refusal keeps the shares");
    }

    function test_UnwrapFromDissolvedSubnetAfterNewSubnetRegistered() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateNewNetworkRegistered(tokenId, 500, 5 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 5 ether);
    }

    function test_TwoDissolvedGenerationsPayFromTheirOwnClones() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 gen1 = vault.currentTokenId(NETUID1);
        uint256 gen1Shares = vault.balanceOf(alice, gen1);
        address clone1 = vault.subnetClone(gen1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(gen1, 50 ether);
        _simulateDissolutionCompleted(NETUID1);

        _setRegBlock(NETUID1, 500);
        _simulateAlphaDeposit(alice, NETUID1, 4 ether);
        _wrap(alice, NETUID1);
        uint256 gen2 = vault.currentTokenId(NETUID1);
        uint256 gen2Shares = vault.balanceOf(alice, gen2);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(gen2, 20 ether);
        _simulateDissolutionCompleted(NETUID1);

        assertEq(clone1.balance, 50 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(gen2, gen2Shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - before, 20 ether);

        before = alice.balance;
        vm.prank(alice);
        vault.unwrap(gen1, gen1Shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - before, 50 ether);
    }

    function test_Unwrap_ReplacedGenerationPaysDuringSuccessorBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);
        _simulateNewNetworkRegistered(TOKEN1, 500, 5 ether);
        _simulateDissolutionStarted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 5 ether);
    }

    /// @dev A cleared registration block makes successor cleanup indistinguishable from this token's own.
    function test_RevertWhen_UnwrapDuringSuccessorLateBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);
        _simulateNewNetworkRegistered(TOKEN1, 500, 5 ether);
        _simulateDissolutionStarted(NETUID1);
        _setRegBlock(NETUID1, 0);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapForTaoOnReplacedGenerationDuringSuccessorBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);
        _simulateNewNetworkRegistered(TOKEN1, 500, 5 ether);
        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_RevertWhen_SharePriceOnReplacedGenerationDuringSuccessorBlackout() public {
        _depositAndWrap(alice, NETUID1, 10 ether);
        _simulateNewNetworkRegistered(TOKEN1, 500, 5 ether);
        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_UnwrapSucceedsAfterCleanupCompletesAfterForceSend() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _setRegBlock(NETUID1, 500);
        _simulateDissolutionStarted(NETUID1);
        vm.deal(vault.subnetClone(tokenId), 1);

        _simulateTaoAwardedOnDissolution(tokenId, 5 ether);

        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);

        assertEq(alice.balance - aliceBefore, 5 ether, "the force-sent wei is below one RAO and stays behind");
    }

    function test_RevertWhen_WrapDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_RevertWhen_UnwrapDuringEarlyBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 5 ether);
        _setRegBlock(NETUID1, 0);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapForTaoDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrapForTao(tokenId, shares, 0);
    }

    function test_RevertWhen_UnwrapForTaoDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 5 ether);
        _setRegBlock(NETUID1, 0);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrapForTao(tokenId, shares, 0);
    }

    function test_RevertWhen_RebalanceDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_WrapDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);

        _simulateDissolutionStarted(NETUID1);
        _setRegBlock(NETUID1, 0);

        vm.prank(alice);
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_RevertWhen_RebalanceDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        _simulateDissolutionStarted(NETUID1);
        _setRegBlock(NETUID1, 0);

        vm.expectRevert(SubnetNotRegistered.selector);
        vault.rebalance(NETUID1);
    }

    function test_PreviewUnwrapDead() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(tokenId, shares);
        assertEq(alpha, 0);
        assertEq(tao, 40 ether);
    }

    function test_PreviewUnwrap_QuotesReplacedGenerationDuringSuccessorBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 ether);
        _simulateNewNetworkRegistered(TOKEN1, 500, 40 ether);
        _simulateDissolutionStarted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0);
        assertEq(tao, 40 ether);
    }

    function test_PreviewUnwrapUnknownTokenId() public view {
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(0xDEADBEEF, 1000);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrapZeroShares() public view {
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(1, 0);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrap_AccountsForRotatedOutStake() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 0, 0, 30 ether);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(actualAlpha, 30 ether, "unwrap reclaims rotated-out stake and pays the full deposit");
        assertEq(previewAlpha, actualAlpha, "preview must match what unwrap actually pays");
    }

    function test_PreviewUnwrap_MatchesDeliveryWithSubFloorRotatedOutStake() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _plantVaultStake(hotkey3, NETUID1, CHAIN_MIN_STAKE - 1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(actualAlpha, previewAlpha, "preview must match delivery when only sub-floor rotated-out stake differs");
    }

    function test_PreviewUnwrapSurvivesFullRegistryRotationWithoutRebalance() public {
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(10_000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey4);
        _wrapHotkey(alice, NETUID1, hotkey4);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(3334, 3333, 3333));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(actualAlpha, 30 ether, "unwrap reclaims stake from the rotated-out validator");
        assertEq(previewAlpha, actualAlpha, "preview matches what unwrap pays after registry rotation");
    }

    function test_PreviewUnwrapReflectsFreshEmissions() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        uint256 hk1Before = _getVaultStake(hotkey1, NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, cloneColdkey, NETUID1, hk1Before + 6 ether);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);

        assertApproxEqAbs(actualAlpha, 36 ether, 1, "unwrap pays deposit + accrued emissions");
        assertEq(previewAlpha, actualAlpha, "preview reflects fresh on-chain balances incl. emissions");
    }

    function test_PreviewUnwrapReturnsZeroWhenVaultDrained() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 0, 0, 0);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);

        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_RevertWhen_SharePriceForFullyDissolvedTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(tokenId);
    }

    function test_RevertWhen_SharePriceForReRegisteredSubnetOldTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 40 ether);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(oldTokenId);
    }

    function test_RevertWhen_SharePriceAndIsNotManipulableByForceSend() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(tokenId);

        vm.deal(clone, clone.balance + 1_000_000 ether);
        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(tokenId);
    }

    function test_RevertWhen_PreviewWrapForDissolvedTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 40 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(tokenId, 10 ether);
    }

    function test_RevertWhen_PreviewWrapForReRegisteredSubnetOldTokenId() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 40 ether);

        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(oldTokenId, 10 ether);
        assertGt(lens.previewWrap(vault.currentTokenId(NETUID1), 10 ether), 0);
    }

    function test_ForceSendBeforeDissolvedUnwrapIsDonationToHolders() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 10 ether);
        _simulateDissolutionCompleted(NETUID1);

        vm.deal(clone, clone.balance + 5 ether);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);

        assertEq(alice.balance - aliceBalBefore, 15 ether, "sole holder captures legit refund + attacker's donation");
    }

    function test_ForceSendBetweenPartialDissolvedUnwraps_BenefitsLaterUnwraps() public {
        _simulateAlphaDeposit(alice, NETUID1, 6 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 4 ether);
        _wrap(bob, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        address clone = vault.subnetClone(tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 10 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supplyBefore = aliceShares + bobShares;

        uint256 aliceExpected = (10 ether * aliceShares) / supplyBefore;

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBalBefore, aliceExpected, "alice gets pro-rata of legit pot");

        vm.deal(clone, clone.balance + 3 ether);

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob), 0);
        uint256 bobGain = bob.balance - bobBalBefore;

        assertEq(bobGain, (10 ether - aliceExpected) + 3 ether);
    }

    function test_RevertWhen_PreviewUnwrapBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.previewUnwrap(tokenId, shares);
    }

    function test_RevertWhen_SharePriceBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.sharePrice(tokenId);
    }

    function test_RevertWhen_PreviewWrapBlackoutOfCurrentRegistration() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.previewWrap(tokenId, 10 ether);
    }

    function test_RevertWhen_PreviewUnwrapDissolvedZeroBalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, 0);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.previewUnwrap(tokenId, shares);
    }

    function test_ForceSendDoesNotAffectAlphaPayout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);
        address clone = vault.subnetClone(tokenId);

        vm.deal(clone, clone.balance + 100 ether);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(tokenId, shares);
        assertEq(tao, 0);
        assertApproxEqAbs(alpha, 10 ether, 1);
    }

    function test_RebalanceRecycledSubnetSilentNoop() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);

        uint256 oldTokenId = vault.currentTokenId(NETUID1);
        address oldClone = vault.subnetClone(oldTokenId);
        uint256 oldStakeBefore = _userStakeAcrossHotkeys(oldClone, NETUID1);

        _setRegBlock(NETUID1, 500);
        uint256 newTokenId = vault.currentTokenId(NETUID1);
        assertTrue(newTokenId != oldTokenId);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
        assertEq(vault.subnetClone(newTokenId), address(0));
        assertEq(lens.totalStake(newTokenId), 0);
        assertEq(_lastSeen(newTokenId).length, 0);

        uint256 oldStakeAfter = _userStakeAcrossHotkeys(oldClone, NETUID1);
        assertEq(oldStakeAfter, oldStakeBefore);
    }

    function test_LifecycleCaseAGovernanceDissolve() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, tokenId);
        uint256 bobShares = vault.balanceOf(bob, tokenId);
        uint256 supply = aliceShares + bobShares;

        _simulateTaoAwardedOnDissolution(tokenId, 80 ether);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceExpected = (80 ether * aliceShares) / supply;

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(tokenId, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, aliceExpected);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(tokenId, bobShares, _toSubstrate(bob), 0);
        assertEq(bob.balance - bobBefore, 80 ether - aliceExpected);

        assertEq(vault.subnetClone(tokenId).balance, 0);
        assertEq(vault.totalSupply(tokenId), 0);
    }

    function test_LifecycleCaseBPruneRecycleWithNewSubnet() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 ether);
        _wrap(alice, NETUID1);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _simulateNewNetworkRegistered(oldTokenId, 500, 3 ether);

        _simulateAlphaDeposit(bob, NETUID1, 20 ether);
        _wrap(bob, NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertTrue(oldTokenId != newTokenId);

        uint256 aliceShares = vault.balanceOf(alice, oldTokenId);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(oldTokenId, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 3 ether);

        uint256 bobShares = vault.balanceOf(bob, newTokenId);
        vm.prank(bob);
        vault.unwrap(newTokenId, bobShares, _toSubstrate(bob), 0);
        uint256 bobTotal = _userStakeAcrossHotkeys(bob, NETUID1);
        assertEq(bobTotal, 20 ether);
    }

    function test_WrapChosenInSetDistributesProportionally() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), _weighted(30 ether, NETUID1_BPS_HK1));
        assertEq(_getVaultStake(hotkey2, NETUID1), _weighted(30 ether, NETUID1_BPS_HK2));
        assertEq(_getVaultStake(hotkey3, NETUID1), _weighted(30 ether, NETUID1_BPS_HK3));
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 30 ether);
        assertEq(lens.totalStake(TOKEN1), 30 ether);
    }

    function test_RevertWhen_WrapChosenOutOfSet() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey4);
        vm.prank(alice);
        vm.expectRevert(ChosenHotkeyNotInSet.selector);
        vault.wrap(NETUID1, hotkey4, 0);
    }

    function test_WrapCount1ChosenIsValidatorNoMoves() public {
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 10 ether);
        assertEq(_getVaultStake(hotkey1, 99), 0);
        assertEq(_getVaultStake(hotkey2, 99), 0);
    }

    function test_RevertWhen_WrapZeroChosenHotkey() public {
        vm.prank(alice);
        vm.expectRevert(ZeroHotkey.selector);
        vault.wrap(NETUID1, bytes32(0), 0);
    }

    function test_RevertWhen_WrapWhenDepositBelowMinStake() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 1_999_999, hotkey1);
        vm.prank(alice);
        vm.expectRevert(DepositTooSmall.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_WrapAcceptsExactlyMinStakeCount1() public {
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 2e6, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 2e6);
    }

    function test_RevertWhen_WrapWhenChosenHasZeroStakeEvenIfOtherHotkeyFunded() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.wrap(NETUID1, hotkey2, 0);
    }

    function test_WrapMintsExactlyTheQuotedShares() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        uint256 quoted = lens.previewWrap(TOKEN1, 30 ether);

        vm.prank(alice);
        vault.wrap(NETUID1, hotkey1, quoted);

        assertEq(vault.balanceOf(alice, TOKEN1), quoted, "the quote is a bound the vault can be held to");
    }

    function test_RevertWhen_WrapMintsBelowMinSharesOut() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        uint256 quoted = lens.previewWrap(TOKEN1, 30 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, quoted));
        vault.wrap(NETUID1, hotkey1, quoted + 1);
    }

    function test_WrapRefusedOnSlippageLeavesTheDepositInTheMailbox() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        bytes32 mailboxColdkey = _toSubstrate(vault.getDepositAddress(alice, NETUID1));
        uint256 quoted = lens.previewWrap(TOKEN1, 30 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, quoted));
        vault.wrap(NETUID1, hotkey1, quoted + 1);

        assertEq(_getStakeForColdkey(hotkey1, mailboxColdkey, NETUID1), 30 ether, "deposit still the caller's");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 0, "no alpha landed in the position");

        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(vault.balanceOf(alice, TOKEN1), quoted, "the retry mints what the bound refused");
    }

    function test_RevertWhen_BackingGrowsBetweenQuoteAndWrap() public {
        _depositAndWrap(alice, NETUID1, 30 ether);
        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        uint256 quoted = lens.previewWrap(TOKEN1, 30 ether);

        _simulateEmissions(NETUID1, 30 ether);

        uint256 requoted = lens.previewWrap(TOKEN1, 30 ether);
        assertLt(requoted, quoted, "the appreciation moved the rate against the depositor");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, requoted));
        vault.wrap(NETUID1, hotkey1, quoted);
    }

    function testFuzz_WrapMintsAtLeastMinSharesOut(uint256 depositAlpha, uint256 boundBps) public {
        depositAlpha = bound(depositAlpha, CHAIN_MIN_STAKE, 1_000 ether);
        boundBps = bound(boundBps, 0, 10_000);
        _simulateAlphaDepositHotkey(alice, NETUID1, depositAlpha, hotkey1);
        uint256 quoted = lens.previewWrap(TOKEN1, depositAlpha);
        uint256 minSharesOut = (quoted * boundBps) / 10_000;

        vm.prank(alice);
        vault.wrap(NETUID1, hotkey1, minSharesOut);

        assertGe(vault.balanceOf(alice, TOKEN1), minSharesOut, "a bound at or below the quote is honored");
    }

    function testFuzz_RevertWhen_MinSharesOutExceedsTheQuote(uint256 depositAlpha, uint256 excess) public {
        depositAlpha = bound(depositAlpha, CHAIN_MIN_STAKE, 1_000 ether);
        _simulateAlphaDepositHotkey(alice, NETUID1, depositAlpha, hotkey1);
        uint256 quoted = lens.previewWrap(TOKEN1, depositAlpha);
        excess = bound(excess, 1, type(uint256).max - quoted);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, quoted));
        vault.wrap(NETUID1, hotkey1, quoted + excess);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "a refused wrap mints nothing");
    }

    function test_WrapDerivesMailboxColdkeyFromUserClone() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 ether, hotkey1);
        _simulateAlphaDepositHotkey(bob, NETUID1, 5 ether, hotkey1);

        address aliceClone = vault.getDepositAddress(alice, NETUID1);
        address bobClone = vault.getDepositAddress(bob, NETUID1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(aliceClone), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(bobClone), NETUID1), 5 ether);
        assertEq(lens.totalStake(TOKEN1), 10 ether);
    }

    function test_WrapPreservesPriorBalances() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        uint256 hk1After1 = _getVaultStake(hotkey1, NETUID1);
        uint256 hk2After1 = _getVaultStake(hotkey2, NETUID1);
        uint256 hk3After1 = _getVaultStake(hotkey3, NETUID1);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 2 * hk1After1);
        assertEq(_getVaultStake(hotkey2, NETUID1), 2 * hk2After1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 2 * hk3After1);
        assertEq(lens.totalStake(TOKEN1), 60 ether);
    }

    function _setNetuid1Set(bytes32 a, bytes32 b, bytes32 c) private {
        _setValidators(NETUID1, _hotkeys(a, b, c), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3));
    }

    function test_LastSeenSnapshot_InitializedOnFirstWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        bytes32[] memory lastSeen = _lastSeen(TOKEN1);
        assertEq(lastSeen[0], hotkey1);
        assertEq(lastSeen[1], hotkey2);
        assertEq(lastSeen[2], hotkey3);
    }

    function test_RotationSweptOnRebalance() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 hk3Before = _getVaultStake(hotkey3, NETUID1);
        assertGt(hk3Before, CHAIN_MIN_STAKE);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out slot must be drained");
        assertEq(_countRebalancedLogs(logs), 1, "silent consolidation; only the post-consolidation alignment logs");

        bytes32[] memory lastSeen = _lastSeen(TOKEN1);
        assertEq(lastSeen.length, 3);
        assertEq(lastSeen[2], hotkey4, "cleared rotated-out slot follows the current set");
    }

    function test_RotationSweptOnNextWrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake consolidated before second deposit");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 60 ether, 10);
    }

    function test_RotationSweptOnUnwrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(received, 30 ether, 10, "user must receive full deposit including rotated-out stake");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake drained as part of unwrap");
    }

    function test_RotationMultipleBacklog_ConsolidatesAllRotatedOutStake() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 hk2Before = _getVaultStake(hotkey2, NETUID1);
        uint256 hk3Before = _getVaultStake(hotkey3, NETUID1);
        assertGt(hk2Before, CHAIN_MIN_STAKE);
        assertGt(hk3Before, CHAIN_MIN_STAKE);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);
        _setNetuid1Set(hotkey1, hotkey4, hotkey3); // hotkey3 returned before any vault call; only hotkey2 is now dropped.

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "hotkey2 rotated-out stake consolidated");
        assertApproxEqAbs(_getVaultStake(hotkey3, NETUID1), hk3Before, 1, "hk3 stays - back in current set");
    }

    function test_RotationNoChangeIsNoOp() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 hk3 = _getVaultStake(hotkey3, NETUID1);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countRebalancedLogs(logs), 0, "no-op rebalance emits nothing");
        assertEq(_getVaultStake(hotkey3, NETUID1), hk3);
    }

    function test_UnwrapSyncsEmissions() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 5 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(received, 35 ether, 1e9, "sole holder receives deposit + emissions");
        assertLt(_totalVaultStakeAcrossHotkeys(NETUID1), 1e9, "no meaningful alpha left after full exit");
    }

    function test_EmissionsShareEquallyAcrossHolders() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        _simulateAlphaDeposit(bob, NETUID1, 30 ether);
        _wrap(bob, NETUID1);

        _simulateEmissions(NETUID1, 20 ether);

        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, aliceSub, 0);

        uint256 aliceReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(aliceReceived, 40 ether, 1e9, "alice gets her 30 + half of 20 emissions");

        uint256 bobShares = vault.balanceOf(bob, TOKEN1);
        bytes32 bobSub = _toSubstrate(bob);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobSub, 0);

        uint256 bobReceived = _userStakeAcrossHotkeys(bob, NETUID1);
        assertApproxEqAbs(bobReceived, 40 ether, 1e9, "bob gets his 30 + half of 20 emissions");
    }

    function test_PartialUnwrapAccountsForEmissions() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);

        _simulateEmissions(NETUID1, 10 ether);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares / 2, aliceSub, 0);

        uint256 aliceReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertApproxEqAbs(aliceReceived, 20 ether, 1e9, "alice gets half of 40 = 20");

        uint256 vaultRemaining = _totalVaultStakeAcrossHotkeys(NETUID1);
        assertApproxEqAbs(vaultRemaining, 20 ether, 1e9, "remaining shares back ~20 alpha");
    }

    function test_TotalStake_ReflectsEmissionsWithoutSync() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);
        uint256 priceBefore = lens.sharePrice(TOKEN1);

        _simulateEmissions(NETUID1, 5 ether);

        assertEq(lens.totalStake(TOKEN1), _totalVaultStakeAcrossHotkeys(NETUID1), "totalStake tracks live stake");
        assertEq(lens.totalStake(TOKEN1), 35 ether, "totalStake includes the 5 ether emission");
        assertGt(lens.sharePrice(TOKEN1), priceBefore, "sharePrice rises with emissions");
    }

    function test_EmptyVault_ViewsReturnZeroNotRevert() public {
        (AlphaVault fresh, AlphaVaultLens freshLens) = _deployVaultAndLens(address(registry));
        fresh.createSubnetProxy(NETUID1);
        uint256 tokenId = fresh.currentTokenId(NETUID1);

        assertEq(freshLens.totalStake(tokenId), 0, "totalStake returns 0 for a vault with no stake");
        assertEq(
            freshLens.previewWrap(tokenId, 1 ether), 1 ether * 1e9, "previewWrap returns the empty-vault initial rate"
        );
    }

    function test_Rebalance_SingleValidatorSet() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(10_000));

        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _simulateEmissions(NETUID1, 4 ether);
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 34 ether, "single-validator stake stays whole and live");
    }

    function test_WrapRebalancesPreSkewedBalances() public {
        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _simulateEmissions(NETUID1, 40 ether);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 ether, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 100 ether, "total alpha conserved across deposit + rebalance");
        assertEq(lens.totalStake(TOKEN1), 100 ether, "totalStake synced to on-chain total");

        assertEq(_getVaultStake(hotkey1, NETUID1), _weighted(100 ether, NETUID1_BPS_HK1));
        assertEq(_getVaultStake(hotkey2, NETUID1), _weighted(100 ether, NETUID1_BPS_HK2));
        assertEq(_getVaultStake(hotkey3, NETUID1), _weighted(100 ether, NETUID1_BPS_HK3));
    }

    function test_WrapAutoRebalancesTwoValidatorSet() public {
        _simulateAlphaDepositHotkey(alice, NETUID2, 100 ether, hotkey2);
        _wrapHotkey(alice, NETUID2, hotkey2);

        assertEq(_totalVaultStakeAcrossHotkeys(NETUID2), 100 ether, "total alpha conserved");
        assertEq(lens.totalStake(TOKEN2), 100 ether, "totalStake synced");
        assertEq(_getVaultStake(hotkey2, NETUID2), _weighted(100 ether, NETUID2_BPS_HK2));
        assertEq(_getVaultStake(hotkey1, NETUID2), _weighted(100 ether, NETUID2_BPS_HK1));
    }

    function testFuzz_WrapUnwrapRoundTripPreservesAlpha(uint256 d) public {
        d = bound(d, CHAIN_MIN_STAKE, type(uint64).max);

        _simulateAlphaDeposit(alice, NETUID1, d);
        _wrap(alice, NETUID1);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, aliceSub, 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);

        assertEq(received, d, "round-trip preserves alpha exactly");
    }

    function testFuzz_RebalanceIdempotent(uint256 b1, uint256 b2, uint256 b3) public {
        b1 = bound(b1, 0, type(uint64).max);
        b2 = bound(b2, 0, type(uint64).max);
        b3 = bound(b3, 0, type(uint64).max);

        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, b1, b2, b3);

        vault.rebalance(NETUID1);
        uint256 b1After = _getVaultStake(hotkey1, NETUID1);
        uint256 b2After = _getVaultStake(hotkey2, NETUID1);
        uint256 b3After = _getVaultStake(hotkey3, NETUID1);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), b1After, "hotkey1 unchanged on second rebalance");
        assertEq(_getVaultStake(hotkey2, NETUID1), b2After, "hotkey2 unchanged on second rebalance");
        assertEq(_getVaultStake(hotkey3, NETUID1), b3After, "hotkey3 unchanged on second rebalance");
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "no Rebalanced events on second call");
    }

    function testFuzz_UnwrapConservesAlpha(uint256 b1, uint256 b2, uint256 b3, uint256 burnPct) public {
        uint256 minAmt = CHAIN_MIN_STAKE;
        // Keep the gathered total inside a single uint64 stake entry.
        uint256 perHotkeyMax = type(uint64).max / 3;
        b1 = bound(b1, minAmt, perHotkeyMax);
        b2 = bound(b2, minAmt, perHotkeyMax);
        b3 = bound(b3, minAmt, perHotkeyMax);
        burnPct = bound(burnPct, 1, 99);

        uint256 d = b1 + b2 + b3;
        _simulateAlphaDepositHotkey(alice, NETUID1, d, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _plantVaultStakes(NETUID1, b1, b2, b3);

        uint256 supply = vault.totalSupply(TOKEN1);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * burnPct / 100;
        uint256 expectedAssets = (burnShares * ((b1 + b2 + b3) + 1)) / (supply + 1e9);

        bytes32 aliceSub = _toSubstrate(alice);

        if (expectedAssets < minAmt) {
            vm.prank(alice);
            vm.expectRevert(WithdrawTooSmall.selector);
            vault.unwrap(TOKEN1, burnShares, aliceSub, 0);
            return;
        }

        vm.prank(alice);
        vault.unwrap(TOKEN1, burnShares, aliceSub, 0);

        uint256 userReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        uint256 vaultAfter = _totalVaultStakeAcrossHotkeys(NETUID1);

        assertEq(userReceived, expectedAssets, "delivers exactly the pro-rata assets");
        assertEq(vaultAfter + userReceived, b1 + b2 + b3, "unwrap conserves total alpha");
    }

    function testFuzz_WrapLandsExactlyOnTargets(uint256 d) public {
        uint256 minAmt = CHAIN_MIN_STAKE;
        // Choose the first deposit whose smallest weighted slice clears the move floor.
        uint16 smallestBps = NETUID1_BPS_HK3;
        uint256 minD = (minAmt * BPS_BASE + (smallestBps - 1)) / smallestBps;
        d = bound(d, minD, type(uint64).max);

        _simulateAlphaDepositHotkey(alice, NETUID1, d, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        uint256 t1 = _weighted(d, NETUID1_BPS_HK1);
        uint256 t2 = _weighted(d, NETUID1_BPS_HK2);
        uint256 t3 = d - t1 - t2;

        assertEq(_getVaultStake(hotkey1, NETUID1), t1, "hotkey1 hits weight target exactly");
        assertEq(_getVaultStake(hotkey2, NETUID1), t2, "hotkey2 hits weight target exactly");
        assertEq(_getVaultStake(hotkey3, NETUID1), t3, "hotkey3 hits weight target exactly");
        assertEq(lens.totalStake(TOKEN1), d, "totalStake synced to deposit amount");
    }

    function testFuzz_RotatedOutStakeReclaimedAcrossRotation(uint256 b1, uint256 b2, uint256 b3) public {
        // Bound the gathered total to uint64; keep hotkey1 movable while fuzzing hotkey3 down to zero.
        uint256 perCap = type(uint64).max / 3;
        b1 = bound(b1, CHAIN_MIN_STAKE, perCap);
        b2 = bound(b2, 0, perCap);
        b3 = bound(b3, 0, perCap);

        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey4, _subnetColdkey(NETUID1), NETUID1, 0);
        _plantVaultStakes(NETUID1, b1, b2, b3);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vault.rebalance(NETUID1);

        uint256 a1 = _getVaultStake(hotkey1, NETUID1);
        uint256 a2 = _getVaultStake(hotkey2, NETUID1);
        uint256 a4 = _getVaultStake(hotkey4, NETUID1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake fully consolidated by the roller");
        assertEq(a1 + a2 + a4, b1 + b2 + b3, "active set holds the whole post-roll total");
        assertEq(lens.totalStake(TOKEN1), b1 + b2 + b3, "totalStake counts the consolidated union");

        bytes32[] memory seen = _lastSeen(TOKEN1);
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey2);
        assertEq(seen[2], hotkey4, "remembered set refreshed to the current set");
    }

    function testFuzz_RebalanceConvergesWithinBoundToFloorFixpoint(uint256 b1, uint256 b2, uint256 b3) public {
        b1 = bound(b1, 0, type(uint64).max);
        b2 = bound(b2, 0, type(uint64).max);
        b3 = bound(b3, 0, type(uint64).max);

        _simulateAlphaDeposit(alice, NETUID1, 30 ether);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, b1, b2, b3);

        uint256 preTotal = b1 + b2 + b3;
        uint256 minAmt = CHAIN_MIN_STAKE;

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 a1 = _getVaultStake(hotkey1, NETUID1);
        uint256 a2 = _getVaultStake(hotkey2, NETUID1);
        uint256 a3 = _getVaultStake(hotkey3, NETUID1);

        assertEq(a1 + a2 + a3, preTotal, "rebalance conserves total alpha");
        assertEq(lens.totalStake(TOKEN1), preTotal, "totalStake synced to on-chain total");
        assertLe(_countRebalancedLogs(logs), 2, "rebalance loop bounded by N-1 iterations");

        uint256 t1 = _weighted(preTotal, NETUID1_BPS_HK1);
        uint256 t2 = _weighted(preTotal, NETUID1_BPS_HK2);
        uint256 t3 = preTotal - t1 - t2;

        uint256 maxOver;
        uint256 maxUnder;
        if (a1 > t1) {
            uint256 delta = a1 - t1;
            if (delta > maxOver) maxOver = delta;
        } else if (a1 < t1) {
            uint256 delta = t1 - a1;
            if (delta > maxUnder) maxUnder = delta;
        }
        if (a2 > t2) {
            uint256 delta = a2 - t2;
            if (delta > maxOver) maxOver = delta;
        } else if (a2 < t2) {
            uint256 delta = t2 - a2;
            if (delta > maxUnder) maxUnder = delta;
        }
        if (a3 > t3) {
            uint256 delta = a3 - t3;
            if (delta > maxOver) maxOver = delta;
        } else if (a3 < t3) {
            uint256 delta = t3 - a3;
            if (delta > maxUnder) maxUnder = delta;
        }

        uint256 minMatchable = maxOver < maxUnder ? maxOver : maxUnder;
        assertLt(minMatchable, minAmt, "rebalance reaches floor-bounded fixpoint");
    }
}
