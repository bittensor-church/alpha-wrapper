// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { WithdrawTooSmall } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { CHAIN_MIN_STAKE, CHAIN_MIN_TRANSFER, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract MinStakeFloorTest is AlphaVaultTestBase {
    uint256 private constant PRICE_HALF = 0.5e18;

    function _setChainMinStake(uint256 minStakeTao) private {
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(minStakeTao);
    }

    function test_RevertWhen_WrapDepositBelowTaoFloor() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_HALF);

        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);
    }

    function test_Wrap_SucceedsAtTaoFloorBoundaryUnderLowPrice() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, PRICE_HALF);

        _simulateAlphaDepositHotkey(alice, 99, 4e6, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 4e6);
        assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0);
    }

    function test_Rebalance_SkipsSubFloorMove() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 8e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        // The 2e6-alpha corrective move is worth only 1e6 TAO RAO, below the floor.
        _plantVaultStake(hotkey1, NETUID1, 6e6);
        _plantVaultStake(hotkey2, NETUID1, 2e6);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "sub-floor move skipped pre-call");
        assertEq(_getVaultStake(hotkey1, NETUID1), 6e6);
        assertEq(_getVaultStake(hotkey2, NETUID1), 2e6);
    }

    function test_RevertWhen_RebalanceMoveFailsAboveFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 8e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _plantVaultStake(hotkey1, NETUID1, 6e6);
        _plantVaultStake(hotkey2, NETUID1, 2e6);
        MockStaking(STAKING_PRECOMPILE).setMoveStakeReverts(true);

        vm.expectRevert(bytes("MockStaking: moveStake reverted"));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 6e6, "balances unchanged after the bubbled failure");
        assertEq(_getVaultStake(hotkey2, NETUID1), 2e6);
    }

    // The mock consumes all gas on a sub-floor move, so the budget also checks that no call is attempted.
    function test_Wrap_SkipsSubFloorRebalanceWithinGasBudget() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(9900, 100));
        MockStaking(STAKING_PRECOMPILE).setConsumeAllGasOnFailure(true);
        _setAlphaPrice(NETUID1, PRICE_HALF);

        _simulateAlphaDepositHotkey(alice, NETUID1, 6e6, hotkey1);
        vm.recordLogs();
        vm.prank(alice);
        vault.wrap{ gas: 1_500_000 }(NETUID1, hotkey1, 0);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "doomed move never attempted");
        assertGt(vault.balanceOf(alice, TOKEN1), 0, "wrap completed within the fixed gas budget");
    }

    function test_RevertWhen_UnwrapWithAllSlotsSubFloor() public {
        _depositAndWrap(alice, NETUID1, 4_500_000);
        _plantVaultStakes(NETUID1, 1_500_000, 1_500_000, 1_500_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapRequestBelowFloor() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _setAlphaPrice(NETUID1, PRICE_HALF);
        uint256 burnShares = vault.balanceOf(alice, TOKEN1) * 5 / 100;

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice), 0);
    }

    function test_Unwrap_DeliversExactlyAtFloorValue() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        uint256 shares = _sharesForExactAssets(TOKEN1, CHAIN_MIN_STAKE, 40e6);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), CHAIN_MIN_STAKE, "a request worth exactly the floor delivers");
    }

    function test_RevertWhen_DepositBelowRaisedChainFloor() public {
        _setChainMinStake(5e6);
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 3e6, hotkey4);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);
    }

    function test_RevertWhen_UnwrapBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setChainMinStake(5e6);

        uint256 shares = _sharesForExactAssets(TOKEN1, 3e6, 40e6);
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_WrapBetweenTheMoveAndUnstakeMinimums() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);
        uint256 deposit = (CHAIN_MIN_TRANSFER + CHAIN_MIN_STAKE) / 2;
        _simulateAlphaDepositHotkey(alice, 99, deposit, hotkey4);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);

        _setChainMinStake(CHAIN_MIN_TRANSFER);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), deposit, "the chain takes it once the vault stops refusing");
    }

    // Ensure a partial sale: full drains bypass the minimum this test exercises.
    function test_UnwrapForTao_FollowsRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 300e6);
        uint256 tenth = vault.balanceOf(alice, TOKEN1) / 10;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, tenth, 0);
        assertGt(alice.balance, balanceBefore, "the partial sale clears the current minimum");

        _setChainMinStake(50e6);
        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrapForTao(TOKEN1, tenth, 0);
    }

    function test_Rebalance_SkipsEveryMoveBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _plantVaultStakes(NETUID1, 20e6, 10e6, 10e6);
        _setChainMinStake(50e6);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "a raised minimum stops every corrective move");
        assertEq(_getVaultStake(hotkey1, NETUID1), 20e6, "the split is left drifted");
    }

    function test_Rebalance_FollowsLoweredChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setAlphaPrice(NETUID1, PRICE_HALF);
        _plantVaultStakes(NETUID1, 16e6, 12e6, 12e6);

        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 16e6, "the corrective move is under the current minimum");

        _setChainMinStake(5e5);
        vault.rebalance(NETUID1);

        assertLt(_getVaultStake(hotkey1, NETUID1), 16e6, "it lands once the minimum drops below it");
    }

    function test_Wrap_FollowsLoweredChainFloor() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 1e6, hotkey4);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.DepositTooSmall.selector);
        vault.wrap(99, hotkey4, 0);

        _setChainMinStake(5e5);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 1e6, "deposit lands once the chain minimum drops below it");
    }

    function test_Wrap_ChainMinimumOfZeroLeavesTheGateOpen() public {
        _setChainMinStake(0);
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);
        _simulateAlphaDepositHotkey(alice, 99, CHAIN_MIN_TRANSFER, hotkey4);

        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), CHAIN_MIN_TRANSFER, "a zero minimum admits whatever the chain will move");
    }

    function testFuzz_Wrap_GateBindsAtTheChainMinimum(uint256 chainMinStake, uint256 deposit) public {
        chainMinStake = bound(chainMinStake, 1, 50e6);
        deposit = bound(deposit, 1, 100e6);
        _setChainMinStake(chainMinStake);
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1e18);
        _simulateAlphaDepositHotkey(alice, 99, deposit, hotkey4);

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.wrap, (99, hotkey4, 0)));

        // The exposed unstake minimum can differ from the mock's independent transfer minimum.
        bool clearsVaultGate = deposit >= chainMinStake;
        bool chainWillMoveIt = deposit >= CHAIN_MIN_TRANSFER;
        assertEq(ok, clearsVaultGate && chainWillMoveIt, "the gate binds exactly at the chain's reported minimum");

        if (!ok) {
            bytes memory expectedRefusal = clearsVaultGate
                ? abi.encodeWithSignature("Error(string)", "MockStaking: AmountTooLow")
                : abi.encodeWithSelector(IAlphaVaultAbi.DepositTooSmall.selector);
            assertEq(keccak256(ret), keccak256(expectedRefusal), "the refusal came from the bar that binds first");
            assertEq(_getVaultStake(hotkey4, 99), 0, "nothing staked behind the refusal");
            assertEq(vault.balanceOf(alice, vault.currentTokenId(99)), 0, "no shares minted behind the refusal");
        }
    }

    function test_RevertWhen_GatherBelowRaisedChainFloor() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _plantVaultStakes(NETUID1, 15e6, 15e6, 10e6);
        _setChainMinStake(20e6);

        uint256 shares = _sharesForExactAssets(TOKEN1, 25e6, 40e6);
        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.GatherBelowFloor.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_PreviewUnwrap_QuotesWhatDustUnwrapRefuses() public {
        _depositAndWrap(alice, NETUID1, 40e6);
        _setAlphaPrice(NETUID1, PRICE_HALF);

        uint256 shares = _sharesForExactAssets(TOKEN1, 3e6, 40e6);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(previewAlpha, 3e6, "preview quotes the pro-rata alpha");

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function testFuzz_Rebalance_NeverTripsChainFloor(uint256 chainPriceE18, uint256 a, uint256 b, uint256 c) public {
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        a = bound(a, 0, 1e16);
        b = bound(b, 0, 1e16);
        c = bound(c, 0, 1e16);
        _depositAndWrap(alice, NETUID1, 30 ether);
        _setAlphaPrice(NETUID1, chainPriceE18);
        uint256 total = _plantVaultStakes(NETUID1, a, b, c);

        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), total, "every attempted move cleared the chain floor");
    }

    // The vault can prove some rejections from a rounded price; otherwise the chain's lower move floor decides.
    function testFuzz_Rebalance_ConsolidationMatchesChainFloor(uint256 dust, uint256 chainPriceE18) public {
        dust = bound(dust, 1, 1e16);
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 ether, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        uint256 tokenId = vault.currentTokenId(99);
        _plantVaultStake(hotkey4, 99, dust);
        _setValidators(99, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));
        _setAlphaPrice(99, chainPriceE18);
        uint256 trueValue = (dust * chainPriceE18) / VaultMath.ALPHA_PRICE_SCALE;
        uint256 read = _alphaPriceRead(99);

        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(vault.rebalance, (99)));

        if (ok) {
            assertEq(_getVaultStake(hotkey4, 99), 0, "rotated-out stake consolidated");
            assertEq(lens.totalStake(tokenId), dust, "pile conserved onto the current set");
            assertGe(trueValue, CHAIN_MIN_TRANSFER, "the roll landed, so it cleared the chain's move bar");
        } else if (bytes4(ret) == IAlphaVaultAbi.ConsolidationBelowFloor.selector) {
            assertLt(
                (dust * (read + VaultMath.ALPHA_PRICE_QUANTUM_E18)) / VaultMath.ALPHA_PRICE_SCALE,
                CHAIN_MIN_STAKE,
                "reject only fires on the provable bound"
            );
        } else {
            assertEq(
                keccak256(ret),
                keccak256(abi.encodeWithSignature("Error(string)", "MockStaking: AmountTooLow")),
                "fall-through surfaces the chain's own refusal"
            );
            assertTrue(
                read == 0
                    || (dust * (read + VaultMath.ALPHA_PRICE_QUANTUM_E18)) / VaultMath.ALPHA_PRICE_SCALE
                        >= CHAIN_MIN_STAKE,
                "fell through only when unprovable"
            );
            assertLt(trueValue, CHAIN_MIN_TRANSFER, "the chain refused because the roll is below its move bar");
        }
    }

    function testFuzz_Unwrap_DeliversExactlyOrRevertsAtomically(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 shareBps,
        uint256 chainPriceE18
    ) public {
        a = bound(a, 0, 1e16);
        b = bound(b, 0, 1e16);
        c = bound(c, 1e10, 1e16);
        shareBps = bound(shareBps, 1, VaultMath.BPS_BASE);
        chainPriceE18 = bound(chainPriceE18, 1, 100e18);
        uint256 supply = _depositAndWrap(alice, NETUID1, 30 ether);
        _setAlphaPrice(NETUID1, chainPriceE18);
        uint256 total = _plantVaultStakes(NETUID1, a, b, c);
        uint256 shares = (supply * shareBps) / VaultMath.BPS_BASE;
        uint256 expected = (shares * (total + VaultMath.VIRTUAL_ASSETS)) / (supply + VaultMath.VIRTUAL_SHARES);

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(vault.unwrap, (TOKEN1, shares, _toSubstrate(alice), expected)));

        if (ok) {
            assertEq(_userStakeAcrossHotkeys(alice, NETUID1), expected, "delivery is exact");
            assertEq(lens.totalStake(TOKEN1), total - expected, "only the delivered alpha left the vault");
        } else {
            bytes4 selector = bytes4(ret);
            bool chainRefusedTheMove =
                keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "MockStaking: AmountTooLow"));
            assertTrue(
                selector == WithdrawTooSmall.selector || selector == IAlphaVaultAbi.GatherBelowFloor.selector
                    || chainRefusedTheMove,
                "only floor-classed reverts are legitimate"
            );
            assertEq(vault.balanceOf(alice, TOKEN1), supply, "shares intact after rollback");
            assertEq(lens.totalStake(TOKEN1), total, "nothing moved on revert");
        }
    }

    function test_Wrap_AcceptsBoundaryAtQuantizedRead() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1.5e9);

        _simulateAlphaDepositHotkey(alice, 99, 2e15, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 2e15);
        assertGt(vault.balanceOf(alice, vault.currentTokenId(99)), 0);
    }

    function test_Rebalance_ConsolidatesRichestSlotInsideOracleQuantumBand() public {
        _registerSubnet(99, hotkey4);
        _setAlphaPrice(99, 1.5e9);
        _simulateAlphaDepositHotkey(alice, 99, 4e15, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        // Inside the oracle band: read value 1.5e6, true value 2.25e6, floor 2e6 TAO RAO.
        _plantVaultStake(hotkey4, 99, 1.5e15);
        _setValidators(99, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));

        vault.rebalance(99);

        assertEq(_getVaultStake(hotkey4, 99), 0, "in-band richest slot consolidated by the chain's own check");
        assertEq(_getVaultStake(hotkey1, 99), 1.5e15, "pile landed on the current set");
    }

    function test_RevertWhen_DeliveryTransferFails() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 40e6, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        uint256 sharesBefore = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.unwrap(TOKEN1, sharesBefore, _toSubstrate(alice), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), sharesBefore, "shares intact after bubbled failure");
    }

    function testFuzz_Unwrap_DeliversExactlyPreview(uint256 priceE18, uint256 deposit) public {
        priceE18 = bound(priceE18, 0.1e18, 100e18);
        uint256 floorAlpha = (CHAIN_MIN_STAKE * VaultMath.ALPHA_PRICE_SCALE) / priceE18 + 1;
        // Keep all weighted slots above the floor; this mock does not apply stake-share rounding.
        deposit = bound(deposit, 4 * floorAlpha, 1e15);

        _setAlphaPrice(NETUID1, priceE18);
        _depositAndWrap(alice, NETUID1, deposit);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, previewAlpha, "delivery is exact - no shortfall above the floor");
    }

    function test_Unwrap_GatherWithinOneQuantumOfFloorDelivers() public {
        _setAlphaPrice(NETUID1, 1e9);
        _depositAndWrap(alice, NETUID1, 6e15);
        _plantVaultStakes(NETUID1, 1_500_000_000_000_000, 1_500_000_000_000_000, 1_500_000_000_000_000);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), previewAlpha, "the gather delivered the full preview");
    }

    function test_RevertWhen_WrapFlushFailsForNonFloorReason() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10e6, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setTransferStakeReverts(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockStaking: transferStake reverted"));
        vault.wrap(99, hotkey4, 0);
    }
}
