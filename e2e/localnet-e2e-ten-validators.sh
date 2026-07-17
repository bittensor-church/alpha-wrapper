#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper - Local Chain E2E: ten-validator basic flow
# ============================================================================
#
# The registry accepts attested sets of up to 64 validators; this test runs the
# core user flow against a ten-validator set with distinct weights:
#   - seven extra hotkeys registered next to the bootstrap's three
#   - all ten attested in one EIP-712 update
#   - wrap: the deposit spreads across all ten validators by weight
#   - unwrap: the user receives the whole backing back, every slot drained
#
# Prerequisites: same as localnet-e2e.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

e2e_bootstrap

TEN_NET="${NETUIDS[0]}"
TEN_TID="${VAULT_IDS[0]}"
VALIDATOR_COUNT=10
TEN_WEIGHTS="1900,1700,1500,1300,1100,900,700,400,300,200"
DEPOSIT_RAW=60000000000
# Ten balance reads plus nine alignment moves dominate the wrap; the unwrap adds the gather
# hops. The bounds hold headroom over that, while a rejected dispatch (which burns everything
# forwarded to it) still overshoots them.
TEN_WRAP_GAS_BOUND=2500000
TEN_UNWRAP_GAS_BOUND=3500000

log "Phase 6: Register seven extra hotkeys on netuid $TEN_NET"

TEN_HK_B32S=("${ALL_HK_B32S[0]}" "${ALL_HK_B32S[1]}" "${ALL_HK_B32S[2]}")
TEN_HK_SS58S=("${ALL_HK_SS58S[0]}" "${ALL_HK_SS58S[1]}" "${ALL_HK_SS58S[2]}")

# Registration is rate-limited per interval as well as per block; lift the interval target so
# seven back-to-back registrations land quickly. Best-effort: register_hotkey retries across
# intervals anyway, this only shortens the wait.
btcli_cmd sudo set --netuid "$TEN_NET" \
    --wallet-name "$ALICE_WALLET" --param target_regs_per_interval --value 10 --no-prompt 2>&1 | tail -1 || true

for SUFFIX in d e f g h i j; do
    HK="hk_e2e_1${SUFFIX}"
    register_hotkey "$TEN_NET" "$HK"
    TEN_HK_B32S+=("$REGISTERED_HK_B32")
    TEN_HK_SS58S+=("$REGISTERED_HK_SS58")
    ok "$HK registered on netuid $TEN_NET: ${REGISTERED_HK_B32:0:18}..."
done

[[ "${#TEN_HK_B32S[@]}" == "$VALIDATOR_COUNT" ]] || fail "expected $VALIDATOR_COUNT hotkeys, have ${#TEN_HK_B32S[@]}"

log "Phase 7: Attest all ten validators in one update"

TEN_HKS_CSV=$(IFS=,; echo "${TEN_HK_B32S[*]}")
set_validators_py "$TEN_NET" "$TEN_HKS_CSV" "$TEN_WEIGHTS" | tail -1
ok "netuid $TEN_NET attested with $VALIDATOR_COUNT validators (weights $TEN_WEIGHTS)"

CURRENT_COUNT=$(cast call "$VAULT_ADDR" "getCurrentValidators(uint256)(bytes32[])" "$TEN_NET" --rpc-url "$RPC_URL" | count_entries)
[[ "$CURRENT_COUNT" == "$VALIDATOR_COUNT" ]] || fail "vault resolves $CURRENT_COUNT validators, expected $VALIDATOR_COUNT"
ok "Vault resolves all $VALIDATOR_COUNT attested validators"

python3 scripts/get_vault_state.py \
    --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
    --registry-address "$VAL_REGISTRY_ADDR" --netuid "$TEN_NET" \
    | python3 e2e/verify_csv.py --rows 1 --column-eq "token_id=$TEN_TID" --column-eq "validators_count=10"
ok "get_vault_state reports validators_count=10"

log "Phase 8: Wrap a deposit -> stake spreads across all ten validators"

deposit_and_wrap "$TEN_NET" "${TEN_HK_B32S[0]}" "${TEN_HK_SS58S[0]}" "$DEPOSIT_RAW" 4000000 "ten-validator wrap failed"
assert_gas_within "$TEN_WRAP_GAS_BOUND" "ten-validator wrap gas"

TEN_SHARES=$(vault_shares "$TEN_TID")
[[ "$TEN_SHARES" != "0" ]] || fail "no shares minted by the ten-validator wrap"
TEN_DEPOSITED=$(vault_total_stake "$TEN_TID")
assert_ge "$TEN_DEPOSITED" $((DEPOSIT_RAW - ROUNDING_DUST_SLOT_RAO * VALIDATOR_COUNT)) "wrap lost more than rounding dust"
ok "Wrapped: shares=$TEN_SHARES, totalStake=$TEN_DEPOSITED RAO (gas $(last_gas_used))"

# Targets derive from the transferred amount, not the live total: emissions accrued since the
# wrap only push slot balances up, so the lower bounds stay stable.
TEN_CLONE_SUB=$(clone_coldkey "$TEN_TID")
IFS=',' read -r -a TEN_WEIGHT_ARR <<< "$TEN_WEIGHTS"
for i in $(seq 0 $((VALIDATOR_COUNT - 1))); do
    SLOT=$(get_stake "${TEN_HK_B32S[$i]}" "$TEN_CLONE_SUB" "$TEN_NET")
    TARGET=$(python3 -c "print($DEPOSIT_RAW * ${TEN_WEIGHT_ARR[$i]} // 10000)")
    assert_ge "$SLOT" $((TARGET - 1000)) "validator $i below its weight target"
    ok "validator $i holds $SLOT RAO (target ~$TARGET)"
done

LAST_SEEN_COUNT=$(cast call "$VAULT_ADDR" "lastSeenHotkeys(uint256)(bytes32[])" "$TEN_TID" --rpc-url "$RPC_URL" | count_entries)
[[ "$LAST_SEEN_COUNT" == "$VALIDATOR_COUNT" ]] || fail "remembered set has $LAST_SEEN_COUNT entries, expected $VALIDATOR_COUNT"
ok "Remembered set tracks all $VALIDATOR_COUNT validators"

log "Phase 9: Unwrap all shares -> full backing returned"

TEN_BEFORE=$(sum_stake "$WRAPPER_SUB_B32" "$TEN_NET" "${TEN_HK_B32S[@]}")

vault_send 5000000 "ten-validator unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$TEN_TID" "$TEN_SHARES" "$WRAPPER_SUB_B32"
assert_gas_within "$TEN_UNWRAP_GAS_BOUND" "ten-validator unwrap gas"

TEN_SHARES_POST=$(vault_shares "$TEN_TID")
[[ "$TEN_SHARES_POST" == "0" ]] || fail "shares still $TEN_SHARES_POST after full unwrap"

TEN_AFTER=$(sum_stake "$WRAPPER_SUB_B32" "$TEN_NET" "${TEN_HK_B32S[@]}")
TEN_RECEIVED=$((TEN_AFTER - TEN_BEFORE))
# The gather touches up to one slot per validator and each touch can round a RAO.
assert_ge "$TEN_RECEIVED" $((TEN_DEPOSITED - ROUNDING_DUST_SLOT_RAO * VALIDATOR_COUNT)) \
    "user received $TEN_RECEIVED RAO of $TEN_DEPOSITED deposited"
ok "User received $TEN_RECEIVED RAO across ten validators (deposited $TEN_DEPOSITED, gas $(last_gas_used))"

for i in $(seq 0 $((VALIDATOR_COUNT - 1))); do
    SLOT=$(get_stake "${TEN_HK_B32S[$i]}" "$TEN_CLONE_SUB" "$TEN_NET")
    assert_le "$SLOT" "$ROUNDING_DUST_SLOT_RAO" "clone slot $i still holds $SLOT RAO after full unwrap"
done
ok "All ten clone slots drained to dust"

log "E2E complete"
echo "  AlphaVault:        $VAULT_ADDR"
echo "  ValidatorRegistry: $VAL_REGISTRY_ADDR"
echo "  Subnet:            $TEN_NET (tokenId $TEN_TID)"
echo "  Validators:        $VALIDATOR_COUNT"
ok "All phases passed"
