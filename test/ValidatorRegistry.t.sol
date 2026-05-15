// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test, Vm } from "forge-std/Test.sol";
import { ValidatorRegistry } from "src/ValidatorRegistry.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ValidatorRegistryTest is Test {
    event SignersUpdated(address[] newSigners, uint8 newThreshold);
    event ValidatorsUpdated(uint256 indexed netuid, uint256 nonce, bytes32[] hotkeys, uint256[] weights);

    uint256 internal constant SN1 = 1;
    uint256 internal constant SN2 = 2;

    bytes32 internal hk1 = keccak256("hotkey1");
    bytes32 internal hk2 = keccak256("hotkey2");
    bytes32 internal hk3 = keccak256("hotkey3");
    bytes32 internal hk4 = keccak256("hotkey4");

    uint256 internal constant PK1 = 0xA11CE;
    uint256 internal constant PK2 = 0xB0B;
    uint256 internal constant PK3 = 0xCAFE;
    uint256 internal constant PK_UNKNOWN = 0xDEADBEEF;

    address internal s1;
    address internal s2;
    address internal s3;

    address internal admin = address(this);
    address internal nobody = makeAddr("nobody");

    ValidatorRegistry internal registry;

    function setUp() public {
        s1 = vm.addr(PK1);
        s2 = vm.addr(PK2);
        s3 = vm.addr(PK3);

        address[] memory init = new address[](3);
        init[0] = s1;
        init[1] = s2;
        init[2] = s3;

        registry = new ValidatorRegistry(admin, init, 2);
    }

    function _att(uint256 netuid, uint256 len, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ValidatorRegistry.WeightAttestation memory att)
    {
        att.netuid = netuid;
        att.nonce = nonce;
        att.deadline = deadline;
        att.hotkeys = new bytes32[](len);
        att.weights = new uint256[](len);
        if (len == 1) {
            att.hotkeys[0] = hk1;
            att.weights[0] = 10_000;
        } else if (len == 2) {
            att.hotkeys[0] = hk1;
            att.hotkeys[1] = hk2;
            att.weights[0] = 6_000;
            att.weights[1] = 4_000;
        } else if (len == 3) {
            att.hotkeys[0] = hk1;
            att.hotkeys[1] = hk2;
            att.hotkeys[2] = hk3;
            att.weights[0] = 5_000;
            att.weights[1] = 3_000;
            att.weights[2] = 2_000;
        }
    }

    /// @dev Sign with each privkey, return sigs sorted by recovered address ascending.
    function _sign(ValidatorRegistry.WeightAttestation memory att, uint256[] memory pks)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = _digestIndependent(att);
        uint256 n = pks.length;
        sigs = new bytes[](n);
        address[] memory addrs = new address[](n);

        for (uint256 i = 0; i < n; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
            addrs[i] = vm.addr(pks[i]);
        }

        // Bubble sort sigs in parallel with addrs ascending
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (sigs[i], sigs[j]) = (sigs[j], sigs[i]);
                }
            }
        }
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("AlphaVault ValidatorRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(registry)
            )
        );
    }

    /// @dev Independent reconstruction of the EIP-712 digest. Used as cross-check
    ///      against the contract's hash builder — if a sig built from this digest
    ///      verifies on-chain, both implementations agree.
    function _digestIndependent(ValidatorRegistry.WeightAttestation memory att) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ATTESTATION_TYPEHASH(),
                att.netuid,
                keccak256(abi.encodePacked(att.hotkeys)),
                keccak256(abi.encodePacked(att.weights)),
                att.nonce,
                att.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _pks2(uint256 a, uint256 b) internal pure returns (uint256[] memory pks) {
        pks = new uint256[](2);
        pks[0] = a;
        pks[1] = b;
    }

    function _pks3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory pks) {
        pks = new uint256[](3);
        pks[0] = a;
        pks[1] = b;
        pks[2] = c;
    }

    function test_constructor_revertsZeroAdmin() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectRevert(ValidatorRegistry.ZeroAddress.selector);
        new ValidatorRegistry(address(0), init, 1);
    }

    function test_constructor_revertsZeroSignerInInitial() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = address(0);
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        new ValidatorRegistry(admin, init, 1);
    }

    function test_constructor_revertsDuplicateInInitial() public {
        address[] memory init = new address[](3);
        init[0] = s1;
        init[1] = s2;
        init[2] = s1;
        vm.expectRevert(ValidatorRegistry.DuplicateValue.selector);
        new ValidatorRegistry(admin, init, 2);
    }

    function test_constructor_revertsThresholdZero() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdZero.selector);
        new ValidatorRegistry(admin, init, 0);
    }

    function test_constructor_revertsThresholdExceedsSigners() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdExceedsSigners.selector);
        new ValidatorRegistry(admin, init, 3);
    }

    function test_constructor_setsAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_installsSignerSet() public view {
        assertEq(registry.signers(0), s1);
        assertEq(registry.signers(1), s2);
        assertEq(registry.signers(2), s3);
        assertTrue(registry.isSigner(s1));
        assertTrue(registry.isSigner(s2));
        assertTrue(registry.isSigner(s3));
    }

    function test_constructor_setsThreshold() public view {
        assertEq(registry.threshold(), 2);
    }

    function test_constructor_emitsSignersUpdated() public {
        address[] memory init = new address[](2);
        init[0] = s1;
        init[1] = s2;
        vm.expectEmit(true, true, true, true);
        emit SignersUpdated(init, 1);
        new ValidatorRegistry(admin, init, 1);
    }

    function test_constructor_eip712Domain() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = registry.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "AlphaVault ValidatorRegistry");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(registry));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_setSigners_revertsNonAdmin() public {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        address[] memory ns = new address[](1);
        ns[0] = s1;
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, adminRole)
        );
        registry.setSigners(ns, 1);
    }

    function test_setSigners_revertsZeroValue() public {
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = address(0);
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.setSigners(ns, 1);
    }

    function test_setSigners_revertsDuplicate() public {
        address[] memory ns = new address[](3);
        ns[0] = s1;
        ns[1] = s2;
        ns[2] = s1;
        vm.expectRevert(ValidatorRegistry.DuplicateValue.selector);
        registry.setSigners(ns, 2);
    }

    function test_setSigners_revertsThresholdZero() public {
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdZero.selector);
        registry.setSigners(ns, 0);
    }

    function test_setSigners_revertsThresholdExceedsNew() public {
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = s2;
        vm.expectRevert(ValidatorRegistry.ThresholdExceedsSigners.selector);
        registry.setSigners(ns, 3);
    }

    function test_setSigners_clearsOldFlags() public {
        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;
        registry.setSigners(ns, 1);

        assertFalse(registry.isSigner(s1));
        assertFalse(registry.isSigner(s2));
        assertFalse(registry.isSigner(s3));
        assertTrue(registry.isSigner(d));
        assertTrue(registry.isSigner(e));
    }

    function test_setSigners_replacesArray() public {
        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;
        registry.setSigners(ns, 1);

        assertEq(registry.signers(0), d);
        assertEq(registry.signers(1), e);
        vm.expectRevert(); // out-of-bounds panic
        registry.signers(2);
    }

    function test_setSigners_updatesThreshold() public {
        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;
        registry.setSigners(ns, 2);
        assertEq(registry.threshold(), 2);
    }

    function test_setSigners_emitsSignersUpdated() public {
        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;

        vm.expectEmit(true, true, true, true);
        emit SignersUpdated(ns, 1);
        registry.setSigners(ns, 1);
    }

    function test_setSigners_atomicOnRevert() public {
        address d = vm.addr(0xD);
        address[] memory bad = new address[](2);
        bad[0] = d;
        bad[1] = address(0); // triggers revert mid-loop

        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.setSigners(bad, 1);

        // Old state intact
        assertEq(registry.signers(0), s1);
        assertEq(registry.signers(1), s2);
        assertEq(registry.signers(2), s3);
        assertTrue(registry.isSigner(s1));
        assertTrue(registry.isSigner(s2));
        assertTrue(registry.isSigner(s3));
        assertFalse(registry.isSigner(d));
        assertEq(registry.threshold(), 2);
    }

    function test_setSigners_sameSignerKeptIfReused() public {
        address d = vm.addr(0xD);
        address[] memory ns = new address[](2);
        ns[0] = s1;
        ns[1] = d;
        registry.setSigners(ns, 1);

        assertEq(registry.signers(0), s1);
        assertEq(registry.signers(1), d);
        assertTrue(registry.isSigner(s1));
        assertTrue(registry.isSigner(d));
        assertFalse(registry.isSigner(s2));
        assertFalse(registry.isSigner(s3));
    }

    function test_update_writesAllSlots_len3() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));

        vm.expectEmit(true, true, true, true);
        emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
        registry.updateValidators(att, sigs);

        assertEq(registry.nonces(SN1), 1);
        (bytes32[3] memory hks, uint16[3] memory wts) = registry.getValidators(SN1);
        assertEq(hks[0], hk1);
        assertEq(hks[1], hk2);
        assertEq(hks[2], hk3);
        assertEq(wts[0], 5_000);
        assertEq(wts[1], 3_000);
        assertEq(wts[2], 2_000);
    }

    function test_update_writesAllSlots_len2() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));

        vm.expectEmit(true, true, true, true);
        emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
        registry.updateValidators(att, sigs);

        assertEq(registry.nonces(SN1), 1);
        (bytes32[3] memory hks, uint16[3] memory wts) = registry.getValidators(SN1);
        assertEq(hks[0], hk1);
        assertEq(hks[1], hk2);
        assertEq(hks[2], bytes32(0));
        assertEq(wts[0], 6_000);
        assertEq(wts[1], 4_000);
        assertEq(wts[2], 0);
    }

    function test_update_writesAllSlots_len1() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));

        vm.expectEmit(true, true, true, true);
        emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
        registry.updateValidators(att, sigs);

        assertEq(registry.nonces(SN1), 1);
        (bytes32[3] memory hks, uint16[3] memory wts) = registry.getValidators(SN1);
        assertEq(hks[0], hk1);
        assertEq(hks[1], bytes32(0));
        assertEq(hks[2], bytes32(0));
        assertEq(wts[0], 10_000);
        assertEq(wts[1], 0);
        assertEq(wts[2], 0);
    }

    function test_update_zeroesTrailingOnShrink() public {
        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, 3, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK1, PK2)));

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, 1, 2, block.timestamp + 60);
        registry.updateValidators(att2, _sign(att2, _pks2(PK1, PK2)));

        assertEq(registry.nonces(SN1), 2);
        (bytes32[3] memory hks, uint16[3] memory wts) = registry.getValidators(SN1);
        assertEq(hks[0], hk1);
        assertEq(hks[1], bytes32(0));
        assertEq(hks[2], bytes32(0));
        assertEq(wts[0], 10_000);
        assertEq(wts[1], 0);
        assertEq(wts[2], 0);
    }

    function test_update_overwritesOnGrow() public {
        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, 1, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK1, PK2)));

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, 3, 2, block.timestamp + 60);
        registry.updateValidators(att2, _sign(att2, _pks2(PK1, PK2)));

        assertEq(registry.nonces(SN1), 2);
        (bytes32[3] memory hks, uint16[3] memory wts) = registry.getValidators(SN1);
        assertEq(hks[0], hk1);
        assertEq(hks[1], hk2);
        assertEq(hks[2], hk3);
        assertEq(wts[0], 5_000);
        assertEq(wts[1], 3_000);
        assertEq(wts[2], 2_000);
    }

    function test_update_threeSubnetsIndependent() public {
        ValidatorRegistry.WeightAttestation memory a1 = _att(SN1, 2, 1, block.timestamp + 60);
        registry.updateValidators(a1, _sign(a1, _pks2(PK1, PK2)));

        ValidatorRegistry.WeightAttestation memory a2 = _att(SN2, 3, 1, block.timestamp + 60);
        registry.updateValidators(a2, _sign(a2, _pks2(PK1, PK2)));

        ValidatorRegistry.WeightAttestation memory a3 = _att(SN1, 1, 2, block.timestamp + 60);
        registry.updateValidators(a3, _sign(a3, _pks2(PK1, PK2)));

        assertEq(registry.nonces(SN1), 2);
        assertEq(registry.nonces(SN2), 1);

        // SN1 final state: a3 (len=1, hk1, 10_000)
        (bytes32[3] memory hks1, uint16[3] memory wts1) = registry.getValidators(SN1);
        assertEq(hks1[0], hk1);
        assertEq(hks1[1], bytes32(0));
        assertEq(hks1[2], bytes32(0));
        assertEq(wts1[0], 10_000);
        assertEq(wts1[1], 0);
        assertEq(wts1[2], 0);

        // SN2 final state: a2 (len=3, hk1/hk2/hk3, 5000/3000/2000)
        (bytes32[3] memory hks2, uint16[3] memory wts2) = registry.getValidators(SN2);
        assertEq(hks2[0], hk1);
        assertEq(hks2[1], hk2);
        assertEq(hks2[2], hk3);
        assertEq(wts2[0], 5_000);
        assertEq(wts2[1], 3_000);
        assertEq(wts2[2], 2_000);
    }

    function test_update_revertsEmptyHotkeys() public {
        ValidatorRegistry.WeightAttestation memory att;
        att.netuid = SN1;
        att.nonce = 1;
        att.deadline = block.timestamp + 60;
        att.hotkeys = new bytes32[](0);
        att.weights = new uint256[](0);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.InvalidValidatorCount.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsTooManyHotkeys() public {
        ValidatorRegistry.WeightAttestation memory att;
        att.netuid = SN1;
        att.nonce = 1;
        att.deadline = block.timestamp + 60;
        att.hotkeys = new bytes32[](4);
        att.weights = new uint256[](4);
        att.hotkeys[0] = hk1;
        att.hotkeys[1] = hk2;
        att.hotkeys[2] = hk3;
        att.hotkeys[3] = hk4;
        att.weights[0] = 2_500;
        att.weights[1] = 2_500;
        att.weights[2] = 2_500;
        att.weights[3] = 2_500;
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.InvalidValidatorCount.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsLengthMismatch() public {
        ValidatorRegistry.WeightAttestation memory att;
        att.netuid = SN1;
        att.nonce = 1;
        att.deadline = block.timestamp + 60;
        att.hotkeys = new bytes32[](3);
        att.weights = new uint256[](2);
        att.hotkeys[0] = hk1;
        att.hotkeys[1] = hk2;
        att.hotkeys[2] = hk3;
        att.weights[0] = 5_000;
        att.weights[1] = 5_000;
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.LengthMismatch.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsNetuidTooLarge() public {
        ValidatorRegistry.WeightAttestation memory att = _att(uint256(type(uint16).max) + 1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.NetuidOutOfRange.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_acceptsNetuidExactlyMax() public {
        ValidatorRegistry.WeightAttestation memory att = _att(uint256(type(uint16).max), 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        registry.updateValidators(att, sigs);
        assertEq(registry.nonces(uint256(type(uint16).max)), 1);
    }

    function test_update_revertsZeroHotkey_slot0() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.hotkeys[0] = bytes32(0);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsZeroHotkey_slot1() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.hotkeys[1] = bytes32(0);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.ZeroValue.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsZeroWeight_first() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        att.weights[0] = 0;
        att.weights[1] = 5_000;
        att.weights[2] = 5_000;
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.ZeroWeight.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsZeroWeight_middle() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        att.weights[0] = 3_000;
        att.weights[1] = 0;
        att.weights[2] = 7_000;
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.ZeroWeight.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsDuplicateHotkey() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 3, 1, block.timestamp + 60);
        att.hotkeys[2] = hk1;
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.DuplicateValue.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsWeightsSumLow() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.weights[0] = 6_000;
        att.weights[1] = 3_999; // sum 9_999
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.WeightsMustSum10000.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsWeightsSumHigh() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        att.weights[0] = 6_000;
        att.weights[1] = 4_001; // sum 10_001
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.WeightsMustSum10000.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsNonceStale() public {
        ValidatorRegistry.WeightAttestation memory att1 = _att(SN1, 1, 1, block.timestamp + 60);
        registry.updateValidators(att1, _sign(att1, _pks2(PK1, PK2)));

        ValidatorRegistry.WeightAttestation memory att2 = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att2, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(att2, sigs);
    }

    function test_update_revertsNonceZero() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 0, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsNonceSkipAhead() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 2, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsDeadlineExpired() public {
        uint256 deadline = block.timestamp + 60;
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, deadline);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.warp(deadline + 1);
        vm.expectRevert(ValidatorRegistry.ExpiredAttestation.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_acceptsDeadlineExactlyNow() public {
        uint256 deadline = block.timestamp + 60;
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, deadline);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        vm.warp(deadline); // boundary: contract uses `>` not `>=`
        registry.updateValidators(att, sigs);
        assertEq(registry.nonces(SN1), 1);
    }

    function test_update_revertsZeroSigs() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = new bytes[](0);
        vm.expectRevert(ValidatorRegistry.NotEnoughSignatures.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsBelowThreshold() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        uint256[] memory pks = new uint256[](1);
        pks[0] = PK1;
        bytes[] memory sigs = _sign(att, pks);
        vm.expectRevert(ValidatorRegistry.NotEnoughSignatures.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsUnknownSigner() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK_UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(ValidatorRegistry.UnknownSigner.selector, vm.addr(PK_UNKNOWN)));
        registry.updateValidators(att, sigs);
    }

    function test_update_revertsSigsNotSorted() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sortedSigs = _sign(att, _pks2(PK1, PK2));
        // Reverse to break ascending order
        bytes[] memory unsorted = new bytes[](2);
        unsorted[0] = sortedSigs[1];
        unsorted[1] = sortedSigs[0];
        vm.expectRevert(ValidatorRegistry.SignersNotSorted.selector);
        registry.updateValidators(att, unsorted);
    }

    function test_update_revertsSameSignerTwice() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes32 digest = _digestIndependent(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig;
        sigs[1] = sig;
        vm.expectRevert(ValidatorRegistry.SignersNotSorted.selector);
        registry.updateValidators(att, sigs);
    }

    function test_update_acceptsAboveThreshold() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks3(PK1, PK2, PK3));
        registry.updateValidators(att, sigs);
        assertEq(registry.nonces(SN1), 1);
    }

    function test_update_revertsAboveThreshold_oneInvalid() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks3(PK1, PK2, PK_UNKNOWN));
        vm.expectRevert(abi.encodeWithSelector(ValidatorRegistry.UnknownSigner.selector, vm.addr(PK_UNKNOWN)));
        registry.updateValidators(att, sigs);
    }

    /// @dev Sign with the current set, rotate to a new set, then submit. The verify-time
    ///      `isSigner` check kills the stockpiled attestation regardless of its deadline.
    function test_update_revertsAfterSignerRotation() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory oldSigs = _sign(att, _pks2(PK1, PK2));

        address d = vm.addr(0xD);
        address e = vm.addr(0xE);
        address[] memory ns = new address[](2);
        ns[0] = d;
        ns[1] = e;
        registry.setSigners(ns, 2);

        // The first recovered address among the ascending-sorted oldSigs is whichever of
        // s1/s2 sorts lower; either way the contract's first iteration hits a non-signer.
        // Selector-only expectRevert keeps the test independent of that ordering.
        vm.expectRevert();
        registry.updateValidators(att, oldSigs);

        // State is unchanged after the failed submission.
        assertEq(registry.nonces(SN1), 0);
    }

    /// @dev If our independently reconstructed digest is byte-identical to the
    ///      contract's `_hashTypedDataV4`, signing the independent digest will
    ///      pass the on-chain `isSigner[recovered]` check without firing
    ///      `UnknownSigner`. Any drift causes recovery to a different address.
    function test_digest_independentReconstructionMatchesContract() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 2, 1, block.timestamp + 60);
        bytes[] memory sigs = _sign(att, _pks2(PK1, PK2));
        registry.updateValidators(att, sigs);
        assertEq(registry.nonces(SN1), 1);
    }

    function test_digest_changesOnEachField() public view {
        ValidatorRegistry.WeightAttestation memory base = _att(SN1, 2, 1, 1000);
        bytes32 baseDigest = _digestIndependent(base);

        ValidatorRegistry.WeightAttestation memory mNetuid = _att(SN2, 2, 1, 1000);
        assertTrue(_digestIndependent(mNetuid) != baseDigest);

        ValidatorRegistry.WeightAttestation memory mHotkeys = _att(SN1, 2, 1, 1000);
        mHotkeys.hotkeys[1] = hk3;
        assertTrue(_digestIndependent(mHotkeys) != baseDigest);

        ValidatorRegistry.WeightAttestation memory mWeights = _att(SN1, 2, 1, 1000);
        mWeights.weights[0] = 7_000;
        mWeights.weights[1] = 3_000;
        assertTrue(_digestIndependent(mWeights) != baseDigest);

        ValidatorRegistry.WeightAttestation memory mNonce = _att(SN1, 2, 2, 1000);
        assertTrue(_digestIndependent(mNonce) != baseDigest);

        ValidatorRegistry.WeightAttestation memory mDeadline = _att(SN1, 2, 1, 1001);
        assertTrue(_digestIndependent(mDeadline) != baseDigest);
    }

    function test_digest_chainIdInDomain() public {
        ValidatorRegistry.WeightAttestation memory att = _att(SN1, 1, 1, block.timestamp + 60);
        bytes32 d1 = _digestIndependent(att);
        vm.chainId(block.chainid + 1);
        bytes32 d2 = _digestIndependent(att);
        assertTrue(d1 != d2);
    }

    function test_getValidators_unconfiguredReturnsZeros() public view {
        (bytes32[3] memory hks, uint16[3] memory wts) = registry.getValidators(99);
        assertEq(hks[0], bytes32(0));
        assertEq(hks[1], bytes32(0));
        assertEq(hks[2], bytes32(0));
        assertEq(wts[0], 0);
        assertEq(wts[1], 0);
        assertEq(wts[2], 0);
    }

    function test_nonces_unconfiguredReturnsZero() public view {
        assertEq(registry.nonces(99), 0);
    }

    function test_isSigner_unknownReturnsFalse() public view {
        assertFalse(registry.isSigner(address(0xDEAD)));
    }

    function test_signers_outOfBoundsReverts() public {
        vm.expectRevert();
        registry.signers(3);
    }

    function test_update_concurrentNoncesFirstWins() public {
        ValidatorRegistry.WeightAttestation memory a1 = _att(SN1, 1, 1, block.timestamp + 60);
        bytes[] memory sigs1 = _sign(a1, _pks2(PK1, PK2));

        // Construct an alternative attestation also at nonce 1 with different content
        ValidatorRegistry.WeightAttestation memory a2 = _att(SN1, 2, 1, block.timestamp + 60);
        bytes[] memory sigs2 = _sign(a2, _pks2(PK1, PK2));

        registry.updateValidators(a1, sigs1);
        assertEq(registry.nonces(SN1), 1);

        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidators(a2, sigs2);

        // State of SN1 must still be a1's content (len=1, hk1, 10_000), not partially overwritten by a2.
        assertEq(registry.nonces(SN1), 1);
        (bytes32[3] memory hks, uint16[3] memory wts) = registry.getValidators(SN1);
        assertEq(hks[0], hk1);
        assertEq(hks[1], bytes32(0));
        assertEq(hks[2], bytes32(0));
        assertEq(wts[0], 10_000);
        assertEq(wts[1], 0);
        assertEq(wts[2], 0);
    }

    function test_batch_commitsAllAttestations() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 3, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 2, 1, block.timestamp + 60);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], _pks2(PK1, PK2));
        sigs[2] = _sign(atts[2], _pks2(PK1, PK2));

        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 1);
        assertEq(registry.nonces(SN2), 1);
        assertEq(registry.nonces(100), 1);

        (bytes32[3] memory hksA,) = registry.getValidators(SN1);
        (bytes32[3] memory hksB,) = registry.getValidators(SN2);
        (bytes32[3] memory hksC, uint16[3] memory wtsC) = registry.getValidators(100);
        assertEq(hksA[2], hk3);
        assertEq(hksB[1], hk2);
        assertEq(hksC[0], hk1);
        assertEq(wtsC[0], 10_000);
    }

    function test_batch_emitsValidatorsUpdatedPerEntry() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 3, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 2, 1, block.timestamp + 60);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], _pks2(PK1, PK2));
        sigs[2] = _sign(atts[2], _pks2(PK1, PK2));

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

    function test_batch_revertsLengthMismatch() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](2);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 1, 1, block.timestamp + 60);
        bytes[][] memory sigs = new bytes[][](1);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));

        vm.expectRevert(ValidatorRegistry.LengthMismatch.selector);
        registry.updateValidatorsBatch(atts, sigs);
    }

    function test_batch_atomicityOnBadSig() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 1, 1, block.timestamp + 60);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        uint256[] memory bad = new uint256[](2);
        bad[0] = PK1;
        bad[1] = PK_UNKNOWN;

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], bad);
        sigs[2] = _sign(atts[2], _pks2(PK1, PK2));

        vm.expectRevert(abi.encodeWithSelector(ValidatorRegistry.UnknownSigner.selector, vm.addr(PK_UNKNOWN)));
        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 0);
        assertEq(registry.nonces(SN2), 0);
        assertEq(registry.nonces(100), 0);
    }

    function test_batch_atomicityOnExpiredDeadline() public {
        vm.warp(1000);

        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 1, 1, block.timestamp - 1);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], _pks2(PK1, PK2));
        sigs[2] = _sign(atts[2], _pks2(PK1, PK2));

        vm.expectRevert(ValidatorRegistry.ExpiredAttestation.selector);
        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 0);
        assertEq(registry.nonces(SN2), 0);
        assertEq(registry.nonces(100), 0);
    }

    function test_batch_atomicityOnPayloadError() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 2, 1, block.timestamp + 60);
        atts[1].weights[1] = 0;
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], _pks2(PK1, PK2));
        sigs[2] = _sign(atts[2], _pks2(PK1, PK2));

        vm.expectRevert(ValidatorRegistry.ZeroWeight.selector);
        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 0);
        assertEq(registry.nonces(SN2), 0);
        assertEq(registry.nonces(100), 0);
    }

    function test_batch_heterogeneousSigners() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](3);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN2, 1, 1, block.timestamp + 60);
        atts[2] = _att(100, 1, 1, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](3);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], _pks2(PK2, PK3));
        sigs[2] = _sign(atts[2], _pks2(PK1, PK3));

        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 1);
        assertEq(registry.nonces(SN2), 1);
        assertEq(registry.nonces(100), 1);
    }

    function test_batch_largeN_commits() public {
        uint256 n = 20;
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](n);
        bytes[][] memory sigs = new bytes[][](n);
        for (uint256 i = 0; i < n; i++) {
            atts[i] = _att(1000 + i, 3, 1, block.timestamp + 600);
            sigs[i] = _sign(atts[i], _pks2(PK1, PK2));
        }

        registry.updateValidatorsBatch(atts, sigs);

        for (uint256 i = 0; i < n; i++) {
            assertEq(registry.nonces(1000 + i), 1);
        }
    }

    function test_batch_atomicityOnStaleNonce() public {
        ValidatorRegistry.WeightAttestation memory pre = _att(SN1, 1, 1, block.timestamp + 60);
        registry.updateValidators(pre, _sign(pre, _pks2(PK1, PK2)));
        assertEq(registry.nonces(SN1), 1);

        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](2);
        atts[0] = _att(SN2, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN1, 1, 1, block.timestamp + 60); // stale: nonces[SN1] already == 1

        bytes[][] memory sigs = new bytes[][](2);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], _pks2(PK1, PK2));

        vm.expectRevert(ValidatorRegistry.StaleNonce.selector);
        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN2), 0);
        assertEq(registry.nonces(SN1), 1);
    }

    function test_batch_emptyIsNoOp() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](0);
        bytes[][] memory sigs = new bytes[][](0);

        vm.recordLogs();
        registry.updateValidatorsBatch(atts, sigs);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(registry.nonces(SN1), 0);
        assertEq(registry.nonces(SN2), 0);
    }

    function test_batch_sameNetuidConsecutiveNonces() public {
        ValidatorRegistry.WeightAttestation[] memory atts = new ValidatorRegistry.WeightAttestation[](2);
        atts[0] = _att(SN1, 1, 1, block.timestamp + 60);
        atts[1] = _att(SN1, 2, 2, block.timestamp + 60);

        bytes[][] memory sigs = new bytes[][](2);
        sigs[0] = _sign(atts[0], _pks2(PK1, PK2));
        sigs[1] = _sign(atts[1], _pks2(PK1, PK2));

        registry.updateValidatorsBatch(atts, sigs);

        assertEq(registry.nonces(SN1), 2);
        (bytes32[3] memory hks,) = registry.getValidators(SN1);
        assertEq(hks[1], hk2);
    }
}
