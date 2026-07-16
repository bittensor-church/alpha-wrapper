#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper - Local Chain E2E: dust cannot lock the vault
# ============================================================================
# Tests that no dust state can permanently block deposits or withdrawals, in
# three scenarios:
#   1. A position reduced to dust under a validator that dropped out of the
#      set: the alpha exit is refused cheaply with a clear error, the TAO
#      exit still pays out in full, and the vault works normally afterwards.
#   2. A market crash that devalues a position below the chain's minimum:
#      the alpha exit is refused clearly instead of failing forever, the TAO
#      exit still pays out, and deposits keep working at the crashed price.
#   3. A small holder alongside a large one, its slice below the minimum:
#      both exits refuse without touching the large holder's backing, and a
#      top-up lets the small holder leave in full; the large holder exits
#      unharmed.
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

# Second holder for the multi-holder scenario: the well-known Hardhat #1 test key, localnet-only.
HOLDER2_ADDR="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
HOLDER2_PK="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

e2e_bootstrap

FLOOR=$(cast call "$VAULT_ADDR" "minStakeTaoFloor()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
info "minStakeTaoFloor = $FLOOR RAO"
[[ "$(cast wallet address "$HOLDER2_PK")" == "$HOLDER2_ADDR" ]] || fail "holder-2 key/address mismatch"

log "Scenario 1: rotated-out dust cannot lock the vault"

ROTATED_OUT_NETUID="${NETUIDS[0]}"
ROTATED_OUT_TOKEN_ID="${VAULT_IDS[0]}"
ROTATED_OUT_HOTKEY="${ALL_HK_B32S[0]}"
ROTATED_OUT_HOTKEY_SS58="${ALL_HK_SS58S[0]}"
KEPT_HOTKEY_B="${ALL_HK_B32S[1]}"
KEPT_HOTKEY_B_SS58="${ALL_HK_SS58S[1]}"
KEPT_HOTKEY_C="${ALL_HK_B32S[2]}"

# A fresh validator to take the dust hotkey's slot after the rotation.
register_hotkey "$ROTATED_OUT_NETUID" "hk_e2e_1d"
REPLACEMENT_HOTKEY="$REGISTERED_HK_B32"
ok "Registered replacement validator ${REPLACEMENT_HOTKEY:0:18}... on netuid $ROTATED_OUT_NETUID"

floor_boundary "$ROTATED_OUT_NETUID" "Rotated-out dust"
# 1.5x the boundary clears the deposit floor while every corrective move toward the 50/30/20
# split stays below it, keeping the whole deposit on the soon-rotated hotkey.
ROTATED_OUT_DEPOSIT=$(python3 -c "print($FLOOR_BOUNDARY * 3 // 2)")
deposit_and_wrap "$ROTATED_OUT_NETUID" "$ROTATED_OUT_HOTKEY" "$ROTATED_OUT_HOTKEY_SS58" "$ROTATED_OUT_DEPOSIT" 1500000 \
    "Rotated-out dust: wrap failed"

# Burn 5/6 of the shares, then rotate: the leftover is sub-floor dust on a rotated-out hotkey and
# there is no fresh deposit to consolidate it - the worst stranded state the vault can reach.
ROTATED_OUT_CLONE_COLDKEY=$(clone_coldkey "$ROTATED_OUT_TOKEN_ID")
ROTATED_OUT_BURN=$(python3 -c "print($(vault_shares "$ROTATED_OUT_TOKEN_ID") * 5 // 6)")
vault_send 2500000 "Rotated-out dust: partial unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$ROTATED_OUT_TOKEN_ID" "$ROTATED_OUT_BURN" "$WRAPPER_SUB_B32"
ROTATED_OUT_RESIDUE=$(get_stake "$ROTATED_OUT_HOTKEY" "$ROTATED_OUT_CLONE_COLDKEY" "$ROTATED_OUT_NETUID")
[[ $(python3 -c "print(1 if $(alpha_value_tao "$ROTATED_OUT_NETUID" "$ROTATED_OUT_RESIDUE") < $FLOOR else 0)") == "1" ]] \
    || fail "Rotated-out dust: residual $ROTATED_OUT_RESIDUE alpha RAO is not sub-floor"
set_validators_py "$ROTATED_OUT_NETUID" "$REPLACEMENT_HOTKEY,$KEPT_HOTKEY_B,$KEPT_HOTKEY_C" "5000,3000,2000" > /dev/null
ok "Position is now $ROTATED_OUT_RESIDUE alpha RAO of dust under a rotated-out hotkey"

ROTATED_OUT_SHARES=$(vault_shares "$ROTATED_OUT_TOKEN_ID")
assert_vault_reverts_with "ConsolidationBelowFloor()" 1500000 \
    "Rotated-out dust: alpha exit did NOT revert as ConsolidationBelowFloor" \
    "unwrap(uint256,uint256,bytes32)" "$ROTATED_OUT_TOKEN_ID" "$ROTATED_OUT_SHARES" "$WRAPPER_SUB_B32"
assert_gas_within "$REVERT_GAS_BOUND" "Rotated-out dust: alpha-exit refusal"
ok "Alpha exit refused up front as ConsolidationBelowFloor, without burning the gas budget"

# The TAO exit needs no consolidation and full drains are floor-exempt on the chain: it must pay
# out even from this state.
ROTATED_OUT_QUOTE=$(alpha_to_tao_quote "$ROTATED_OUT_NETUID" "$(vault_total_stake "$ROTATED_OUT_TOKEN_ID")")
ROTATED_OUT_MIN_OUT=$(python3 -c "print($ROTATED_OUT_QUOTE * 10**9 // 2)")
ROTATED_OUT_PRE_WEI=$(user_tao_wei)
vault_send 2500000 "Rotated-out dust: TAO exit failed from the dust state" \
    "unwrapForTao(uint256,uint256,uint256)" "$ROTATED_OUT_TOKEN_ID" "$ROTATED_OUT_SHARES" "$ROTATED_OUT_MIN_OUT"
assert_payout_near_quote "$ROTATED_OUT_PRE_WEI" "$(user_tao_wei)" "$ROTATED_OUT_QUOTE" \
    "Rotated-out dust: TAO exit payout off quote"
[[ "$(vault_shares "$ROTATED_OUT_TOKEN_ID")" == "0" ]] || fail "Rotated-out dust: shares not fully burned"
assert_le "$(get_stake "$ROTATED_OUT_HOTKEY" "$ROTATED_OUT_CLONE_COLDKEY" "$ROTATED_OUT_NETUID")" "$ROUNDING_DUST_SLOT_RAO" \
    "Rotated-out dust: rotated-out hotkey still holds stake after the TAO exit"
assert_le "$(vault_total_stake "$ROTATED_OUT_TOKEN_ID")" "$ROUNDING_DUST_TOTAL_RAO" \
    "Rotated-out dust: stake left behind after the TAO exit"
ok "TAO exit drained the dust in full and paid out per the chain quote"

# The token stays fully usable after the episode.
floor_boundary "$ROTATED_OUT_NETUID" "Rotated-out dust"
ROTATED_OUT_RETRY=$(python3 -c "print($FLOOR_BOUNDARY * 3 // 2)")
deposit_and_wrap "$ROTATED_OUT_NETUID" "$KEPT_HOTKEY_B" "$KEPT_HOTKEY_B_SS58" "$ROTATED_OUT_RETRY" 1500000 \
    "Rotated-out dust: follow-up wrap failed"
vault_send 2500000 "Rotated-out dust: follow-up unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$ROTATED_OUT_TOKEN_ID" "$(vault_shares "$ROTATED_OUT_TOKEN_ID")" "$WRAPPER_SUB_B32"
ok "Round-trip after the dust episode: wrap and unwrap both clean"

log "Scenario 2: a price crash cannot lock exits"

CRASH_NETUID="${NETUIDS[1]}"
CRASH_TOKEN_ID="${VAULT_IDS[1]}"
CRASH_HOTKEY="${ALL_HK_B32S[3]}"
CRASH_HOTKEY_SS58="${ALL_HK_SS58S[3]}"
CRASH_SELL_HOTKEY="${ALL_HK_B32S[4]}"
CRASH_SELL_HOTKEY_SS58="${ALL_HK_SS58S[4]}"

floor_boundary "$CRASH_NETUID" "Price crash"
# Just above the floor, so a sell that roughly halves the price (the crash helper's reach) drops
# the whole position well under it.
CRASH_DEPOSIT=$(python3 -c "print($FLOOR_BOUNDARY * 12 // 10)")
deposit_and_wrap "$CRASH_NETUID" "$CRASH_HOTKEY" "$CRASH_HOTKEY_SS58" "$CRASH_DEPOSIT" 1500000 \
    "Price crash: wrap failed"
ok "Healthy position wrapped at price $FLOOR_PRICE"

# Alice dumps alpha until the whole position is worth less than the floor - devalued by the
# market alone, with no stake moved.
crash_price_until_below "$CRASH_NETUID" "$CRASH_SELL_HOTKEY" "$CRASH_SELL_HOTKEY_SS58" \
    "$(vault_total_stake "$CRASH_TOKEN_ID")" $((FLOOR * 9 / 10)) "Price crash"
CRASH_VALUE=$(alpha_value_tao "$CRASH_NETUID" "$(vault_total_stake "$CRASH_TOKEN_ID")")
python3 -c "import sys; sys.exit(0 if $CRASH_VALUE < $FLOOR else 1)" \
    || fail "Price crash: position still worth $CRASH_VALUE RAO (floor $FLOOR)"
ok "Position devalued to $CRASH_VALUE RAO, below the $FLOOR RAO floor"

CRASH_SHARES=$(vault_shares "$CRASH_TOKEN_ID")
assert_vault_reverts_with "WithdrawTooSmall()" 1500000 \
    "Price crash: alpha exit did NOT revert as WithdrawTooSmall" \
    "unwrap(uint256,uint256,bytes32)" "$CRASH_TOKEN_ID" "$CRASH_SHARES" "$WRAPPER_SUB_B32"
assert_gas_within "$REVERT_GAS_BOUND" "Price crash: alpha-exit refusal"
ok "Alpha exit refused up front as WithdrawTooSmall, without burning the gas budget"

CRASH_QUOTE=$(alpha_to_tao_quote "$CRASH_NETUID" "$(vault_total_stake "$CRASH_TOKEN_ID")")
CRASH_MIN_OUT=$(python3 -c "print($CRASH_QUOTE * 10**9 // 2)")
CRASH_PRE_WEI=$(user_tao_wei)
vault_send 2500000 "Price crash: TAO exit failed at the crashed price" \
    "unwrapForTao(uint256,uint256,uint256)" "$CRASH_TOKEN_ID" "$CRASH_SHARES" "$CRASH_MIN_OUT"
assert_payout_near_quote "$CRASH_PRE_WEI" "$(user_tao_wei)" "$CRASH_QUOTE" \
    "Price crash: TAO exit payout off quote"
[[ "$(vault_shares "$CRASH_TOKEN_ID")" == "0" ]] || fail "Price crash: shares not fully burned"
assert_le "$(vault_total_stake "$CRASH_TOKEN_ID")" "$ROUNDING_DUST_TOTAL_RAO" \
    "Price crash: stake left behind after the TAO exit"
ok "TAO exit paid out the devalued position in full"

# Deposits and alpha exits keep working at the crashed price.
floor_boundary "$CRASH_NETUID" "Price crash"
CRASH_RETRY=$(python3 -c "print($FLOOR_BOUNDARY * 3 // 2)")
deposit_and_wrap "$CRASH_NETUID" "$CRASH_HOTKEY" "$CRASH_HOTKEY_SS58" "$CRASH_RETRY" 1500000 \
    "Price crash: post-crash wrap failed"
CRASH_ASSETS=$(holder_assets "$CRASH_TOKEN_ID" "$WRAPPER_ADDR")
vault_send 2500000 "Price crash: post-crash unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$CRASH_TOKEN_ID" "$(vault_shares "$CRASH_TOKEN_ID")" "$WRAPPER_SUB_B32"
CRASH_DELIVERED=$(sum_stake "$WRAPPER_SUB_B32" "$CRASH_NETUID" "$CRASH_HOTKEY" "$CRASH_SELL_HOTKEY" "${ALL_HK_B32S[5]}")
assert_ge "$CRASH_DELIVERED" "$(python3 -c "print($CRASH_ASSETS * 98 // 100)")" \
    "Price crash: post-crash unwrap under-delivered"
ok "Post-crash round-trip clean: wrap accepted, unwrap delivered $CRASH_DELIVERED alpha RAO"

log "Scenario 3: a sub-floor co-holder cannot be locked in or leak the other holder"

PAIR_NETUID="${NETUIDS[2]}"
PAIR_TOKEN_ID="${VAULT_IDS[2]}"
PAIR_HOTKEY="${ALL_HK_B32S[6]}"
PAIR_HOTKEY_SS58="${ALL_HK_SS58S[6]}"
PAIR_SELL_HOTKEY="${ALL_HK_B32S[7]}"
PAIR_SELL_HOTKEY_SS58="${ALL_HK_SS58S[7]}"
HOLDER2_SUB_B32=$(h160_to_substrate_b32 "$HOLDER2_ADDR")

btcli_cmd wallet transfer --wallet-name "$ALICE_WALLET" --dest "$(h160_to_ss58 "$HOLDER2_ADDR")" \
    --amount 10 --allow-death --no-prompt 2>&1 | tail -1
ok "Funded holder 2 with 10 TAO for gas"

floor_boundary "$PAIR_NETUID" "Co-holder"
# The large holder's corrective moves (3x and 2x the boundary) land, so the position carries a
# real 50/30/20 split; the small holder sits just above the floor.
PAIR_LARGE=$(python3 -c "print($FLOOR_BOUNDARY * 10)")
PAIR_SMALL=$(python3 -c "print($FLOOR_BOUNDARY * 12 // 10)")
deposit_and_wrap "$PAIR_NETUID" "$PAIR_HOTKEY" "$PAIR_HOTKEY_SS58" "$PAIR_LARGE" 2500000 \
    "Co-holder: large wrap failed"
deposit_and_wrap "$PAIR_NETUID" "$PAIR_HOTKEY" "$PAIR_HOTKEY_SS58" "$PAIR_SMALL" 1500000 \
    "Co-holder: small wrap failed" "$HOLDER2_ADDR" "$HOLDER2_PK"
ok "Two holders wrapped: large $PAIR_LARGE, small $PAIR_SMALL alpha RAO"

HOLDER2_VALUE=$(alpha_value_tao "$PAIR_NETUID" "$(holder_assets "$PAIR_TOKEN_ID" "$HOLDER2_ADDR")")
HOLDER1_VALUE=$(alpha_value_tao "$PAIR_NETUID" "$(holder_assets "$PAIR_TOKEN_ID" "$WRAPPER_ADDR")")
# The large co-holder's stake deepens the pool, so a market sell can't move the price enough to
# devalue the small slice; raise the vault floor between the two holders instead (as the owner
# would to track a chain increase), which the large position dwarfs.
ORIGINAL_FLOOR=$FLOOR
RAISED_FLOOR=$(python3 -c "print($HOLDER2_VALUE * 3 // 2)")
assert_le "$((HOLDER2_VALUE + 1))" "$RAISED_FLOOR" "Co-holder: small slice not below the raised floor"
assert_le "$RAISED_FLOOR" "$HOLDER1_VALUE // 2 - 1" "Co-holder: split too narrow to raise the floor between the holders"
set_vault_floor "$RAISED_FLOOR" "Co-holder: raising the vault floor failed"
FLOOR=$RAISED_FLOOR
ok "Floor raised to $RAISED_FLOOR RAO: small holder ($HOLDER2_VALUE RAO) sub-floor, large holder ($HOLDER1_VALUE RAO) healthy"

# Both rails refuse the sub-floor slice: the chain cannot move or sell that little, and
# force-selling it would sweep value out of the co-holder's backing.
HOLDER2_SHARES=$(vault_shares "$PAIR_TOKEN_ID" "$HOLDER2_ADDR")
assert_vault_reverts_with_as "$HOLDER2_PK" "$HOLDER2_ADDR" "WithdrawTooSmall()" 1500000 \
    "Co-holder: sub-floor alpha exit did NOT revert as WithdrawTooSmall" \
    "unwrap(uint256,uint256,bytes32)" "$PAIR_TOKEN_ID" "$HOLDER2_SHARES" "$HOLDER2_SUB_B32"
assert_gas_within "$REVERT_GAS_BOUND" "Co-holder: alpha-exit refusal"
assert_vault_reverts_with_as "$HOLDER2_PK" "$HOLDER2_ADDR" "WithdrawTooSmall()" 2500000 \
    "Co-holder: sub-floor TAO exit did NOT revert as WithdrawTooSmall" \
    "unwrapForTao(uint256,uint256,uint256)" "$PAIR_TOKEN_ID" "$HOLDER2_SHARES" 1
assert_gas_within "$REVERT_GAS_BOUND" "Co-holder: TAO-exit refusal"
ok "Both exits refused the sub-floor slice cleanly"

HOLDER1_ASSETS_PRE=$(holder_assets "$PAIR_TOKEN_ID" "$WRAPPER_ADDR")

# Escape: topping up past the floor unlocks a full exit on the alpha rail.
floor_boundary "$PAIR_NETUID" "Co-holder"
PAIR_TOPUP=$(python3 -c "print($FLOOR_BOUNDARY * 2)")
deposit_and_wrap "$PAIR_NETUID" "$PAIR_HOTKEY" "$PAIR_HOTKEY_SS58" "$PAIR_TOPUP" 1500000 \
    "Co-holder: top-up wrap failed" "$HOLDER2_ADDR" "$HOLDER2_PK"
HOLDER2_ASSETS=$(holder_assets "$PAIR_TOKEN_ID" "$HOLDER2_ADDR")
vault_send_as "$HOLDER2_PK" 2500000 "Co-holder: post-top-up exit failed" \
    "unwrap(uint256,uint256,bytes32)" "$PAIR_TOKEN_ID" "$(vault_shares "$PAIR_TOKEN_ID" "$HOLDER2_ADDR")" "$HOLDER2_SUB_B32"
[[ "$(vault_shares "$PAIR_TOKEN_ID" "$HOLDER2_ADDR")" == "0" ]] \
    || fail "Co-holder: small holder shares not fully burned"
HOLDER2_DELIVERED=$(sum_stake "$HOLDER2_SUB_B32" "$PAIR_NETUID" "$PAIR_HOTKEY" "$PAIR_SELL_HOTKEY" "${ALL_HK_B32S[8]}")
assert_ge "$HOLDER2_DELIVERED" "$(python3 -c "print($HOLDER2_ASSETS * 98 // 100)")" \
    "Co-holder: top-up exit under-delivered"
ok "Top-up unlocked the alpha exit: small holder left in full ($HOLDER2_DELIVERED alpha RAO delivered)"

# The episode must not have cost the large holder anything.
HOLDER1_ASSETS_POST=$(holder_assets "$PAIR_TOKEN_ID" "$WRAPPER_ADDR")
assert_ge "$HOLDER1_ASSETS_POST" "$(python3 -c "print($HOLDER1_ASSETS_PRE - 100)")" \
    "Co-holder: large holder's backing shrank"

PAIR_QUOTE=$(alpha_to_tao_quote "$PAIR_NETUID" "$HOLDER1_ASSETS_POST")
PAIR_MIN_OUT=$(python3 -c "print($PAIR_QUOTE * 10**9 // 2)")
PAIR_PRE_WEI=$(user_tao_wei)
vault_send 2500000 "Co-holder: large holder's exit failed" \
    "unwrapForTao(uint256,uint256,uint256)" "$PAIR_TOKEN_ID" "$(vault_shares "$PAIR_TOKEN_ID")" "$PAIR_MIN_OUT"
assert_payout_near_quote "$PAIR_PRE_WEI" "$(user_tao_wei)" "$PAIR_QUOTE" \
    "Co-holder: large holder's payout off quote"
assert_le "$(vault_total_stake "$PAIR_TOKEN_ID")" "$ROUNDING_DUST_TOTAL_RAO" \
    "Co-holder: stake left behind after both holders exited"
ok "Large holder exited in full; vault position fully drained"
set_vault_floor "$ORIGINAL_FLOOR" "Co-holder: restoring the vault floor failed"

log "E2E (dust DoS) complete"
ok "Dust states refuse cheaply with designed errors; TAO exits, top-ups, and fresh deposits always clear them"
