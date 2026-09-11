// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { MockStaking, CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// @dev Healthy chain campaign: one owned validator, no losses, no emissions or sweep threshold.
///      These preconditions make adequately sized exits mandatory, so failures must never be caught.
contract AlphaAccountingHandler is Test {
    AlphaVault public immutable vault;
    AlphaVaultLens public immutable lens;
    AlphaAccountingInvariantTest public immutable harness;
    uint256 public immutable tokenId;
    address[3] public actors;
    uint256 public deposited;
    uint256 public alphaDelivered;
    uint256 public alphaSold;
    uint256 public taoPaid;
    uint256 public shareConversions;

    constructor(
        AlphaAccountingInvariantTest owner,
        AlphaVault v,
        AlphaVaultLens l,
        uint256 id,
        address[3] memory users
    ) {
        harness = owner;
        vault = v;
        lens = l;
        tokenId = id;
        actors = users;
    }

    function wrap(uint256 actorSeed, uint256 amount) external {
        _deposit(actors[actorSeed % actors.length], bound(amount, 1e9, 1_000e9));
    }

    function _deposit(address actor, uint256 amount) private {
        uint256 sharesBefore = vault.balanceOf(actor, tokenId);
        harness.depositFor(actor, amount);
        assertGt(vault.balanceOf(actor, tokenId), sharesBefore, "a healthy deposit gives the depositor shares");
        deposited += amount;
        ++shareConversions;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        uint256 balance = vault.balanceOf(from, tokenId);
        if (balance == 0) return;
        vm.prank(from);
        vault.safeTransferFrom(from, actors[toSeed % actors.length], tokenId, bound(amount, 0, balance), "");
    }

    function unwrap(uint256 actorSeed, bool forTao) external {
        _exit(actors[actorSeed % actors.length], forTao);
    }

    function _exit(address actor, bool forTao) private {
        uint256 shares = vault.balanceOf(actor, tokenId);
        if (shares == 0) return;
        // This campaign fixes the precompile quote at 1 TAO RAO per alpha RAO,
        // so the alpha quote also measures the sale minimum in TAO RAO.
        // A share transfer can leave a sub-floor holder. A real top-up makes that position exit-able.
        (uint256 quoted,) = lens.previewUnwrap(tokenId, shares);
        if (quoted < CHAIN_MIN_STAKE) {
            _deposit(actor, 1e9);
            shares = vault.balanceOf(actor, tokenId);
        }
        uint256 backingBefore = harness.chainBacking();
        if (forTao) {
            uint256 balanceBefore = actor.balance;
            vm.prank(actor);
            vault.unwrapForTao(tokenId, shares, 0);
            uint256 sold = backingBefore - harness.chainBacking();
            uint256 paid = actor.balance - balanceBefore;
            assertEq(paid, sold * VaultMath.TAO_NATIVE_QUANTUM, "TAO sale pays the precompile quote in native units");
            alphaSold += sold;
            taoPaid += paid;
        } else {
            uint256 stakeBefore = harness.recipientStake(actor);
            vm.prank(actor);
            vault.unwrap(tokenId, shares, keccak256(abi.encodePacked("evm:", actor)), 0);
            uint256 delivered = harness.recipientStake(actor) - stakeBefore;
            assertEq(backingBefore - harness.chainBacking(), delivered, "alpha reaches the caller's destination");
            alphaDelivered += delivered;
        }
        assertEq(vault.balanceOf(actor, tokenId), 0, "a healthy full exit retires the holder's shares");
        ++shareConversions;
    }

    function closeAllPositions() external {
        for (uint256 i; i < actors.length; ++i) {
            _exit(actors[i], i % 2 == 0);
        }
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract AlphaAccountingInvariantTest is AlphaVaultTestBase {
    AlphaAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));
        _setDustThreshold(0);
        MockStaking(STAKING_PRECOMPILE).setNativeTaoUnits(true);
        handler = new AlphaAccountingHandler(this, vault, lens, TOKEN1, [alice, bob, makeAddr("carol")]);
        handler.wrap(0, 50e9);
        handler.wrap(1, 50e9);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.wrap.selector;
        selectors[1] = handler.transferShares.selector;
        selectors[2] = handler.unwrap.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function depositFor(address actor, uint256 amount) external {
        _depositAndWrap(actor, NETUID1, amount);
    }

    function chainBacking() public view returns (uint256) {
        return _getVaultStake(hotkey1, NETUID1);
    }

    function recipientStake(address actor) public view returns (uint256) {
        return _getStake(hotkey1, actor, NETUID1);
    }

    function invariant_EveryDepositedAlphaIsHeldDeliveredOrSold() public view {
        assertEq(chainBacking() + handler.alphaDelivered() + handler.alphaSold(), handler.deposited());
        assertEq(handler.taoPaid(), handler.alphaSold() * VaultMath.TAO_NATIVE_QUANTUM);
    }

    function invariant_AllSharesBelongToTheKnownHolders() public view {
        uint256 held;
        for (uint256 i; i < 3; ++i) {
            held += vault.balanceOf(handler.actors(i), TOKEN1);
        }
        assertEq(held, vault.totalSupply(TOKEN1));
    }

    function afterInvariant() public {
        handler.closeAllPositions();
        assertEq(vault.totalSupply(TOKEN1), 0, "every healthy holder can leave");
        assertLe(chainBacking(), handler.shareConversions(), "at most one RAO per share conversion stays behind");
        invariant_EveryDepositedAlphaIsHeldDeliveredOrSold();
    }
}
