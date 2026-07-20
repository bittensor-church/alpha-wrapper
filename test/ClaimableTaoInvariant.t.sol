// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Tests that random sequences of deposits, transfers, exits, donations and claims never let the
// vault promise more TAO than its subnet clone actually holds, and that holders as a group can
// never withdraw more TAO than actually arrived.

import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";

contract ClaimableTaoHandler is Test {
    AlphaVault public immutable vault;
    ClaimableTaoInvariantTest public immutable harness;
    uint256 public immutable tokenId;
    address[] public actors;
    uint256 public totalDonated;
    uint256 public totalClaimed;

    constructor(AlphaVault _vault, ClaimableTaoInvariantTest _harness, uint256 _tokenId, address[] memory _actors) {
        vault = _vault;
        harness = _harness;
        tokenId = _tokenId;
        actors = _actors;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        address clone = vault.subnetClone(tokenId);
        vm.deal(clone, clone.balance + amount);
        totalDonated += amount;
    }

    function wrap(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1 ether, 1_000 ether);
        harness.wrapFor(_actor(actorSeed), amount);
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = vault.balanceOf(from, tokenId);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        vault.safeTransferFrom(from, to, tokenId, amount, "");
    }

    // The quote is a commitment: a claim pays exactly what the view promised and moves exactly
    // that much out of the clone, so a payout the chain rounds down can never clear more
    // entitlement than it delivered. A zero quote must not be claimable at all.
    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        address clone = vault.subnetClone(tokenId);
        uint256 quoted = vault.claimableTaoOf(actor, tokenId);
        if (quoted == 0) {
            vm.expectRevert();
            vm.prank(actor);
            vault.claimTao(tokenId, payable(actor));
            return;
        }
        uint256 cloneBefore = clone.balance;
        uint256 actorBefore = actor.balance;
        vm.prank(actor);
        vault.claimTao(tokenId, payable(actor));
        uint256 delivered = actor.balance - actorBefore;
        assertEq(delivered, quoted);
        assertEq(cloneBefore - clone.balance, delivered);
        totalClaimed += delivered;
    }

    function exitForTao(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, shares, 0) { } catch { }
    }
}

contract ClaimableTaoInvariantTest is AlphaVaultTestBase {
    ClaimableTaoHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = makeAddr("carol");
        for (uint256 i; i < actors.length;) {
            _depositAndWrap(actors[i], NETUID1, 50 ether);
            unchecked {
                ++i;
            }
        }
        handler = new ClaimableTaoHandler(vault, this, TOKEN1, actors);
        targetContract(address(handler));
    }

    function wrapFor(address user, uint256 amount) external {
        _depositAndWrap(user, NETUID1, amount);
    }

    function invariant_CloneBalanceCoversReservedTao() public view {
        address clone = vault.subnetClone(TOKEN1);
        assertGe(clone.balance, vault.taoLiability(TOKEN1) + vault.excludedTao(TOKEN1));
    }

    // Repeated debt re-baselining under these exact amounts accrues a one-wei phantom entitlement
    // while a zero-supply donation sits quarantined; the final claim must pay only what the
    // recorded liability backs instead of drawing on that quarantine.
    function test_PhantomEntitlement_CannotOverdrawReservedBacking() public {
        handler.donate(166020153748861866463033272813676692912666046992);
        handler.transferShares(110000000000000000000, 9555, 2827);
        handler.donate(102142341534152);
        handler.exitForTao(0, 73315913919308072336014126598163198670341373657912476761918536887541170423);
        handler.exitForTao(21584, 80000000000000000000);
        handler.transferShares(707555285614818085490393633386771809465, 2, 13107892645965101188);
        handler.donate(96059874);
        handler.exitForTao(1095121753685999, type(uint256).max - 2);
        handler.exitForTao(87125161342098102928376337271756967828300673868306152515792131233, type(uint256).max - 1);
        handler.exitForTao(303583378333217576626297821739604849790832966811745973, type(uint256).max - 2);
        handler.transferShares(1000, 500000, 40000000);
        handler.transferShares(
            202381823421021314971225073412094948282656,
            7046475790067961059792,
            702498195375104724870804370661893358612984996200603330987954554
        );
        handler.claim(2641);
        handler.exitForTao(7238, 17820);
        handler.claim(4394);
        handler.donate(4359);
        handler.claim(3438);

        address clone = vault.subnetClone(TOKEN1);
        assertGe(clone.balance, vault.taoLiability(TOKEN1) + vault.excludedTao(TOKEN1));
    }

    function invariant_LiabilityNeverExceedsDonated() public view {
        assertLe(vault.taoLiability(TOKEN1) + handler.totalClaimed(), handler.totalDonated());
    }
}
