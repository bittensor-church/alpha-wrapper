// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test, Vm } from "forge-std/Test.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AttestationHelper } from "./helpers/AttestationHelper.sol";

contract ValidatorRegistryTest is AttestationHelper {
    event SignersUpdated(address[] newSigners, uint8 newThreshold);
    event MaxValidatorsUpdated(uint8 oldMaxValidators, uint8 newMaxValidators);
    event ValidatorsUpdated(uint256 indexed netuid, uint256 nonce, bytes32[] hotkeys, uint256[] weights);

    uint256 private constant SN1 = 1;
    uint256 private constant SN2 = 2;

    uint8 private maxValidators;

    uint256 private constant PK1 = 0xA11CE;
    uint256 private constant PK2 = 0xB0B;
    uint256 private constant PK3 = 0xCAFE;
    uint256 private constant PK_UNKNOWN = 0xDEADBEEF;

    address private s1;
    address private s2;
    address private s3;

    address private admin = address(this);
    address private nobody = makeAddr("nobody");

    ValidatorRegistry private registry;

    function setUp() public {
        s1 = vm.addr(PK1);
        s2 = vm.addr(PK2);
        s3 = vm.addr(PK3);

        address[] memory init = new address[](3);
        init[0] = s1;
        init[1] = s2;
        init[2] = s3;

        registry = new ValidatorRegistry(admin, init, 2);
        maxValidators = registry.maxValidators();
    }

    function _att(uint256 netuid, uint256 len, uint256 nonce, uint256 deadline)
        private
        pure
        returns (ValidatorRegistry.WeightAttestation memory att)
    {
        att.netuid = netuid;
        att.nonce = nonce;
        att.deadline = deadline;
        att.hotkeys = _generateHotkeys(len);
        att.weights = len == 0 ? new uint256[](0) : _rampWeights(len);
    }

    function _assertStoredSetMatches(uint256 netuid, ValidatorRegistry.WeightAttestation memory att) private view {
        (bytes32[] memory hotkeys, uint16[] memory weights) = registry.getValidators(netuid);
        assertEq(hotkeys.length, att.hotkeys.length);
        assertEq(weights.length, att.weights.length);
        for (uint256 i; i < hotkeys.length; ++i) {
            assertEq(hotkeys[i], att.hotkeys[i]);
            assertEq(weights[i], att.weights[i]);
        }
    }

    /// @dev Sign with each privkey in the order given. Caller is responsible for ordering
    ///      `pks` so recovered addresses ascend; the contract's `_verifySignatures` enforces
    ///      that. PK address order is PK2 < PK3 < PK1 < PK_UNKNOWN — the `_pksN` helpers
    ///      below are written with this in mind.
    function _sign(ValidatorRegistry.WeightAttestation memory att, uint256[] memory pks)
        private
        view
        returns (bytes[] memory)
    {
        return _sign(_attestationDigest(registry, att), pks);
    }

    function _pks2(uint256 a, uint256 b) private pure returns (uint256[] memory pks) {
        pks = new uint256[](2);
        pks[0] = a;
        pks[1] = b;
    }

    function _pks3(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory pks) {
        pks = new uint256[](3);
        pks[0] = a;
        pks[1] = b;
        pks[2] = c;
    }

    function test_RevertWhen_AdminIsZeroAddress() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectRevert(ValidatorRegistry.ZeroAddress.selector);
        new ValidatorRegistry(address(0), init, 1);
    }

    function test_RevertWhen_InitialSignerIsZeroAddress() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = address(0);
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        new ValidatorRegistry(admin, init, 2);
    }

    function test_RevertWhen_InitialSignersContainDuplicate() public {
        address[] memory init = new address[](3);
        init[0] = s1;
        init[1] = s2;
        init[2] = s1;
        vm.expectRevert(ValidatorRegistry.DuplicateValue.selector);
        new ValidatorRegistry(admin, init, 2);
    }

    function test_RevertWhen_InitialThresholdIsZero() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdTooLow.selector);
        new ValidatorRegistry(admin, init, 0);
    }

    function test_RevertWhen_InitialThresholdIsOne() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdTooLow.selector);
        new ValidatorRegistry(admin, init, 1);
    }

    function test_RevertWhen_NoInitialSigners() public {
        address[] memory init = new address[](0);
        vm.expectRevert(ValidatorRegistry.InsufficientSigners.selector);
        new ValidatorRegistry(admin, init, 2);
    }

    function test_RevertWhen_OnlyOneInitialSigner() public {
        address[] memory init = new address[](1);
        init[0] = s1;
        vm.expectRevert(ValidatorRegistry.InsufficientSigners.selector);
        new ValidatorRegistry(admin, init, 2);
    }

    function test_RevertWhen_InitialThresholdExceedsSignerCount() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdExceedsSigners.selector);
        new ValidatorRegistry(admin, init, 3);
    }

    function test_RevertWhen_TooManyInitialSigners() public {
        address[] memory init = new address[](17);
        for (uint256 i; i < 17; ++i) {
            init[i] = vm.addr(uint256(keccak256(abi.encode("init-signer", i))));
        }
        vm.expectRevert(ValidatorRegistry.TooManySigners.selector);
        new ValidatorRegistry(admin, init, 2);
    }

    function test_Constructor_AdminGrantedDefaultAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_InitialSignersStored() public view {
        assertEq(registry.signers(0), s1);
        assertEq(registry.signers(1), s2);
        assertEq(registry.signers(2), s3);
        assertTrue(registry.isSigner(s1));
        assertTrue(registry.isSigner(s2));
        assertTrue(registry.isSigner(s3));
    }

    function test_Constructor_ThresholdStored() public view {
        assertEq(registry.threshold(), 2);
    }

    function test_Constructor_EmitsSignersUpdated() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectEmit(true, true, true, true);
        emit SignersUpdated(init, 2);
        new ValidatorRegistry(admin, init, 2);
    }

    function test_Constructor_Eip712DomainNameAndVersion() public view {
        (, string memory name, string memory version,,,,) = registry.eip712Domain();
        assertEq(name, "AlphaVault ValidatorRegistry");
        assertEq(version, "1");
    }

    function test_RevertWhen_SetSignersCallerNotAdmin() public {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        address[] memory ns = new address[](1);
        ns[0] = s1;
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, adminRole)
        );
        registry.setSigners(ns, 1);
    }

    function test_RevertWhen_SetSignersContainsZeroAddress() public {
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = address(0);
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.setSigners(ns, 2);
    }

    function test_RevertWhen_SetSignersContainsDuplicate() public {
        address[] memory ns = new address[](3);
        ns[0] = s1;
        ns[1] = s2;
        ns[2] = s1;
        vm.expectRevert(ValidatorRegistry.DuplicateValue.selector);
        registry.setSigners(ns, 2);
    }

    function test_RevertWhen_SetSignersThresholdTooLowZero() public {
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdTooLow.selector);
        registry.setSigners(ns, 0);
    }

    function test_RevertWhen_SetSignersThresholdTooLowOne() public {
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdTooLow.selector);
        registry.setSigners(ns, 1);
    }

    function test_RevertWhen_SetSignersInsufficientSignersEmpty() public {
        address[] memory ns = new address[](0);
        vm.expectRevert(ValidatorRegistry.InsufficientSigners.selector);
        registry.setSigners(ns, 2);
    }

    function test_RevertWhen_SetSignersInsufficientSignersOne() public {
        address[] memory ns = new address[](1);
        ns[0] = s1;
        vm.expectRevert(ValidatorRegistry.InsufficientSigners.selector);
        registry.setSigners(ns, 2);
    }

    function test_RevertWhen_SetSignersThresholdExceedsCount() public {
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdExceedsSigners.selector);
        registry.setSigners(ns, 3);
    }

    function test_RevertWhen_SetSignersTooMany() public {
        address[] memory ns = new address[](17);
        for (uint256 i; i < 17; ++i) {
            ns[i] = vm.addr(uint256(keccak256(abi.encode("set-signer", i))));
        }
        vm.expectRevert(ValidatorRegistry.TooManySigners.selector);
        registry.setSigners(ns, 2);
    }

    function test_SetSigners_AcceptsMaxSigners() public {
        address[] memory ns = new address[](16);
        for (uint256 i; i < 16; ++i) {
            ns[i] = vm.addr(uint256(keccak256(abi.encode("max-signer", i))));
        }
        registry.setSigners(ns, 2);
        assertEq(registry.signers(15), ns[15]);
    }

    function test_SetSigners_RemovedSignersUnmarked() public {
        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;
        registry.setSigners(ns, 2);

        assertFalse(registry.isSigner(s1));
        assertFalse(registry.isSigner(s2));
        assertFalse(registry.isSigner(s3));
        assertTrue(registry.isSigner(d));
        assertTrue(registry.isSigner(e));
    }

    function test_SetSigners_NewThresholdStored() public {
        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address f = vm.addr(0xF);
        address[] memory ns = new address[](3);
        ns[0] = d;
        ns[1] = e;
        ns[2] = f;
        registry.setSigners(ns, 3);
        assertEq(registry.threshold(), 3);
    }

    function test_SetSigners_EmitsSignersUpdated() public {
        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;

        vm.expectEmit(true, true, true, true);
        emit SignersUpdated(ns, 2);
        registry.setSigners(ns, 2);
    }

    function test_SetSigners_ReusedSignerStaysMarked() public {
        address d = vm.addr(0xD);
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = d;
        registry.setSigners(ns, 2);

        assertEq(registry.signers(0), s1);
        assertEq(registry.signers(1), d);
        assertTrue(registry.isSigner(s1));
        assertTrue(registry.isSigner(d));
        assertFalse(registry.isSigner(s2));
        assertFalse(registry.isSigner(s3));
    }

    function test_Constructor_MaxValidatorsDefaultsToTwenty() public view {
        assertEq(registry.maxValidators(), 20);
    }

    function test_SetMaxValidators_UpdatesCap() public {
        vm.expectEmit(true, true, true, true);
        emit MaxValidatorsUpdated(20, 30);
        registry.setMaxValidators(30);
        assertEq(registry.maxValidators(), 30);
    }

    function test_RevertWhen_SetMaxValidatorsCallerNotAdmin() public {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, adminRole)
        );
        registry.setMaxValidators(10);
    }

    function test_RevertWhen_SetMaxValidatorsZero() public {
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.setMaxValidators(0);
    }

    function test_SetMaxValidators_AcceptsLimit() public {
        registry.setMaxValidators(registry.MAX_VALIDATORS_LIMIT());
        assertEq(registry.maxValidators(), registry.MAX_VALIDATORS_LIMIT());
    }

    function test_RevertWhen_SetMaxValidatorsAboveLimit() public {
        uint8 aboveLimit = registry.MAX_VALIDATORS_LIMIT() + 1;
        vm.expectRevert(ValidatorRegistry.MaxValidatorsAboveLimit.selector);
        registry.setMaxValidators(aboveLimit);
    }

    function test_Update_AcceptsSetSizedToRaisedCap() public {
        registry.setMaxValidators(30);

        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 30, 1, block.timestamp + 60);
        registry.updateValidators(att, _sign(att, _pks2(PK2, PK1)));

        _assertStoredSetMatches(SN1, att);
    }

    function test_RevertWhen_UpdateExceedsLoweredCap() public {
        registry.setMaxValidators(2);

        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.InvalidValidatorCount.selector);
        registry.updateValidators(att, sigs);
    }

    function test_Update_KeepsStoredSetWhenCapLoweredBelowIt() public {
        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, 3, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK2, PK1)));

        registry.setMaxValidators(2);
        _assertStoredSetMatches(SN1, att1);

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, 2, 2, block.timestamp + 60);
        registry.updateValidators(att2, _sign(att2, _pks2(PK2, PK1)));
        _assertStoredSetMatches(SN1, att2);
    }

    function testFuzz_SetMaxValidators_BoundsAttestationCount(uint8 capSeed) public {
        // uint8 arithmetic keeps the cap cast-free for the uint8 setter.
        uint8 cap = capSeed % registry.MAX_VALIDATORS_LIMIT() + 1;
        registry.setMaxValidators(cap);

        ValidatorRegistry.WeightAttestation memory oversized = _att(SN1, cap + 1, 1, block.timestamp + 60);
        bytes[] memory oversizedSigs = _sign(oversized, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.InvalidValidatorCount.selector);
        registry.updateValidators(oversized, oversizedSigs);

        ValidatorRegistry.WeightAttestation memory exact = _att(SN1, cap, 1, block.timestamp + 60);
        registry.updateValidators(exact, _sign(exact, _pks2(PK2, PK1)));
        _assertStoredSetMatches(SN1, exact);
    }

    function test_Update_PersistsTwoValidators() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));

        vm.expectEmit(true, true, true, true);
        emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
        registry.updateValidators(att, sigs);

        assertEq(registry.nonces(SN1), 1);
        _assertStoredSetMatches(SN1, att);
    }

    function test_Update_PersistsMaxValidators() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, maxValidators, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));

        vm.expectEmit(true, true, true, true);
        emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
        registry.updateValidators(att, sigs);

        assertEq(registry.nonces(SN1), 1);
        _assertStoredSetMatches(SN1, att);
    }

    function test_Update_ShrinksSetToExactLength() public {
        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, maxValidators, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK2, PK1)));

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, 1, 2, block.timestamp + 60);
        registry.updateValidators(att2, _sign(att2, _pks2(PK2, PK1)));

        assertEq(registry.nonces(SN1), 2);
        _assertStoredSetMatches(SN1, att2);
    }

    function test_Update_OverwritesPreviousAttestationOnGrow() public {
        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, 1, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK2, PK1)));

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, maxValidators, 2, block.timestamp + 60);
        registry.updateValidators(att2, _sign(att2, _pks2(PK2, PK1)));

        assertEq(registry.nonces(SN1), 2);
        _assertStoredSetMatches(SN1, att2);
    }

    function test_Update_NetuidsHaveIndependentState() public {
        ValidatorRegistry.WeightAttestation memory a1 = _att(SN1, 2, 1, block.timestamp + 60);
        registry.updateValidators(a1, _sign(a1, _pks2(PK2, PK1)));

        ValidatorRegistry.WeightAttestation memory a2 = _att(SN2, 3, 1, block.timestamp + 60);
        registry.updateValidators(a2, _sign(a2, _pks2(PK2, PK1)));

        ValidatorRegistry.WeightAttestation memory a3 = _att(SN1, 1, 2, block.timestamp + 60);
        registry.updateValidators(a3, _sign(a3, _pks2(PK2, PK1)));

        assertEq(registry.nonces(SN1), 2);
        assertEq(registry.nonces(SN2), 1);

        _assertStoredSetMatches(SN1, a3);
        _assertStoredSetMatches(SN2, a2);
    }

    function testFuzz_Update_RoundTripsAnyCount(uint256 count) public {
        uint256 len = bound(count, 1, maxValidators);
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, len, 1, block.timestamp + 60);
        registry.updateValidators(att, _sign(att, _pks2(PK2, PK1)));

        assertEq(registry.nonces(SN1), 1);
        _assertStoredSetMatches(SN1, att);
    }

    function testFuzz_Update_SequentialCommitsLeaveExactFinalSet(uint256 firstCount, uint256 secondCount) public {
        uint256 firstLen = bound(firstCount, 1, maxValidators);
        uint256 secondLen = bound(secondCount, 1, maxValidators);

        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, firstLen, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK2, PK1)));

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, secondLen, 2, block.timestamp + 60);
        registry.updateValidators(att2, _sign(att2, _pks2(PK2, PK1)));

        assertEq(registry.nonces(SN1), 2);
        _assertStoredSetMatches(SN1, att2);
    }

    function test_RevertWhen_UpdateEmptyHotkeys() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 0, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.InvalidValidatorCount.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_UpdateTooManyHotkeys() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, uint256(maxValidators) + 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.InvalidValidatorCount.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_UpdateLengthMismatch() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        att.weights = new uint256[](2);
        att.weights[0] = 5_000;
        att.weights[1] = 5_000;
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.LengthMismatch.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_NetuidExceedsUint16Max() public {
        ValidatorRegistry.WeightAttestation memory att = _att(uint256(type(uint16).max) + 1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.NetuidOutOfRange.selector);
        registry.updateValidators(att, sigs);
    }

    function test_Update_AcceptsNetuidAtUint16Max() public {
        ValidatorRegistry.WeightAttestation memory att = _att(uint256(type(uint16).max), 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        registry.updateValidators(att, sigs);
        assertEq(registry.nonces(uint256(type(uint16).max)), 1);
    }

    function test_RevertWhen_HotkeyAtSlot0IsZero() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.hotkeys[0] = bytes32(0);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_HotkeyAtSlot1IsZero() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.hotkeys[1] = bytes32(0);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_WeightAtSlot0IsZero() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        att.weights[0] = 0;
        att.weights[1] = 5_000;
        att.weights[2] = 5_000;
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.ZeroWeight.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_WeightAtMiddleSlotIsZero() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        att.weights[0] = 3_000;
        att.weights[1] = 0;
        att.weights[2] = 7_000;
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.ZeroWeight.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_HotkeysContainDuplicate() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        att.hotkeys[2] = att.hotkeys[0];
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.DuplicateValue.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_WeightsSumBelowBpsBase() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.weights[0] = 6_000;
        att.weights[1] = 3_999; // sum 9_999
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.WeightsMustSum10000.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_WeightsSumAboveBpsBase() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.weights[0] = 6_000;
        att.weights[1] = 4_001; // sum 10_001
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.WeightsMustSum10000.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_NonceLessThanExpected() public {
        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, 1, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK2, PK1)));

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att2, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(att2, sigs);
    }

    function test_RevertWhen_NonceIsZero() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 0, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_NonceSkipsAhead() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 2, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_DeadlineInPast() public {
        uint256 deadline = block.timestamp + 60;
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, deadline);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.warp(deadline + 1);
        vm.expectRevert(ValidatorRegistry.ExpiredAttestation.selector);
        registry.updateValidators(att, sigs);
    }

    function test_Update_AcceptsDeadlineEqualToBlockTimestamp() public {
        uint256 deadline = block.timestamp + 60;
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, deadline);
        bytes[] memory sigs = _sign(att, _pks2(PK2, PK1));
        vm.warp(deadline); // boundary: contract uses `>` not `>=`
        registry.updateValidators(att, sigs);
        assertEq(registry.nonces(SN1), 1);
    }

    function test_RevertWhen_NoSignaturesProvided() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = new bytes[](0);
        vm.expectRevert(ValidatorRegistry.NotEnoughSignatures.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_FewerSignaturesThanThreshold() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        uint256[] memory pks = new uint256[](1);
        pks[0] = PK1;
        bytes[] memory sigs = _sign(att, pks);
        vm.expectRevert(ValidatorRegistry.NotEnoughSignatures.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_RecoveredSignerNotInSet() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK_UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(ValidatorRegistry.UnknownSigner.selector, vm.addr(PK_UNKNOWN)));
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_SignaturesNotSortedByRecoveredAddress() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        // Intentionally non-ascending: PK1's address > PK2's, so passing (PK1, PK2) breaks order.
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.SignersNotSorted.selector);
        registry.updateValidators(att, sigs);
    }

    function test_RevertWhen_SameSignerProvidesTwoSignatures() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes32 digest = _attestationDigest(registry, att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig;
        sigs[1] = sig;
        vm.expectRevert(ValidatorRegistry.SignersNotSorted.selector);
        registry.updateValidators(att, sigs);
    }

    function test_Update_AcceptsExtraValidSignatures() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks3(PK2, PK3, PK1));
        registry.updateValidators(att, sigs);
        assertEq(registry.nonces(SN1), 1);
    }

    function test_RevertWhen_ExtraSignatureIsFromUnknownSigner() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks3(PK2, PK1, PK_UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(ValidatorRegistry.UnknownSigner.selector, vm.addr(PK_UNKNOWN)));
        registry.updateValidators(att, sigs);
    }

    /// @dev Sign with the current set, rotate to a new set, then submit. The verify-time
    ///      `isSigner` check kills the stockpiled attestation regardless of its deadline.
    function test_RevertWhen_AttestationSignedByRotatedOutSigner() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory oldSigs = _sign(att, _pks2(PK2, PK1));

        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;
        registry.setSigners(ns, 2);

        // oldSigs sort ascending to [s2, s1], so the contract recovers s2 first; it is no longer a signer.
        vm.expectRevert(abi.encodeWithSelector(ValidatorRegistry.UnknownSigner.selector, s2));
        registry.updateValidators(att, oldSigs);

        // State is unchanged after the failed submission.
        assertEq(registry.nonces(SN1), 0);
    }

    function test_Update_FirstAttestationWithNonceWinsRace() public {
        ValidatorRegistry.WeightAttestation memory a1 = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs1 = _sign(a1, _pks2(PK2, PK1));

        // Construct an alternative attestation also at nonce 1 with different content
        ValidatorRegistry.WeightAttestation memory a2 = _att(SN1, 2, 1, block.timestamp + 60);
        bytes[] memory sigs2 = _sign(a2, _pks2(PK2, PK1));

        registry.updateValidators(a1, sigs1);
        assertEq(registry.nonces(SN1), 1);

        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(a2, sigs2);

        // State of SN1 must still be a1's content, not partially overwritten by a2.
        assertEq(registry.nonces(SN1), 1);
        _assertStoredSetMatches(SN1, a1);
    }

    function test_Batch_CommitsAllEntries() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 3, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 2, 1, block.timestamp + 60);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK2, PK1));
        sigs[1] = _sign(atts[1], _pks2(PK2, PK1));
        sigs[2] = _sign(atts[2], _pks2(PK2, PK1));

        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 1);
        assertEq(registry.nonces(SN2), 1);
        assertEq(registry.nonces(100), 1);

        _assertStoredSetMatches(SN1, atts[0]);
        _assertStoredSetMatches(SN2, atts[1]);
        _assertStoredSetMatches(100, atts[2]);
    }

    function test_Batch_EmitsValidatorsUpdatedPerEntry() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 3, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 2, 1, block.timestamp + 60);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK2, PK1));
        sigs[1] = _sign(atts[1], _pks2(PK2, PK1));
        sigs[2] = _sign(atts[2], _pks2(PK2, PK1));

        vm.recordLogs();
        registry.updateValidatorsBatch(atts, sigs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("ValidatorsUpdated(uint256,uint256,bytes32[],uint256[])");
        uint256 count = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) count++;
        }
        assertEq(count, 3);
    }

    function test_RevertWhen_BatchAttsAndSigsLengthMismatch() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](2);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 1, 1, block.timestamp + 60);
        bytes[][] memory sigs = new bytes[][](1);
        sigs[0] = _sign(atts[0], _pks2(PK2, PK1));

        vm.expectRevert(ValidatorRegistry.LengthMismatch.selector);
        registry.updateValidatorsBatch(atts, sigs);
    }

    function test_Batch_EntriesUseDifferentSignerPairs() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 1, 1, block.timestamp + 60);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK2, PK1));
        sigs[1] = _sign(atts[1], _pks2(PK2, PK3));
        sigs[2] = _sign(atts[2], _pks2(PK3, PK1));

        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 1);
        assertEq(registry.nonces(SN2), 1);
        assertEq(registry.nonces(100), 1);
    }

    function test_Batch_TwentyEntriesCommitSuccessfully() public {
        uint256 n = 20;
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](n);
        bytes[][] memory sigs = new bytes[][](n);
        for (uint256 i = 0; i < n; i++) {
            atts[i] = _att(1000 + i, 3, 1, block.timestamp + 600);
            sigs[i] = _sign(atts[i], _pks2(PK2, PK1));
        }

        registry.updateValidatorsBatch(atts, sigs);

        for (uint256 i = 0; i < n; i++) {
            assertEq(registry.nonces(1000 + i), 1);
        }
    }

    function test_Batch_EmptyArrayIsNoOp() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](0);
        bytes[][] memory sigs = new bytes[][](0);

        vm.recordLogs();
        registry.updateValidatorsBatch(atts, sigs);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(registry.nonces(SN1), 0);
        assertEq(registry.nonces(SN2), 0);
    }

    function test_Batch_SameNetuidConsecutiveNoncesAllCommit() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](2);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN1, 2, 2, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](2);
        sigs[0] = _sign(atts[0], _pks2(PK2, PK1));
        sigs[1] = _sign(atts[1], _pks2(PK2, PK1));

        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 2);
        _assertStoredSetMatches(SN1, atts[1]);
    }
}
