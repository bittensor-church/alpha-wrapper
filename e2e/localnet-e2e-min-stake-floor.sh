#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper - Local Chain E2E: min-stake floor handling
# ============================================================================
# Tests that the vault respects the chain's minimum-stake rule without ever
# costing users money, in three scenarios:
#   1. A deposit below the vault's minimum is refused outright with a clear
#      error, and a deposit above it goes through. (The vault's minimum is
#      raised above the chain's for this test, because the chain itself blocks
#      anything smaller before the vault ever sees it.)
#   2. Small leftovers stranded when the validator set changes are picked up
#      by the next deposit - nothing is ever forfeited.
#   3. An internal move too small for the chain to accept is skipped up front
#      rather than attempted and failed, so the transaction doesn't waste gas;
#      the imbalance is corrected by a later, larger deposit.
# Shared fixture bring-up and helpers come from e2e_common.sh.
#
# Prerequisites:
#   - Local subtensor running at ws://127.0.0.1:9944
#   - btcli installed with Alice wallet (hotkey "default")
#   - forge/cast installed
#   - python3 with substrate-interface
#   - Funded EVM deployer (see DEPLOYER in e2e/e2e_common.sh)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

e2e_bootstrap

FLOOR=$(cast call "$VAULT_ADDR" "minStakeTaoFloor()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
info "minStakeTaoFloor = $FLOOR RAO"

log "Wrap gate binds at the raised vault floor"

# A sub-chain-floor deposit cannot even park, so exercise the vault's gate by raising its floor to
# 2x the chain's: a between-floors deposit must be refused, a top-up past the raised floor must wrap.
FLOOR_NETUID="${NETUIDS[0]}"
FLOOR_HOTKEY="${ALL_HK_B32S[0]}"
FLOOR_HOTKEY_SS58="${ALL_HK_SS58S[0]}"
RAISED_FLOOR=$((FLOOR * 2))
set_vault_floor "$RAISED_FLOOR" "Floor gate: raising the vault floor failed"
floor_boundary "$FLOOR_NETUID" "Floor gate"
MID_ALPHA=$(python3 -c "print($FLOOR_BOUNDARY * 3 // 2)")
ok "Alpha price=$FLOOR_PRICE -> chain-floor boundary=$FLOOR_BOUNDARY alpha RAO, parking $MID_ALPHA"

BOUNDARY_MAILBOX=$(mailbox_addr "$FLOOR_NETUID")
# 1.5x the boundary clears the chain's transfer floor only while the chain's minimum stake
# matches the vault's deploy floor; fail with context if the localnet image drifts.
transfer_stake_py "$(h160_to_ss58 "$BOUNDARY_MAILBOX")" "$FLOOR_HOTKEY_SS58" "$FLOOR_NETUID" "$MID_ALPHA" | tail -1 \
    || fail "Floor gate: parking transfer refused - has the chain's minimum stake moved past this script's sizing ($MID_ALPHA alpha = 1.5x the vault deploy floor)?"
assert_vault_reverts_with "DepositTooSmall()" 1500000 \
    "Floor gate: between-floors wrap did NOT revert as DepositTooSmall" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$FLOOR_NETUID" "$FLOOR_HOTKEY"
ok "wrap refused a deposit between the chain floor and the raised vault floor as DepositTooSmall"

# A second parking transfer doubles the mailbox to ~3x the chain floor, above the raised floor.
transfer_stake_py "$(h160_to_ss58 "$BOUNDARY_MAILBOX")" "$FLOOR_HOTKEY_SS58" "$FLOOR_NETUID" "$MID_ALPHA" | tail -1
vault_send 1500000 "Floor gate: above-floor wrap failed" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$FLOOR_NETUID" "$FLOOR_HOTKEY"
ok "wrap accepted the deposit once it cleared the raised floor"
# A healthy first wrap (clone deploys + flush + skipped sub-floor moves) anchors the gas budget below.
WRAP_GAS_BASELINE=$(last_gas_used)
[[ "$WRAP_GAS_BASELINE" =~ ^[0-9]+$ ]] || fail "Floor gate: could not parse gasUsed for the wrap baseline"
info "Healthy first-wrap gas baseline: $WRAP_GAS_BASELINE"

# Restore the deploy-time floor for the remaining scenarios.
set_vault_floor "$FLOOR" "Floor gate: restoring the vault floor failed"

log "Rotated-out dust is consolidated by the next wrap"

# Park sub-floor dust under a soon-rotated hotkey; the next wrap's fresh deposit starts the roller,
# so deposit + dust roll over the chain floor in one transaction - no keeper, no forfeiture.
DUST_NETUID="${NETUIDS[2]}"
DUST_TOKEN_ID="${VAULT_IDS[2]}"
DUST_HOTKEY="${ALL_HK_B32S[6]}"
DUST_HOTKEY_SS58="${ALL_HK_SS58S[6]}"
KEPT_HOTKEY_B="${ALL_HK_B32S[7]}"
KEPT_HOTKEY_B_SS58="${ALL_HK_SS58S[7]}"
KEPT_HOTKEY_C="${ALL_HK_B32S[8]}"

# A fresh validator to take the dust hotkey's slot after the rotation.
register_hotkey "$DUST_NETUID" "hk_e2e_3d"
ROTATED_IN_HOTKEY="$REGISTERED_HK_B32"
ok "Registered replacement validator ${ROTATED_IN_HOTKEY:0:18}... on netuid $DUST_NETUID"

# The bootstrap's 50/30/20 three-validator set is already attested, with the dust hotkey first.
floor_boundary "$DUST_NETUID" "Dust consolidation"
DUST_PRICE=$FLOOR_PRICE
DUST_BOUNDARY=$FLOOR_BOUNDARY
# 1.5x the boundary clears the deposit floor while every corrective move toward the 50/30/20
# split stays below it, keeping the whole deposit on the dust hotkey.
DUST_DEPOSIT=$(python3 -c "print($DUST_BOUNDARY * 3 // 2)")
deposit_and_wrap "$DUST_NETUID" "$DUST_HOTKEY" "$DUST_HOTKEY_SS58" "$DUST_DEPOSIT" 1500000 "Dust consolidation: wrap failed"

DUST_SHARES=$(vault_shares "$DUST_TOKEN_ID")
DUST_CLONE_COLDKEY=$(clone_coldkey "$DUST_TOKEN_ID")

# Burn 5/6 of the shares: delivers ~1.25x the boundary and leaves ~0.25x the boundary (sub-floor) dust.
DUST_BURN=$(python3 -c "print($DUST_SHARES * 5 // 6)")
vault_send 2500000 "Dust consolidation: partial unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$DUST_TOKEN_ID" "$DUST_BURN" "$WRAPPER_SUB_B32"
DUST_RESIDUE=$(get_stake "$DUST_HOTKEY" "$DUST_CLONE_COLDKEY" "$DUST_NETUID")
DUST_IS_SUBFLOOR=$(python3 -c "print('yes' if $DUST_RESIDUE * $DUST_PRICE // 10**18 < $FLOOR else 'no')")
[[ "$DUST_IS_SUBFLOOR" == "yes" ]] || fail "Dust consolidation: residual $DUST_RESIDUE is not sub-floor (price $DUST_PRICE)"
ok "Left sub-floor dust of $DUST_RESIDUE alpha RAO under the soon-rotated hotkey"

# Rotate the dust hotkey out for the replacement, then wrap a fresh above-floor deposit under a
# surviving validator.
set_validators_py "$DUST_NETUID" "$ROTATED_IN_HOTKEY,$KEPT_HOTKEY_B,$KEPT_HOTKEY_C" "5000,3000,2000" > /dev/null
DUST_TOTAL_BEFORE=$(vault_total_stake "$DUST_TOKEN_ID")
CONSOLIDATING_DEPOSIT=$((DUST_BOUNDARY * 3))
deposit_and_wrap "$DUST_NETUID" "$KEPT_HOTKEY_B" "$KEPT_HOTKEY_B_SS58" "$CONSOLIDATING_DEPOSIT" 2500000 "Dust consolidation: consolidating wrap failed"

DUST_RESIDUE_POST=$(get_stake "$DUST_HOTKEY" "$DUST_CLONE_COLDKEY" "$DUST_NETUID")
assert_le "$DUST_RESIDUE_POST" "$ROUNDING_DUST_SLOT_RAO" "Dust consolidation: rotated dust NOT consolidated"
ok "Next wrap consolidated the rotated dust: rotated-out hotkey left with $DUST_RESIDUE_POST RAO"

# The remembered set must drop the drained hotkey and the backing must fold in deposit + reclaimed dust.
DUST_LAST_SEEN=$(cast call "$VAULT_ADDR" "lastSeenHotkeys(uint256)(bytes32[3])" "$DUST_TOKEN_ID" --rpc-url "$RPC_URL")
if echo "$DUST_LAST_SEEN" | grep -qi "${DUST_HOTKEY#0x}"; then
    fail "Dust consolidation: consolidated hotkey still present in lastSeenHotkeys"
fi
DUST_TOTAL_AFTER=$(vault_total_stake "$DUST_TOKEN_ID")
CONSERVED=$(python3 -c "print('yes' if $DUST_TOTAL_AFTER >= $DUST_TOTAL_BEFORE + $CONSOLIDATING_DEPOSIT - 100 else 'no')")
[[ "$CONSERVED" == "yes" ]] || fail "Dust consolidation: backing did not fold in deposit + reclaimed dust ($DUST_TOTAL_AFTER)"
ok "Backing folded in the fresh deposit and the reclaimed dust; remembered set refreshed to the current set"

log "A sub-floor rebalance move is skipped, not attempted"

# Against a 50/30/20 three-validator split, a 1.5x-floor deposit leaves every corrective move
# sub-floor; the chain would reject such a move at full forwarded-gas cost, so the vault must
# skip them pre-call and leave the split drifted.
SKIP_NETUID="${NETUIDS[1]}"
SKIP_TOKEN_ID="${VAULT_IDS[1]}"
OVER_HOTKEY="${ALL_HK_B32S[3]}"
UNDER_HOTKEY_B="${ALL_HK_B32S[4]}"
UNDER_HOTKEY_C="${ALL_HK_B32S[5]}"
OVER_HOTKEY_SS58="${ALL_HK_SS58S[3]}"
set_validators_py "$SKIP_NETUID" "$OVER_HOTKEY,$UNDER_HOTKEY_B,$UNDER_HOTKEY_C" "5000,3000,2000" > /dev/null

floor_boundary "$SKIP_NETUID" "Sub-floor skip"
SKIP_BOUNDARY=$FLOOR_BOUNDARY
# 1.5x the boundary clears the deposit floor while the corrective moves (0.45x and 0.3x) stay below it.
SKIP_DEPOSIT=$(python3 -c "print($SKIP_BOUNDARY * 3 // 2)")
deposit_and_wrap "$SKIP_NETUID" "$OVER_HOTKEY" "$OVER_HOTKEY_SS58" "$SKIP_DEPOSIT" 1500000 \
    "Sub-floor skip: wrap with sub-floor residue failed (doomed move attempted?)"
SKIP_GAS_USED=$(last_gas_used)
[[ "$SKIP_GAS_USED" =~ ^[0-9]+$ ]] || fail "Sub-floor skip: could not parse gasUsed"

SKIP_CLONE_COLDKEY=$(clone_coldkey "$SKIP_TOKEN_ID")
UNDER_B_STAKE=$(get_stake "$UNDER_HOTKEY_B" "$SKIP_CLONE_COLDKEY" "$SKIP_NETUID")
UNDER_C_STAKE=$(get_stake "$UNDER_HOTKEY_C" "$SKIP_CLONE_COLDKEY" "$SKIP_NETUID")
[[ "$UNDER_B_STAKE" == "0" && "$UNDER_C_STAKE" == "0" ]] \
    || fail "Sub-floor skip: a sub-floor move was executed ($UNDER_B_STAKE / $UNDER_C_STAKE RAO moved)"
# Baseline-derived bound tracks chain-side gas re-pricing; a doomed move burns far past +25%.
SKIP_GAS_BOUND=$(python3 -c "print($WRAP_GAS_BASELINE * 5 // 4)")
python3 -c "import sys; sys.exit(0 if $SKIP_GAS_USED <= $SKIP_GAS_BOUND else 1)" \
    || fail "Sub-floor skip: wrap consumed $SKIP_GAS_USED gas (bound $SKIP_GAS_BOUND; doomed move burned the budget)"
ok "Sub-floor moves skipped: wrap used $SKIP_GAS_USED gas (bound $SKIP_GAS_BOUND), split left drifted"

# A later above-floor deposit makes both corrective moves land and clears the drift.
deposit_and_wrap "$SKIP_NETUID" "$OVER_HOTKEY" "$OVER_HOTKEY_SS58" "$((SKIP_BOUNDARY * 6))" 1500000 \
    "Sub-floor skip: follow-up wrap failed"
UNDER_B_STAKE=$(get_stake "$UNDER_HOTKEY_B" "$SKIP_CLONE_COLDKEY" "$SKIP_NETUID")
UNDER_C_STAKE=$(get_stake "$UNDER_HOTKEY_C" "$SKIP_CLONE_COLDKEY" "$SKIP_NETUID")
[[ "$UNDER_B_STAKE" != "0" && "$UNDER_C_STAKE" != "0" ]] \
    || fail "Sub-floor skip: drift did not clear on the follow-up deposit ($UNDER_B_STAKE / $UNDER_C_STAKE RAO)"
ok "Follow-up deposit cleared the drift: $UNDER_B_STAKE and $UNDER_C_STAKE RAO on the under-validators"

log "E2E (min-stake floor) complete"
ok "Min-stake floor enforced on wrap; rotated dust consolidated; sub-floor rebalance skipped in-budget"
