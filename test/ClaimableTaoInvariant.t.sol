// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract ClaimableTaoHandler is Test {
    AlphaVault public immutable vault;
    ClaimableTaoInvariantTest public immutable harness;
    uint256 public immutable tokenId;
    address[] public actors;
    uint256 public totalDonated;
    uint256 public totalClaimed;
    uint256 public actions;
    uint256 public unassigned;
    mapping(address => uint256) public earned;
    mapping(address => uint256) public claimed;

    modifier countAction() {
        ++actions;
        _;
    }

    constructor(AlphaVault _vault, ClaimableTaoInvariantTest _harness, uint256 _tokenId, address[] memory _actors) {
        vault = _vault;
        harness = _harness;
        tokenId = _tokenId;
        actors = _actors;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function donate(uint256 amount) external countAction {
        amount = bound(amount, 1, 1_000 ether);
        address clone = vault.subnetClone(tokenId);
        vm.deal(clone, clone.balance + amount);
        totalDonated += amount;
        _allocate(amount);
    }

    // Independent arrival ledger: split each gift using the balances at arrival.
    // There is no cumulative index or debt checkpoint in this model.
    function _allocate(uint256 amount) private {
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) {
            unassigned += amount;
            return;
        }
        for (uint256 i; i < actors.length; ++i) {
            earned[actors[i]] += amount * vault.balanceOf(actors[i], tokenId) / supply;
        }
    }

    function wrap(uint256 actorSeed, uint256 amount) external countAction {
        amount = bound(amount, 1e9, 1_000e9);
        harness.wrapFor(_actor(actorSeed), amount);
        if (unassigned != 0) {
            uint256 arrival = unassigned;
            unassigned = 0;
            _allocate(arrival);
        }
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external countAction {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = vault.balanceOf(from, tokenId);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        vault.safeTransferFrom(from, to, tokenId, amount, "");
    }

    function claim(uint256 actorSeed) external countAction {
        address actor = _actor(actorSeed);
        address clone = vault.subnetClone(tokenId);
        uint256 cloneBefore = clone.balance;
        uint256 delivered = harness.claimQuotedFor(actor);
        assertEq(cloneBefore - clone.balance, delivered);
        totalClaimed += delivered;
        claimed[actor] += delivered;
    }

    function exitForTao(uint256 actorSeed, uint256 shareSeed) external countAction {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, shares, 0) { } catch { }
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract ClaimableTaoInvariantTest is AlphaVaultTestBase {
    ClaimableTaoHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockStaking(STAKING_PRECOMPILE).setNativeTaoUnits(true);
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = makeAddr("carol");
        for (uint256 i; i < actors.length;) {
            _depositAndWrap(actors[i], NETUID1, 50e9);
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

    function claimQuotedFor(address user) external returns (uint256 delivered) {
        return _claimQuotedAmount(user, TOKEN1);
    }

    function invariant_CloneBalanceCoversReservedTao() public view {
        address clone = vault.subnetClone(TOKEN1);
        assertGe(clone.balance, vault.taoLiability(TOKEN1));
    }

    function invariant_LiabilityNeverExceedsDonated() public view {
        assertLe(vault.taoLiability(TOKEN1) + handler.totalClaimed(), handler.totalDonated());
    }

    function invariant_EachHolderKeepsTheirShareOfEveryArrival() public view {
        // Each allocation/checkpoint can differ by a few wei. The public quote also floors to 1 RAO.
        uint256 rounding = 1e9 + 4 * (handler.actions() + 1);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertApproxEqAbs(
                handler.claimed(actor) + lens.claimableTaoOf(actor, TOKEN1),
                handler.earned(actor),
                rounding,
                "arrival entitlement belongs to its historical holder"
            );
        }
    }

    function invariant_EveryDonatedWeiIsPaidOrStillOnTheClone() public view {
        assertEq(vault.subnetClone(TOKEN1).balance + handler.totalClaimed(), handler.totalDonated());
    }
}
