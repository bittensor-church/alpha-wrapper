# Validator Weight Attestation — Design

Replace the trusted `UPDATER_ROLE` push in `ValidatorRegistry` with a threshold-of-N off-chain attestation flow modelled on TAO20's `SignedAttestationOracle`. Anyone can submit a properly signed per-subnet weight update; no single party can change registered validator weights unilaterally.

## Goals

- Eliminate the single-trusted-bot model in `ValidatorRegistry` (`UPDATER_ROLE`).
- Allow any caller to submit a per-subnet `(hotkeys, weights)` update so long as it carries threshold-of-N signatures from a registered signer set.
- Keep `IValidatorRegistry`'s read shape compatible with `AlphaVault`'s existing call sites with minimal AlphaVault edits.
- Match the operational pattern already proven in TAO20 so a familiar attester service can be deployed alongside.

## Non-Goals

- Choosing the off-chain selection algorithm (top-N validators by APY, vtrust, decentralization, etc.) — operator policy, lives in a separate attester spec.
- On-chain enforcement of attester selection logic.
- Liveness guarantees if attesters go silent (weights stay frozen at last successful update; AlphaVault keeps using them).
- Migration of an already-deployed `AlphaVault` (the contract has `setValidatorRegistry(address) onlyOwner` to swap pointer; whether to redeploy or swap is a deployment decision).

## High-Level Architecture

Single-contract rewrite: `src/ValidatorRegistry.sol` is replaced in place. The new contract combines the oracle (signature verification) and the storage (per-subnet weights) in one unit because there is exactly one consumer (`AlphaVault`).

- Permissionless mutator: `updateValidators(WeightAttestation att, bytes[] sigs)`.
- Read interface preserved (consumed by `AlphaVault`): `getValidators(uint256 netuid)`.
- Admin (`DEFAULT_ADMIN_ROLE`) only manages the signer set + threshold via `setSigners(address[] newSigners, uint8 newThreshold)` — atomic rotation, no individual add/remove.
- Per-subnet monotonic nonce (`nonces[netuid]`) prevents replay and enforces ordering.
- EIP-712 domain pins chainId + verifying contract to prevent cross-chain / cross-contract replay.

```
┌────────────┐  GET /attestation/:netuid  ┌────────────────┐
│ Attester 1 │ ─────────────────────────► │                │
│ (priv A)   │                            │                │
├────────────┤  GET /attestation/:netuid  │ Relayer / dApp │
│ Attester 2 │ ─────────────────────────► │  fetch ≥ thr   │
│ (priv B)   │                            │  sort sigs by  │
├────────────┤  GET /attestation/:netuid  │  recovered ASC │
│ Attester 3 │ ─────────────────────────► │                │
│ (priv C)   │                            └────────┬───────┘
└────────────┘                                     │
                                                   ▼
                                ┌──────────────────────────────┐
                                │  ValidatorRegistry           │
                                │  updateValidators(att, sigs) │
                                │   • payload validation       │
                                │   • nonce strictly +1        │
                                │   • deadline > now           │
                                │   • ≥ threshold valid sigs   │
                                │   • sigs sorted ascending    │
                                │   • commit ValidatorSet      │
                                └──────────────┬───────────────┘
                                               │ getValidators(netuid)
                                               ▼
                                       ┌────────────────┐
                                       │   AlphaVault   │
                                       └────────────────┘
```

## Contract Design

### Contract shell

```solidity
contract ValidatorRegistry is IValidatorRegistry, EIP712, AccessControl {
    // ... constants, types, storage, functions follow below
}
```

Imports: `OpenZeppelin/access/AccessControl.sol`, `OpenZeppelin/utils/cryptography/EIP712.sol`, `OpenZeppelin/utils/cryptography/ECDSA.sol`, local `IValidatorRegistry`.

### Constants and types

```solidity
bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
    "WeightAttestation(uint256 netuid,bytes32[] hotkeys,uint256[] weights,uint256 nonce,uint256 deadline)"
);

uint16 public constant BPS_BASE       = 10_000;
uint8  public constant MAX_VALIDATORS = 3;

struct WeightAttestation {
    uint256   netuid;     // validated <= type(uint16).max on input
    bytes32[] hotkeys;    // length 1..3, no zeros, no duplicates
    uint256[] weights;    // same length, each > 0, sum == BPS_BASE
    uint256   nonce;      // == nonces[netuid] + 1
    uint256   deadline;   // > block.timestamp
}

struct ValidatorSet {
    bytes32[3] hotkeys;   // packed-from-slot-0; trailing slots == bytes32(0)
    uint16[3]  weights;   // packed; trailing slots == 0; one storage slot total
}
```

All EIP-712 fields are `uint256` or `bytes32[]` to keep struct hashing trivial — `keccak256(abi.encodePacked(att.weights))` and `keccak256(abi.encodePacked(att.hotkeys))` are bit-correct because every element is already 32 bytes. Mixing in `uint16[]` or `uint64` would require manual 32-byte padding for the EIP-712 array hash; using `uint256` avoids that footgun. Range checks on the contract side (`netuid <= type(uint16).max`, `weight <= BPS_BASE` derived from the sum invariant) keep storage cast safety.

### Storage

```solidity
// Signer governance (admin-managed)
mapping(address => bool) public isSigner;
address[]                public signers;
uint8                    public threshold;

// Per-subnet state (attestation-managed)
mapping(uint256 => ValidatorSet) internal _validators;
mapping(uint256 => uint256)      public   nonces;
```

`signers` is a manual `address[] public` — gives on-chain enumeration via the auto-getter `signers(uint256)` and `signers.length` replaces a separate signer-count field. Removal is O(n) inside `setSigners` (full clear-and-replace flow), which is fine for the typical 3–7 signer set.

### External API

```solidity
// Permissionless
function updateValidators(WeightAttestation calldata att, bytes[] calldata sigs) external;

// Read (consumed by AlphaVault)
function getValidators(uint256 netuid) external view returns (bytes32[3] memory hotkeys, uint16[3] memory weights);

// Admin (DEFAULT_ADMIN_ROLE)
function setSigners(address[] calldata newSigners, uint8 newThreshold) external;
```

`getValidators` returns a 2-tuple — no `count`. AlphaVault derives count locally via the packing invariant (see "AlphaVault Changes").

OpenZeppelin EIP712 v5 provides `eip712Domain()` (ERC-5267) for free — no custom `domainSeparator()` view. The contract intentionally does not expose a `computeDigest()` helper; off-chain attesters must reconstruct the EIP-712 digest independently with viem / `eth_account`, which doubles as a cross-check on the contract's hash construction.

### Constructor

```solidity
constructor(address admin, address[] memory initialSigners, uint8 initialThreshold)
    EIP712("AlphaVault ValidatorRegistry", "1")
{
    if (admin == address(0)) revert ZeroAddress();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _setSigners(initialSigners, initialThreshold);
}
```

`_setSigners` is the internal helper that both the constructor and the external `setSigners` call. The external version has the `onlyRole(DEFAULT_ADMIN_ROLE)` modifier; the internal helper does not, so the constructor can seed the initial set without msg.sender being admin.

### `setSigners` (admin atomic rotation)

```solidity
function setSigners(address[] calldata newSigners, uint8 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setSigners(newSigners, newThreshold);
}

function _setSigners(address[] memory newSigners, uint8 newThreshold) internal {
    uint256 oldLen = signers.length;
    for (uint256 i = 0; i < oldLen; i++) isSigner[signers[i]] = false;
    delete signers;
    for (uint256 i = 0; i < newSigners.length; i++) {
        address s = newSigners[i];
        if (s == address(0)) revert ZeroValue();
        if (isSigner[s])     revert DuplicateValue();
        isSigner[s] = true;
        signers.push(s);
    }
    if (newThreshold == 0)                  revert ThresholdZero();
    if (newThreshold > newSigners.length)   revert ThresholdExceedsSigners();
    threshold = newThreshold;
    emit SignersUpdated(newSigners, newThreshold);
}
```

Atomicity: the EVM reverts the entire tx on any failure, so partial mid-loop mutation cannot leak. There is no transient window where `threshold > signers.length`.

### `updateValidators` (permissionless)

```solidity
function updateValidators(WeightAttestation calldata att, bytes[] calldata sigs) external {
    if (att.netuid > type(uint16).max)            revert NetuidOutOfRange();
    uint256 len = att.hotkeys.length;
    if (len == 0 || len > MAX_VALIDATORS)         revert InvalidValidatorCount();
    if (len != att.weights.length)                revert LengthMismatch();

    uint256 sum = 0;
    for (uint256 i = 0; i < len; i++) {
        if (att.hotkeys[i] == bytes32(0))         revert ZeroValue();
        if (att.weights[i] == 0)                  revert ZeroWeight();
        for (uint256 j = i + 1; j < len; j++) {
            if (att.hotkeys[i] == att.hotkeys[j]) revert DuplicateValue();
        }
        sum += att.weights[i];
    }
    if (sum != BPS_BASE)                          revert WeightsMustSum10000();

    if (att.nonce != nonces[att.netuid] + 1)      revert StaleNonce();
    if (block.timestamp > att.deadline)           revert ExpiredAttestation();

    uint256 sigCount = sigs.length;
    if (sigCount < threshold)                     revert NotEnoughSignatures();

    bytes32 digest = _hashAttestation(att);
    address last   = address(0);
    for (uint256 i = 0; i < sigCount; i++) {
        address recovered = ECDSA.recover(digest, sigs[i]);
        if (!isSigner[recovered])                 revert UnknownSigner(recovered);
        if (recovered <= last)                    revert SignersNotSorted();
        last = recovered;
    }

    nonces[att.netuid] = att.nonce;
    ValidatorSet storage vs = _validators[att.netuid];
    for (uint256 i = 0; i < MAX_VALIDATORS; i++) {
        if (i < len) {
            vs.hotkeys[i] = att.hotkeys[i];
            vs.weights[i] = uint16(att.weights[i]);
        } else {
            vs.hotkeys[i] = bytes32(0);
            vs.weights[i] = 0;
        }
    }
    emit ValidatorsUpdated(att.netuid, att.nonce, att.hotkeys, att.weights);
}
```

`sum == 10_000` with each weight `> 0` implies each weight is in `[1, 9_998]`, so the `uint16(att.weights[i])` cast cannot truncate. The strict packed-from-slot-0 invariant (writes happen in declared order, trailing slots zeroed) lets `AlphaVault` use `weights[0] == 0` as the "subnet not configured" sentinel and break loops on the first zero.

The signature loop iterates *all* provided sigs (not just the first `threshold`). Extras are allowed but every one must be a valid signer and the full set must be ascending — TAO20 uses the same model.

### Internal `_hashAttestation`

```solidity
function _hashAttestation(WeightAttestation calldata att) internal view returns (bytes32) {
    return _hashTypedDataV4(
        keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                att.netuid,
                keccak256(abi.encodePacked(att.hotkeys)),
                keccak256(abi.encodePacked(att.weights)),
                att.nonce,
                att.deadline
            )
        )
    );
}
```

`_hashTypedDataV4` comes from OZ EIP712 v5 and applies the standard `\x19\x01 || domainSeparator || structHash` envelope.

### Events

```solidity
event SignersUpdated(address[] newSigners, uint8 newThreshold);
event ValidatorsUpdated(uint256 indexed netuid, uint256 nonce, bytes32[] hotkeys, uint256[] weights);
```

### Errors

| Category | Error |
|----------|-------|
| Validation | `NetuidOutOfRange`, `InvalidValidatorCount`, `LengthMismatch`, `ZeroValue`, `ZeroWeight`, `DuplicateValue`, `WeightsMustSum10000` |
| Freshness | `StaleNonce`, `ExpiredAttestation` |
| Signature | `NotEnoughSignatures`, `UnknownSigner(address)`, `SignersNotSorted` |
| Admin     | `ZeroAddress`, `ThresholdZero`, `ThresholdExceedsSigners` |

`ZeroValue` covers both zero hotkey (in attestation) and zero address (in signer set) — the calling function is the disambiguator. `DuplicateValue` covers both duplicate hotkey and duplicate signer. `ZeroAddress` is kept distinct for the constructor's admin-zero check because it's a different code path the user doesn't see in normal operation.

## AlphaVault Changes

`getValidators` now returns 2-tuple instead of 3-tuple. The packing invariant lets us derive `count` locally.

### New helper

```solidity
function _activeCount(uint16[3] memory weights) private pure returns (uint8 c) {
    for (; c < weights.length && weights[c] != 0; c++) {}
}
```

### Updated `_resolveValidators`

```solidity
function _resolveValidators(uint16 netuid)
    internal view
    returns (bytes32[3] memory hotkeys, uint16[3] memory weights)
{
    if (address(validatorRegistry) == address(0)) revert NoValidatorFound();
    (hotkeys, weights) = validatorRegistry.getValidators(netuid);
    if (weights[0] == 0) revert NoValidatorFound();
}
```

### Call-site pattern (every public mutator)

```solidity
(bytes32[3] memory hotkeys, uint16[3] memory weights) = _resolveValidators(netuid);
uint8 count = _activeCount(weights);
// ... rest of function unchanged: existing helpers (_fetchBalances, _sortHotkeysByBalanceDesc,
// _rebalanceOnce) keep their current `count`-bearing signatures
```

### Defensive depth in iteration loops

In every loop that iterates `for (i = 0; i < count; i++)`, also break on `hotkeys[i] == bytes32(0)`. Cheap parity (~10 gas per slot) that catches a corrupt-or-malicious registry returning a non-zero weight against a zero hotkey:

```solidity
for (uint8 i = 0; i < count; i++) {
    if (hotkeys[i] == bytes32(0)) break;
    // ...
}
```

### Validation philosophy

This follows industry practice from Aave V3, MakerDAO, Compound: **trust the source's math invariants, validate cheap sentinels.**

- **Trust** (do not re-derive in AlphaVault): `sum(weights) == 10_000`, no duplicates, packed-from-zero invariant. The registry guarantees these on write; re-checking in AlphaVault costs gas and only fires under owner-compromise scenarios that consumer-side checks can't defend against.
- **Validate** (cheap sentinels): `weights[0] == 0 ⇒ NoValidatorFound` in `_resolveValidators`; iteration is bounded by `count = _activeCount(weights)` (which itself stops at the first zero weight); each iteration also breaks on `hotkeys[i] == bytes32(0)` (defensive depth against a corrupt registry returning a non-zero weight against a zero hotkey). Costs negligible gas, prevents downstream precompile reverts on edge-case data.

The real trust boundary is `AlphaVault.setValidatorRegistry(address) onlyOwner`. That's an owner-key-hygiene problem, not something AlphaVault can defend against by re-validating individual reads.

### Diff scope

`ValidatorRegistry.sol` (full rewrite):
- `UPDATER_ROLE`, `setValidators(...)`, `setValidatorsBatch(...)` removed entirely.
- New `updateValidators(WeightAttestation, bytes[])` permissionless mutator.
- New `setSigners(address[], uint8)` admin-gated atomic rotation.
- New EIP-712 + signer-set + per-subnet-nonce machinery.

`IValidatorRegistry.sol`:
- `getValidators` returns `(bytes32[3], uint16[3])` instead of `(bytes32[3], uint16[3], uint8)`.
- `hasValidators` removed (only ever called by tests; callers can derive from `weights[0] == 0`).

`AlphaVault.sol`:
- 6 call sites update tuple destructuring and add a single `uint8 count = _activeCount(weights);` line.
- `_activeCount` helper added.
- Loop bodies add `if (hotkeys[i] == bytes32(0)) break;` defensive breaks.

Per-subnet-only update path: there is no batch equivalent of `updateValidators`. A relayer needing to update N subnets calls the function N times. This is intentional — keeps per-call gas predictable, isolates failure modes, and matches the per-subnet nonce model (each subnet has its own monotonic clock).

Total: ~30 lines touched in `AlphaVault.sol`, all mechanical.

## Off-Chain Attester (contract-side scope)

The contract pins what an attester service must produce. Implementation is out of scope for this design (TS/Bun reference like TAO20, or Python — operator's choice).

### What each attester instance does

1. Reads `ValidatorRegistry.nonces(netuid)` per subnet.
2. Selects `(hotkeys, weights)` for that subnet according to operator policy.
3. EIP-712-signs `WeightAttestation { netuid, hotkeys, weights, nonce: storedNonce + 1, deadline }`.
4. Exposes the signed payload (e.g., `GET /attestation/:netuid`).

### Determinism across instances

Structurally simpler than TAO20. For a given `(netuid, nonce)`, every honest attester computes the same `(hotkeys, weights)` from the same selection policy on the same chain state — the nonce *is* the deduplication bucket for the payload.

Only the `deadline` field needs cross-instance agreement so digests match. Use TAO20's deadline-bucketing trick:

```
deadline = floor(now / BUCKET) * BUCKET + DEADLINE_SECS
```

Defaults: `BUCKET = 10s`, `DEADLINE_SECS = 60s`. Any two attesters within the same 10-second window produce byte-identical attestations.

### Aggregation

A relayer or dApp:

1. Fetches attestations from `≥ threshold` instances.
2. Verifies the payloads byte-match.
3. Sorts the signatures by recovered address ascending (the contract requires sorted).
4. Submits `ValidatorRegistry.updateValidators(att, sigs)`.

### Bootstrap

First-ever update for a netuid signs `nonce = 1` (storedNonce defaults to 0). Document this in the attester spec.

### Liveness

If attesters go silent, weights stay frozen at the last successful update. `AlphaVault.processDeposit` / `withdraw` / `rebalance` continue to operate against the stale weights — no halt, just no rotation. This is an operational concern, not a contract concern.

### Out of scope for the contract design

- Selection algorithm (top-N validators by APY, vtrust, decentralization, blocklist) — operator policy. Should ship in a separate `attester/SPEC.md` like TAO20.
- Discovery / signer URL list — typically dApp/relayer config.
- Metering, rate limiting, key rotation procedures — operational concerns.

## Security Review

### Threats addressed

- **Replay of old applied attestation** — killed by monotonic per-subnet nonce. Each attestation is bound to exactly one `(netuid, nonce)` pair; once applied, `nonces[netuid]` advances and the same attestation cannot be re-used.
- **Cross-chain replay** — EIP-712 domain separator includes `chainId`. A signature valid on one chain is invalid on another.
- **Cross-contract replay** — EIP-712 domain separator includes `verifyingContract`. A signature valid against one `ValidatorRegistry` deployment is invalid against another.
- **Signature malleability** — OZ `ECDSA.recover` enforces low-`s` form.
- **Compromised signer stockpile** — once admin rotates via `setSigners`, the cleared `isSigner` flags cause the verify loop to revert `UnknownSigner` for any old-key signature, regardless of how far in the future the deadline was set. The verify-time membership check is the actual defense; the deadline is a soft cap on liveness gaps.
- **Threshold-zero / empty-set brick** — `setSigners` rejects `threshold == 0` and `threshold > newSigners.length`; the contract cannot be put in an unusable state by a single admin call.
- **Front-run griefing on race for next nonce** — two valid attestations both targeting nonce N+1: first lands, second reverts cleanly with `StaleNonce`. Both are honestly signed by threshold-of-N; the outcome is acceptable (whoever lands first is the canonical N+1).
- **Reentrancy** — `updateValidators` makes no external calls. ECDSA recovery is internal.
- **Calldata bombing on huge `sigs[]`** — caller pays the gas; protocol unaffected.
- **Front-run admin rotation** — if admin's `setSigners` lands first in a block, an in-flight attestation signed by old keys reverts. Attesters must re-sign with new keys. Correct behaviour.

### Trust boundary

The owner-controlled `AlphaVault.setValidatorRegistry(address)` is the real trust root. Owner can swap to a malicious registry returning attacker-controlled validator weights. Defense is admin-key hygiene (multisig, timelock), not consumer-side re-validation. AlphaVault's defense-in-depth checks (sentinel non-zero on slot 0, loop break on zero hotkey/weight) prevent precompile reverts but cannot defend against semantically-valid-but-malicious data.

### Bootstrapping

`nonces[netuid] = 0` initially. First update on a fresh subnet must sign `nonce = 1`. This must be documented in the attester spec; the contract's `StaleNonce` revert correctly rejects `nonce = 0` or `nonce > 1` first updates.

### EIP-712 hash safety

All struct fields are `uint256` or `bytes32[]` so the struct hash uses standard `keccak256(abi.encodePacked(arr))` for dynamic arrays without padding gymnastics. Cross-validated by reconstructing the digest in tests independently of the contract's `_hashTypedDataV4`.

## Migration

Single-file rewrite of `src/ValidatorRegistry.sol` on the current branch (`pg/validator_weight_attestation`). Existing tests under `test/ValidatorRegistry.t.sol` are rewritten for the new behaviour; `test/AlphaVault.t.sol` mocks updated for the 2-tuple read interface. No on-chain migration concern — branch has not been deployed.

If a deployed `AlphaVault` ever needs to swap to this registry, the existing `setValidatorRegistry(address) onlyOwner` path on `AlphaVault` is sufficient — no new migration tooling required.

## Testing

### Test scaffolding (test/ValidatorRegistry.t.sol)

- `setUp()` deploys `ValidatorRegistry` with `admin = address(this)`, three test signers from deterministic privkeys (`vm.addr(1)`, `vm.addr(2)`, `vm.addr(3)`), threshold 2.
- `_signAttestation(WeightAttestation memory att, uint256[] memory privkeys) returns (bytes[] memory sigs)`: signs with each privkey, sorts by recovered address ascending.
- `_independentDigest(WeightAttestation memory att) returns (bytes32)`: reconstructs the EIP-712 digest from scratch (mirrors TAO20's `_digest()` ground-truth helper). Used to cross-check signing without calling the contract's hash builder.
- `_makeAtt(uint256 netuid, uint256 len, uint256 nonce, uint256 deadline) returns (WeightAttestation memory)`: baseline valid attestations of various sizes.

Every test: use `vm.expectEmit(true, true, true, true)` before any state-changing call that emits; assert exact equality on emitted args. Use `assertEq` against concrete expected values (not "non-zero" approximations) for storage reads.

### Constructor

- `constructor_reverts_zeroAdmin`: `admin == address(0)` → `ZeroAddress`.
- `constructor_reverts_zeroSignerInInitial`: `address(0)` in initialSigners → `ZeroValue`.
- `constructor_reverts_duplicateInInitial`: `[A, B, A]` → `DuplicateValue`.
- `constructor_reverts_thresholdZero`: → `ThresholdZero`.
- `constructor_reverts_thresholdExceedsSigners`: → `ThresholdExceedsSigners`.
- `constructor_happy_setsAdminRole`: assert `hasRole(DEFAULT_ADMIN_ROLE, admin) == true`.
- `constructor_happy_installsSignerSet`: assert `signers.length == 3`; for each `i` assert `signers(i) == initialSigners[i]` and `isSigner(initialSigners[i]) == true`.
- `constructor_happy_setsThreshold`: `threshold() == 2`.
- `constructor_happy_emitsSignersUpdated`: exact `SignersUpdated(initialSigners, 2)`.
- `constructor_happy_eip712Domain`: from `eip712Domain()` assert `name == "AlphaVault ValidatorRegistry"`, `version == "1"`, `chainId == block.chainid`, `verifyingContract == address(registry)`.

### setSigners

- `setSigners_reverts_nonAdmin`: `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`.
- `setSigners_reverts_zeroValue`: → `ZeroValue`.
- `setSigners_reverts_duplicate`: → `DuplicateValue`.
- `setSigners_reverts_thresholdZero`: → `ThresholdZero`.
- `setSigners_reverts_thresholdExceedsNew`: → `ThresholdExceedsSigners`.
- `setSigners_clearsOldFlags`: old `[A, B, C]`, new `[D, E]`. Assert `isSigner(A/B/C) == false`, `isSigner(D/E) == true`.
- `setSigners_replacesArray`: assert `signers.length == 2`, `signers(0) == D`, `signers(1) == E`. `signers(2)` reverts (out-of-bounds).
- `setSigners_updatesThreshold`: assert `threshold() == newThreshold`.
- `setSigners_emitsSignersUpdated`: exact `(newSigners, newThreshold)`.
- `setSigners_atomicOnRevert`: attempt with `[D, address(0)]` → revert. Assert old state intact: `signers.length == 3`, `signers(0) == A`, `isSigner(A) == true`, `isSigner(D) == false`, `threshold()` unchanged.
- `setSigners_sameSignerKeptIfReused`: old `[A, B, C]`, new `[A, D]`. Assert `isSigner(A) == true`, `signers(0) == A`, `signers(1) == D`.

### updateValidators — happy path

- `update_happy_writesAllSlots_len3`: `(netuid=1, hotkeys=[h1,h2,h3], weights=[5000,3000,2000], nonce=1, deadline=now+60)`. Assert `nonces(1) == 1`, `getValidators(1)` returns `([h1,h2,h3], [5000,3000,2000])` element-by-element. Emit assertion: `ValidatorsUpdated(1, 1, [h1,h2,h3], [5000,3000,2000])`.
- `update_happy_writesAllSlots_len2`: assert `getValidators(1) == ([h1,h2,bytes32(0)], [6000,4000,0])`.
- `update_happy_writesAllSlots_len1`: assert `getValidators(1) == ([h1,bytes32(0),bytes32(0)], [10000,0,0])`.
- `update_happy_zeroesTrailingOnShrink`: first len=3, second len=1. Assert slots 1 and 2 zeroed after second.
- `update_happy_overwritesOnGrow`: first len=1, second len=3. Assert all 3 populated after second.
- `update_happy_threeSubnetsIndependent`: update netuid=1 nonce=1, netuid=2 nonce=1, netuid=1 nonce=2. Assert `nonces(1) == 2`, `nonces(2) == 1`, both `getValidators` correct.

### updateValidators — shape errors

For each: build baseline valid attestation, mutate one field, assert revert with named error:

- `update_reverts_emptyHotkeys` → `InvalidValidatorCount`
- `update_reverts_tooManyHotkeys` (4 hotkeys) → `InvalidValidatorCount`
- `update_reverts_lengthMismatch` (3 hotkeys, 2 weights) → `LengthMismatch`
- `update_reverts_netuidTooLarge` (`type(uint16).max + 1`) → `NetuidOutOfRange`
- `update_happy_netuidExactlyMax` (`type(uint16).max`) → succeeds (boundary)
- `update_reverts_zeroHotkey` → `ZeroValue`
- `update_reverts_zeroWeight_first` (`[0,5000,5000]`) → `ZeroWeight`
- `update_reverts_zeroWeight_middle` (`[3000,0,7000]`) → `ZeroWeight`
- `update_reverts_duplicateHotkey` (`[h1,h2,h1]`) → `DuplicateValue`
- `update_reverts_weightsSumLow` (sum=9999) → `WeightsMustSum10000`
- `update_reverts_weightsSumHigh` (sum=10001) → `WeightsMustSum10000`

### updateValidators — freshness errors

- `update_reverts_nonceStale` (att.nonce == stored) → `StaleNonce`.
- `update_reverts_nonceZero` (first ever, att.nonce = 0) → `StaleNonce`.
- `update_reverts_nonceSkipAhead` (stored=0, att.nonce=2) → `StaleNonce`.
- `update_reverts_deadlineExpired` (`vm.warp(att.deadline + 1)`) → `ExpiredAttestation`.
- `update_happy_deadlineExactlyNow` (`block.timestamp == att.deadline`) → succeeds (boundary; check is `>` not `>=`).

### updateValidators — signature errors

- `update_reverts_zeroSigs` → `NotEnoughSignatures`.
- `update_reverts_belowThreshold` (1 sig when threshold=2) → `NotEnoughSignatures`.
- `update_reverts_unknownSigner`: sign with unrelated privkey, attach as 2nd sig → `UnknownSigner(<recoveredAddr>)`. Assert the recovered-addr arg equals `vm.addr(unrelatedKey)`.
- `update_reverts_sigsNotSorted`: sign with two valid signers, deliberately swap descending → `SignersNotSorted`.
- `update_reverts_sameSignerTwice`: same signer's sig twice → `SignersNotSorted` (caught by `recovered <= last` after first iter).
- `update_acceptsAboveThreshold`: threshold=2, pass 3 valid sorted sigs → succeeds.
- `update_revertsAboveThreshold_oneInvalid`: threshold=2, pass 2 valid + 1 from non-signer → `UnknownSigner`.

### EIP-712 conformance

- `digest_independentReconstructionMatchesContract`: build attestation; sign the independently reconstructed digest; call `updateValidators` and observe success. Any digest mismatch would fire `UnknownSigner`.
- `digest_changesOnEachField`: baseline att; for each of (`netuid`, `hotkeys`, `weights`, `nonce`, `deadline`) mutate one field; assert independent digests differ.
- `digest_chainIdInDomain`: snapshot pre-fork digest; `vm.chainId(differentId)`; recompute independently; assert digests differ (chainId is in the domain separator).

### Auto-getter sanity

- `getValidators_unconfigured_returnsZeros`: `getValidators(99)` returns `(bytes32(0)x3, 0x3)`.
- `nonces_unconfigured_returnsZero`: `nonces(99) == 0`.
- `isSigner_unknown_returnsFalse`: `isSigner(0xDEAD) == false`.
- `signers_outOfBounds_reverts`: `signers(signers.length)` reverts (panic, no message).

### Race tests

- `update_concurrentNonces_firstWins`: two valid attestations both with nonce=1. First → succeeds, `nonces(1) == 1`. Second → reverts `StaleNonce`.

### Gas snapshots (informational)

- `gas_update_len1`, `gas_update_len2`, `gas_update_len3`: snapshot via `forge snapshot`. Not assertions; gives reviewers a regression baseline.

### AlphaVault tests

- Existing `test/AlphaVault.t.sol` updated: mock `IValidatorRegistry` returns 2-tuple. Existing test cases re-pass.
- New: `test_activeCount_derivedFromWeights`: mock returns `[10000,0,0]` → behaves as count=1; `[6000,4000,0]` → count=2; `[5000,3000,2000]` → count=3.
- New: `test_resolveValidators_revertsWhenWeightZero`: mock returns `[0,0,0]` → `_resolveValidators` reverts `NoValidatorFound`.
- New: `test_loop_breaksOnZeroHotkey_corruptRegistry`: mock returns `weights=[5000,5000,0]` but `hotkeys=[h1,bytes32(0),h3]` (impossible if registry honest). Defense-in-depth break kicks in at slot 1 cleanly without precompile revert.

## Decisions (and the reasoning behind them)

| Decision | Rationale |
|----------|-----------|
| Push-state per subnet | User-call gas stays cheap; AlphaVault read path unchanged; per-subnet update isolates failures (no batch revert risk). |
| No `UPDATER_ROLE` | Trust-minimization is the entire point of the change. |
| Admin only `setSigners` (no `addSigner`/`removeSigner`/`setThreshold`) | Atomic rotation prevents transient `threshold > signers.length` states; smaller admin surface. |
| Atomic bulk replace for signers | Single-key compromise is recoverable by re-submitting array minus the bad key — same cost as a scan-based remove. |
| No `MAX_DEADLINE_WINDOW` | Monotonic nonce + `isSigner` membership check at verify time make the window mostly redundant. Trust attesters to set sane deadlines (we already trust them to sign correct weights). |
| Monotonic per-subnet nonce | Strongest replay protection; deterministic ordering; second concurrent submitter at same nonce reverts cleanly. |
| All EIP-712 fields `uint256` | Avoids the manual 32-byte padding required for `uint16[]`/`uint64` in dynamic-array struct hashes. Range checks on input keep storage casts safe. |
| Drop `count` from `IValidatorRegistry` | Storage `[3]` arrays + packing-from-slot-0 invariant let AlphaVault derive count locally; the read interface gets simpler. |
| `bytes32[3]`/`uint16[3]` storage (cap 3) | Minimal AlphaVault refactor; existing call sites all assume `[3]`. Raising the cap would touch every loop in AlphaVault. |
| `mapping + manual address[]` for signers | Enumerable on-chain (`signers(i)` and `signers.length`) without OZ EnumerableSet's storage overhead; admin operations are infrequent so O(n) clear is fine. |
| `ZeroValue` / `DuplicateValue` consolidate type-suffixed errors | Function context disambiguates (caller knows which function they called); fewer error types in the ABI. |
| `count` derived in AlphaVault via `_activeCount`, helpers keep current sigs | Minimizes diff to AlphaVault — no helper-signature churn, just one extra call per public mutator. |
| Defense-in-depth break on zero hotkey in AlphaVault loops | ~10 gas/slot, catches a class of corrupt-registry returns. Aligns with Aave/Compound consumer patterns. |
| Trust registry math (`sum`, dedup), validate sentinels (`weights[0] != 0`) | Industry-standard pattern from Aave V3, MakerDAO, Compound: re-deriving math in the consumer doesn't defend against the actual trust boundary (owner-swappable registry); cheap sentinels do prevent precompile reverts on edge data. |
