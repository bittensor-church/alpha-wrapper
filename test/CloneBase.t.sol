// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CloneBase } from "src/CloneBase.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { CHAIN_MIN_STAKE, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract CloneBaseSellAlphaTest is Test {
    SubnetClone clone;
    bytes32 cloneColdkey;
    bytes32 constant HOTKEY = keccak256("hk");
    uint256 constant NETUID = 1;

    function setUp() public {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        vm.deal(STAKING_PRECOMPILE, 1000 ether);
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeRate(1, 1);
        MockStaking(STAKING_PRECOMPILE).setChainMinStake(CHAIN_MIN_STAKE);

        SubnetClone impl = new SubnetClone();
        clone = SubnetClone(payable(Clones.clone(address(impl))));
        clone.initialize(address(this));

        cloneColdkey = keccak256(abi.encodePacked("evm:", address(clone)));
        MockStaking(STAKING_PRECOMPILE).setStake(HOTKEY, cloneColdkey, NETUID, 50 ether);
    }

    function test_SellAlphaForTao_CreditsCloneNativeBalance() public {
        uint256 balanceBefore = address(clone).balance;
        clone.sellAlphaForTao(HOTKEY, NETUID, 30 ether);
        assertEq(address(clone).balance - balanceBefore, 30 ether);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(HOTKEY, cloneColdkey, NETUID), 20 ether);
    }

    function test_SellAlphaForTao_NoOpOnZero() public {
        // Toggle removeStake to revert so a missing zero-guard would surface as a revert here.
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeReverts(true);
        uint256 balanceBefore = address(clone).balance;
        clone.sellAlphaForTao(HOTKEY, NETUID, 0);
        assertEq(address(clone).balance, balanceBefore);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(HOTKEY, cloneColdkey, NETUID), 50 ether);
    }

    function test_OnlyWrapperCanSellAlphaForTao() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(CloneBase.NotWrapper.selector);
        clone.sellAlphaForTao(HOTKEY, NETUID, 1);
    }
}
