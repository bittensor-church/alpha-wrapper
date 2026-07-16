#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper - Local Chain E2E: vault stays live through every dust state
# ============================================================================
# Tests that no sequence of deposits, withdrawals, and validator changes can
# leave the vault stuck because of leftovers too small for the chain to move:
#   - Two full churn cycles, each leaving every kind of small leftover behind
#     (withdrawal remainders, skipped rebalances, sale leftovers, balances
#     left on rotated-out validators): every deposit and withdrawal along the
#     way keeps working at normal gas cost.
#   - The owner then raises the vault's minimum (as it would to track a chain
#     increase) above every validator slot while the position as a whole stays
#     above it: withdrawing alpha is refused cheaply with a clear error, and
#     the next deposit unlocks it.
#   - A closing ledger proves nothing was ever forfeited: everything the user
#     put in came back out, as delivered alpha or as TAO from sales.
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

# Every hotkey a delivery can land under; rotation replacements are appended as they register.
UNION_HOTKEYS=()
# Closing-ledger accumulators (alpha RAO).
DEPOSITED_TOTAL=0
SOLD_TOTAL=0

# Cumulative alpha delivered to the user across all withdrawals so far.
delivered_sum() {
    sum_stake "$WRAPPER_SUB_B32" "$NETUID" "${UNION_HOTKEYS[@]}"
}

# Deposit <amount> under <hotkey> and assert the wrap lands at normal gas cost.
deposit_step() { # <label> <hotkey_b32> <hotkey_ss58> <amount>
    local label="$1" hotkey_b32="$2" hotkey_ss58="$3" amount="$4"
    deposit_and_wrap "$NETUID" "$hotkey_b32" "$hotkey_ss58" "$amount" 1500000 "$label: wrap failed"
    assert_gas_within "$WRAP_GAS_BOUND" "$label: wrap"
    DEPOSITED_TOTAL=$((DEPOSITED_TOTAL + amount))
    ok "$label: wrapped $amount alpha RAO"
}

# Burn <percent> of the user's shares on the alpha rail and assert full delivery at normal gas.
unwrap_step() { # <label> <percent>
    local label="$1" percent="$2"
    local assets_before delivered_before burn delivered
    assets_before=$(holder_assets "$TOKEN_ID" "$WRAPPER_ADDR")
    delivered_before=$(delivered_sum)
    burn=$(python3 -c "print($(vault_shares "$TOKEN_ID") * $percent // 100)")
    vault_send 2500000 "$label: unwrap failed" \
        "unwrap(uint256,uint256,bytes32)" "$TOKEN_ID" "$burn" "$WRAPPER_SUB_B32"
    assert_gas_within "$UNWRAP_GAS_BOUND" "$label: unwrap"
    delivered=$(python3 -c "print($(delivered_sum) - $delivered_before)")
    assert_ge "$delivered" "$(python3 -c "print($assets_before * $percent // 100 * 98 // 100)")" \
        "$label: unwrap under-delivered"
    ok "$label: unwrapped $percent% of shares, delivered $delivered alpha RAO"
}

# Burn <percent> of the user's shares on the TAO rail and assert the payout matches the quote.
unwrap_for_tao_step() { # <label> <percent>
    local label="$1" percent="$2"
    local total_before burn quote min_tao_out tao_before_wei
    total_before=$(vault_total_stake "$TOKEN_ID")
    burn=$(python3 -c "print($(vault_shares "$TOKEN_ID") * $percent // 100)")
    quote=$(alpha_to_tao_quote "$NETUID" "$(python3 -c "print($(holder_assets "$TOKEN_ID" "$WRAPPER_ADDR") * $percent // 100)")")
    min_tao_out=$(python3 -c "print($quote * 10**9 // 2)")
    tao_before_wei=$(user_tao_wei)
    vault_send 2500000 "$label: TAO exit failed" \
        "unwrapForTao(uint256,uint256,uint256)" "$TOKEN_ID" "$burn" "$min_tao_out"
    assert_gas_within "$UNWRAP_GAS_BOUND" "$label: TAO exit"
    assert_payout_near_quote "$tao_before_wei" "$(user_tao_wei)" "$quote" "$label: TAO exit payout off quote"
    SOLD_TOTAL=$(python3 -c "print($SOLD_TOTAL + $total_before - $(vault_total_stake "$TOKEN_ID"))")
    ok "$label: sold $percent% of shares for TAO"
}

# One churn cycle: deposit, withdraw most of it (leaving a remainder), deposit again, rotate the
# primary validator out for a fresh one, withdraw across the rotated-out balances, deposit, and
# sell a slice for TAO. Leaves the union sprinkled with every kind of small leftover.
churn_cycle() { # <round> <primary_b32> <primary_ss58> <secondary_b32> <secondary_ss58> <kept_b32> <replacement_name>
    local round="$1" primary_b32="$2" primary_ss58="$3" secondary_b32="$4" secondary_ss58="$5"
    local kept_b32="$6" replacement_name="$7"

    log "Churn cycle $round"

    floor_boundary "$NETUID" "Cycle $round"
    deposit_step "Cycle $round" "$primary_b32" "$primary_ss58" \
        "$(python3 -c "print($FLOOR_BOUNDARY * 9 // 2)")"
    unwrap_step "Cycle $round" 80
    deposit_step "Cycle $round" "$secondary_b32" "$secondary_ss58" \
        "$(python3 -c "print($FLOOR_BOUNDARY * 5 // 2)")"

    register_hotkey "$NETUID" "$replacement_name"
    UNION_HOTKEYS+=("$REGISTERED_HK_B32")
    set_validators_py "$NETUID" "$REGISTERED_HK_B32,$secondary_b32,$kept_b32" "5000,3000,2000" > /dev/null
    ok "Cycle $round: rotated ${primary_b32:0:18}... out for ${REGISTERED_HK_B32:0:18}..."

    unwrap_step "Cycle $round (over the rotated-out balances)" 50
    assert_le "$(get_stake "$primary_b32" "$CLONE_COLDKEY" "$NETUID")" "$ROUNDING_DUST_SLOT_RAO" \
        "Cycle $round: rotated-out validator still holds stake"
    if cast call "$VAULT_ADDR" "lastSeenHotkeys(uint256)(bytes32[3])" "$TOKEN_ID" --rpc-url "$RPC_URL" \
        | grep -qi "${primary_b32#0x}"; then
        fail "Cycle $round: rotated-out validator still present in lastSeenHotkeys"
    fi
    ok "Cycle $round: withdrawal consolidated the rotated-out balances"

    deposit_step "Cycle $round" "$secondary_b32" "$secondary_ss58" \
        "$(python3 -c "print($FLOOR_BOUNDARY * 3)")"
    unwrap_for_tao_step "Cycle $round" 40
}

e2e_bootstrap

FLOOR=$(cast call "$VAULT_ADDR" "minStakeTaoFloor()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
info "minStakeTaoFloor = $FLOOR RAO"

NETUID="${NETUIDS[0]}"
TOKEN_ID="${VAULT_IDS[0]}"
HOTKEY_A="${ALL_HK_B32S[0]}"
HOTKEY_A_SS58="${ALL_HK_SS58S[0]}"
HOTKEY_B="${ALL_HK_B32S[1]}"
HOTKEY_B_SS58="${ALL_HK_SS58S[1]}"
HOTKEY_C="${ALL_HK_B32S[2]}"
HOTKEY_C_SS58="${ALL_HK_SS58S[2]}"
UNION_HOTKEYS=("$HOTKEY_A" "$HOTKEY_B" "$HOTKEY_C")

log "Fixture position"

# The clone deploys on the first wrap; resolve its coldkey once with a bootstrap deposit.
floor_boundary "$NETUID" "Bootstrap deposit"
deposit_step "Bootstrap deposit" "$HOTKEY_A" "$HOTKEY_A_SS58" \
    "$(python3 -c "print($FLOOR_BOUNDARY * 3 // 2)")"
CLONE_COLDKEY=$(clone_coldkey "$TOKEN_ID")

churn_cycle 1 "$HOTKEY_A" "$HOTKEY_A_SS58" "$HOTKEY_B" "$HOTKEY_B_SS58" "$HOTKEY_C" "hk_e2e_1d"
CYCLE1_REPLACEMENT="${UNION_HOTKEYS[3]}"
churn_cycle 2 "$HOTKEY_B" "$HOTKEY_B_SS58" "$HOTKEY_C" "$HOTKEY_C_SS58" "$CYCLE1_REPLACEMENT" "hk_e2e_1e"
CYCLE2_REPLACEMENT="${UNION_HOTKEYS[4]}"

log "Raised floor devalues every slot below it while the position stays above"

# Rebuild a full 50/30/20 split first, then raise the vault floor above the largest slot (as the
# owner would to track a chain increase): every slot is below the floor while the position as a
# whole stays above it - the one state where the alpha rail must refuse a position worth exiting.
ORIGINAL_FLOOR=$FLOOR
floor_boundary "$NETUID" "Split devaluation"
deposit_step "Split devaluation" "$HOTKEY_C" "$HOTKEY_C_SS58" \
    "$(python3 -c "print($FLOOR_BOUNDARY * 6)")"
LARGEST_SLOT=$(python3 -c "print(max(
    $(get_stake "$CYCLE2_REPLACEMENT" "$CLONE_COLDKEY" "$NETUID"),
    $(get_stake "$HOTKEY_C" "$CLONE_COLDKEY" "$NETUID"),
    $(get_stake "$CYCLE1_REPLACEMENT" "$CLONE_COLDKEY" "$NETUID")))")
LARGEST_VALUE=$(alpha_value_tao "$NETUID" "$LARGEST_SLOT")
TOTAL_VALUE=$(alpha_value_tao "$NETUID" "$(vault_total_stake "$TOKEN_ID")")
RAISED_FLOOR=$(python3 -c "print($LARGEST_VALUE * 13 // 10)")
assert_le "$RAISED_FLOOR" "$TOTAL_VALUE * 9 // 10 - 1" \
    "Split devaluation: split too skewed to raise the floor between largest and total (largest $LARGEST_VALUE, total $TOTAL_VALUE)"
set_vault_floor "$RAISED_FLOOR" "Split devaluation: raising the vault floor failed"
# floor_boundary reads FLOOR when sizing the healing deposit, which must clear the raised floor.
FLOOR=$RAISED_FLOOR
ok "Floor raised to $RAISED_FLOOR RAO: every slot below it (largest $LARGEST_VALUE RAO), position worth $TOTAL_VALUE RAO above it"

assert_vault_reverts_with "GatherBelowFloor()" 2500000 \
    "Split devaluation: alpha exit did NOT revert as GatherBelowFloor" \
    "unwrap(uint256,uint256,bytes32)" "$TOKEN_ID" "$(vault_shares "$TOKEN_ID")" "$WRAPPER_SUB_B32"
assert_gas_within "$REVERT_GAS_BOUND" "Split devaluation: alpha-exit refusal"
ok "Alpha exit refused up front as GatherBelowFloor, without burning the gas budget"

# The next deposit creates a slot the withdrawal can gather from, unlocking the alpha rail.
floor_boundary "$NETUID" "Split devaluation"
deposit_step "Split devaluation (healing)" "$HOTKEY_C" "$HOTKEY_C_SS58" \
    "$(python3 -c "print($FLOOR_BOUNDARY * 5 // 2)")"
unwrap_step "Split devaluation (healed)" 50
set_vault_floor "$ORIGINAL_FLOOR" "Split devaluation: restoring the vault floor failed"

log "Full exit and closing ledger"

unwrap_for_tao_step "Closing" 100
[[ "$(vault_shares "$TOKEN_ID")" == "0" ]] || fail "Closing: shares not fully burned"
assert_le "$(vault_total_stake "$TOKEN_ID")" "$ROUNDING_DUST_TOTAL_RAO" \
    "Closing: stake left behind after the full exit"

# Everything deposited must have come back out as delivered alpha or as alpha sold for TAO;
# emissions only push the left side up, so a shortfall means stake was forfeited along the way.
DELIVERED_TOTAL=$(delivered_sum)
assert_ge "$(python3 -c "print($DELIVERED_TOTAL + $SOLD_TOTAL)")" \
    "$(python3 -c "print($DEPOSITED_TOTAL * 99 // 100)")" \
    "Closing: ledger shortfall (delivered $DELIVERED_TOTAL + sold $SOLD_TOTAL < deposited $DEPOSITED_TOTAL)"
ok "Ledger closed: deposited $DEPOSITED_TOTAL, delivered $DELIVERED_TOTAL, sold $SOLD_TOTAL alpha RAO"

log "E2E (min-stake liveness) complete"
ok "Two churn cycles, a rotation each, and a floor raise: every deposit and exit stayed live, nothing forfeited"
