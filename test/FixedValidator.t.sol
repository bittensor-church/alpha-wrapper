// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { FixedValidator } from "src/FixedValidator.sol";

contract FixedValidatorTest is Test {
    bytes32 internal constant HOTKEY = keccak256("the-validator");

    FixedValidator internal fixedValidator;

    function setUp() public {
        fixedValidator = new FixedValidator(HOTKEY);
    }

    function test_RevertWhen_ZeroHotkey() public {
        vm.expectRevert(FixedValidator.ZeroHotkey.selector);
        new FixedValidator(bytes32(0));
    }

    /// Every netuid resolves to the same single hotkey at full weight - the registry is the
    /// deployment-pinned constant the vault stakes everything under.
    function testFuzz_EveryNetuidReturnsThePinnedHotkeyAtFullWeight(uint256 netuid) public view {
        (bytes32[] memory hotkeys, uint16[] memory weights) = fixedValidator.getValidators(netuid);
        assertEq(hotkeys.length, 1, "exactly one validator");
        assertEq(weights.length, 1, "lengths must match");
        assertEq(hotkeys[0], HOTKEY, "the pinned hotkey");
        assertEq(weights[0], 10_000, "full weight");
    }

    function test_HotkeyIsExposed() public view {
        assertEq(fixedValidator.hotkey(), HOTKEY);
    }
}
