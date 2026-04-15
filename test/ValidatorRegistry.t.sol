// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ValidatorRegistryTest is Test {
    event ValidatorsUpdated(uint256 indexed netuid, uint8 count, uint256 timestamp);
    event ValidatorsBatchUpdated(uint256 subnetCount, uint256 timestamp);

    ValidatorRegistry public registry;

    address public admin = address(this);
    address public updater = makeAddr("updater");
    address public nobody = makeAddr("nobody");

    bytes32 public hk1 = keccak256("hotkey1");
    bytes32 public hk2 = keccak256("hotkey2");
    bytes32 public hk3 = keccak256("hotkey3");

    uint256 public constant SN1 = 1;
    uint256 public constant SN2 = 2;

    function setUp() public {
        registry = new ValidatorRegistry(admin, updater);
    }

    // ──────────── setValidators: happy path ──────────────────────────────

    function testSetValidators1() public {
        bytes32[] memory hks = new bytes32[](1);
        uint16[] memory wts = new uint16[](1);
        hks[0] = hk1;
        wts[0] = 10_000;

        vm.prank(updater);
        registry.setValidators(SN1, hks, wts);

        (bytes32[3] memory rHks, uint16[3] memory rWts, uint8 count) = registry.getValidators(SN1);
        assertEq(count, 1);
        assertEq(rHks[0], hk1);
        assertEq(rWts[0], 10_000);
        assertTrue(registry.hasValidators(SN1));
    }

    function testSetValidators2() public {
        bytes32[] memory hks = new bytes32[](2);
        uint16[] memory wts = new uint16[](2);
        hks[0] = hk1;
        hks[1] = hk2;
        wts[0] = 6000;
        wts[1] = 4000;

        vm.prank(updater);
        registry.setValidators(SN1, hks, wts);

        (bytes32[3] memory rHks, uint16[3] memory rWts, uint8 count) = registry.getValidators(SN1);
        assertEq(count, 2);
        assertEq(rHks[0], hk1);
        assertEq(rHks[1], hk2);
        assertEq(rWts[0], 6000);
        assertEq(rWts[1], 4000);
    }

    function testSetValidators3() public {
        bytes32[] memory hks = new bytes32[](3);
        uint16[] memory wts = new uint16[](3);
        hks[0] = hk1;
        hks[1] = hk2;
        hks[2] = hk3;
        wts[0] = 3334;
        wts[1] = 3333;
        wts[2] = 3333;

        vm.prank(updater);
        registry.setValidators(SN1, hks, wts);

        (bytes32[3] memory rHks,, uint8 count) = registry.getValidators(SN1);
        assertEq(count, 3);
        assertEq(rHks[2], hk3);
    }

    function testSetValidatorsEmitsEvent() public {
        bytes32[] memory hks = new bytes32[](1);
        uint16[] memory wts = new uint16[](1);
        hks[0] = hk1;
        wts[0] = 10_000;

        vm.prank(updater);
        vm.expectEmit(true, false, false, true);
        emit ValidatorsUpdated(SN1, 1, block.timestamp);
        registry.setValidators(SN1, hks, wts);
    }

    function testSetValidatorsOverwrite() public {
        bytes32[] memory hks = new bytes32[](1);
        uint16[] memory wts = new uint16[](1);
        hks[0] = hk1;
        wts[0] = 10_000;

        vm.prank(updater);
        registry.setValidators(SN1, hks, wts);

        // Overwrite with different validator
        hks[0] = hk2;
        vm.prank(updater);
        registry.setValidators(SN1, hks, wts);

        (bytes32[3] memory rHks,, uint8 count) = registry.getValidators(SN1);
        assertEq(count, 1);
        assertEq(rHks[0], hk2);
    }

    function testSetValidatorsOverwriteReducesCount() public {
        // Set 3 validators
        bytes32[] memory hks3 = new bytes32[](3);
        uint16[] memory wts3 = new uint16[](3);
        hks3[0] = hk1;
        hks3[1] = hk2;
        hks3[2] = hk3;
        wts3[0] = 3334;
        wts3[1] = 3333;
        wts3[2] = 3333;

        vm.prank(updater);
        registry.setValidators(SN1, hks3, wts3);

        // Overwrite with 1 validator — old slots should be cleared
        bytes32[] memory hks1 = new bytes32[](1);
        uint16[] memory wts1 = new uint16[](1);
        hks1[0] = hk1;
        wts1[0] = 10_000;

        vm.prank(updater);
        registry.setValidators(SN1, hks1, wts1);

        (bytes32[3] memory rHks, uint16[3] memory rWts, uint8 count) = registry.getValidators(SN1);
        assertEq(count, 1);
        assertEq(rHks[1], bytes32(0));
        assertEq(rHks[2], bytes32(0));
        assertEq(rWts[1], 0);
        assertEq(rWts[2], 0);
    }

    // ──────────── setValidators: revert paths ────────────────────────────

    function testSetValidatorsRevertsEmpty() public {
        bytes32[] memory hks = new bytes32[](0);
        uint16[] memory wts = new uint16[](0);

        vm.prank(updater);
        vm.expectRevert(ValidatorRegistry.EmptyValidators.selector);
        registry.setValidators(SN1, hks, wts);
    }

    function testSetValidatorsRevertsTooMany() public {
        bytes32[] memory hks = new bytes32[](4);
        uint16[] memory wts = new uint16[](4);
        hks[0] = hk1;
        hks[1] = hk2;
        hks[2] = hk3;
        hks[3] = keccak256("hk4");
        wts[0] = 2500;
        wts[1] = 2500;
        wts[2] = 2500;
        wts[3] = 2500;

        vm.prank(updater);
        vm.expectRevert(ValidatorRegistry.TooManyValidators.selector);
        registry.setValidators(SN1, hks, wts);
    }

    function testSetValidatorsRevertsLengthMismatch() public {
        bytes32[] memory hks = new bytes32[](2);
        uint16[] memory wts = new uint16[](1);
        hks[0] = hk1;
        hks[1] = hk2;
        wts[0] = 10_000;

        vm.prank(updater);
        vm.expectRevert(ValidatorRegistry.LengthMismatch.selector);
        registry.setValidators(SN1, hks, wts);
    }

    function testSetValidatorsRevertsZeroHotkey() public {
        bytes32[] memory hks = new bytes32[](1);
        uint16[] memory wts = new uint16[](1);
        hks[0] = bytes32(0);
        wts[0] = 10_000;

        vm.prank(updater);
        vm.expectRevert(ValidatorRegistry.ZeroHotkey.selector);
        registry.setValidators(SN1, hks, wts);
    }

    function testSetValidatorsRevertsWeightsNot10000() public {
        bytes32[] memory hks = new bytes32[](2);
        uint16[] memory wts = new uint16[](2);
        hks[0] = hk1;
        hks[1] = hk2;
        wts[0] = 5000; // sum = 8000 != 10000
        wts[1] = 3000;

        vm.prank(updater);
        vm.expectRevert(ValidatorRegistry.WeightsMustSum10000.selector);
        registry.setValidators(SN1, hks, wts);
    }

    function testSetValidatorsRevertsNonUpdater() public {
        bytes32[] memory hks = new bytes32[](1);
        uint16[] memory wts = new uint16[](1);
        hks[0] = hk1;
        wts[0] = 10_000;

        vm.prank(nobody);
        vm.expectRevert();
        registry.setValidators(SN1, hks, wts);
    }

    // ──────────── setValidatorsBatch ─────────────────────────────────────

    function testSetValidatorsBatch() public {
        uint256[] memory netuids = new uint256[](2);
        bytes32[][] memory hkSets = new bytes32[][](2);
        uint16[][] memory wtSets = new uint16[][](2);

        netuids[0] = SN1;
        netuids[1] = SN2;

        hkSets[0] = new bytes32[](1);
        hkSets[0][0] = hk1;
        wtSets[0] = new uint16[](1);
        wtSets[0][0] = 10_000;

        hkSets[1] = new bytes32[](2);
        hkSets[1][0] = hk2;
        hkSets[1][1] = hk3;
        wtSets[1] = new uint16[](2);
        wtSets[1][0] = 6000;
        wtSets[1][1] = 4000;

        vm.prank(updater);
        registry.setValidatorsBatch(netuids, hkSets, wtSets);

        assertTrue(registry.hasValidators(SN1));
        assertTrue(registry.hasValidators(SN2));
        (,, uint8 c1) = registry.getValidators(SN1);
        (,, uint8 c2) = registry.getValidators(SN2);
        assertEq(c1, 1);
        assertEq(c2, 2);
    }

    function testSetValidatorsBatchEmitsEvent() public {
        uint256[] memory netuids = new uint256[](1);
        bytes32[][] memory hkSets = new bytes32[][](1);
        uint16[][] memory wtSets = new uint16[][](1);

        netuids[0] = SN1;
        hkSets[0] = new bytes32[](1);
        hkSets[0][0] = hk1;
        wtSets[0] = new uint16[](1);
        wtSets[0][0] = 10_000;

        vm.prank(updater);
        vm.expectEmit(false, false, false, true);
        emit ValidatorsBatchUpdated(1, block.timestamp);
        registry.setValidatorsBatch(netuids, hkSets, wtSets);
    }

    function testSetValidatorsBatchRevertsLengthMismatch() public {
        uint256[] memory netuids = new uint256[](2);
        bytes32[][] memory hkSets = new bytes32[][](1);
        uint16[][] memory wtSets = new uint16[][](2);

        netuids[0] = SN1;
        netuids[1] = SN2;
        hkSets[0] = new bytes32[](1);
        hkSets[0][0] = hk1;
        wtSets[0] = new uint16[](1);
        wtSets[0][0] = 10_000;
        wtSets[1] = new uint16[](1);
        wtSets[1][0] = 10_000;

        vm.prank(updater);
        vm.expectRevert(ValidatorRegistry.LengthMismatch.selector);
        registry.setValidatorsBatch(netuids, hkSets, wtSets);
    }

    function testSetValidatorsBatchRevertsNonUpdater() public {
        uint256[] memory netuids = new uint256[](0);
        bytes32[][] memory hkSets = new bytes32[][](0);
        uint16[][] memory wtSets = new uint16[][](0);

        vm.prank(nobody);
        vm.expectRevert();
        registry.setValidatorsBatch(netuids, hkSets, wtSets);
    }

    // ──────────── View functions ─────────────────────────────────────────

    function testHasValidatorsReturnsFalseByDefault() public view {
        assertFalse(registry.hasValidators(99));
    }

    function testGetValidatorsReturnsDefaultsForUnset() public view {
        (bytes32[3] memory hks,, uint8 count) = registry.getValidators(99);
        assertEq(count, 0);
        assertEq(hks[0], bytes32(0));
    }

    // ──────────── Access control ─────────────────────────────────────────

    function testUpdaterRoleConstant() public view {
        assertEq(registry.UPDATER_ROLE(), keccak256("UPDATER_ROLE"));
    }

    function testAdminCanGrantUpdaterRole() public {
        address newUpdater = makeAddr("newUpdater");
        registry.grantRole(registry.UPDATER_ROLE(), newUpdater);
        assertTrue(registry.hasRole(registry.UPDATER_ROLE(), newUpdater));
    }

    function testAdminCanRevokeUpdaterRole() public {
        registry.revokeRole(registry.UPDATER_ROLE(), updater);
        assertFalse(registry.hasRole(registry.UPDATER_ROLE(), updater));
    }
}
