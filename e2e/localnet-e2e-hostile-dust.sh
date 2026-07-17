#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper - Local Chain E2E: hostile dust cannot stop the vault
# ============================================================================
# Tests that alpha planted around the vault by a third party - in a user's
# deposit mailbox and on the vault's own staking account - can never stop
# deposits or withdrawals, even after a rotation and a price drop turn the
# plant into sub-minimum dust the vault is forced to deal with:
#   - a withdrawal consolidates the planted dust and delivers in full,
#   - deposits keep working and ignore mailbox stake parked under other
#     validators,
#   - a mailbox plant too small to wrap is refused with a clear error and
#     folds into the user's next real deposit,
#   - every foreign coin ends up donated to the vault's holders, never the
#     other way around.
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

NETUID="${NETUIDS[0]}"
TOKEN_ID="${VAULT_IDS[0]}"
HOTKEY_A="${ALL_HK_B32S[0]}"
HOTKEY_A_SS58="${ALL_HK_SS58S[0]}"
HOTKEY_B="${ALL_HK_B32S[1]}"
HOTKEY_B_SS58="${ALL_HK_SS58S[1]}"
HOTKEY_C="${ALL_HK_B32S[2]}"
HOTKEY_C_SS58="${ALL_HK_SS58S[2]}"

log "Victim builds a normal position on the 50/30/20 set"

# A fresh validator to take hotkey C's slot after the rotation.
register_hotkey "$NETUID" "hk_e2e_1d"
ROTATED_IN_HOTKEY="$REGISTERED_HK_B32"
ok "Registered replacement validator ${ROTATED_IN_HOTKEY:0:18}... on netuid $NETUID"

floor_boundary "$NETUID" "Hostile dust"
# 4.5x the boundary: the corrective move to B (1.35x) lands while the move to C (0.9x) is
# floor-skipped, so C sits at zero while still in the set - a common drifted split.
VICTIM_DEPOSIT=$(python3 -c "print($FLOOR_BOUNDARY * 9 // 2)")
deposit_and_wrap "$NETUID" "$HOTKEY_A" "$HOTKEY_A_SS58" "$VICTIM_DEPOSIT" 1500000 \
    "Hostile dust: victim wrap failed"
assert_gas_within "$WRAP_GAS_BOUND" "Hostile dust: victim wrap"
CLONE_COLDKEY=$(clone_coldkey "$TOKEN_ID")
[[ "$(get_stake "$HOTKEY_C" "$CLONE_COLDKEY" "$NETUID")" == "0" ]] \
    || fail "Hostile dust: expected the C slot to sit at zero after the floor-skipped move"
ok "Victim position split across A and B; C at zero via the floor-skipped move"

log "Attacker plants the smallest stake the chain allows"

# The chain floors every transfer, so the smallest plantable stake is floor-sized; 1.2x leaves
# margin. One plant goes into the victim's mailbox under B, one onto the vault's own staking
# account under C.
PLANT=$(python3 -c "print($FLOOR_BOUNDARY * 12 // 10)")
VICTIM_MAILBOX=$(mailbox_addr "$NETUID")
MAILBOX_COLDKEY=$(h160_to_substrate_b32 "$VICTIM_MAILBOX")
transfer_stake_py "$(h160_to_ss58 "$VICTIM_MAILBOX")" "$HOTKEY_B_SS58" "$NETUID" "$PLANT" | tail -1
transfer_stake_py "$(h160_to_ss58 "$(clone_addr "$TOKEN_ID")")" "$HOTKEY_C_SS58" "$NETUID" "$PLANT" | tail -1
ok "Planted $PLANT alpha RAO in the victim's mailbox (under B) and on the clone (under C)"

# Rotate C out, then push the price down: the clone plant becomes sub-floor foreign rotated-out stake the
# vault must consolidate, and the mailbox plant becomes too small to wrap on its own.
set_validators_py "$NETUID" "$HOTKEY_A,$HOTKEY_B,$ROTATED_IN_HOTKEY" "5000,3000,2000" > /dev/null
crash_price_until_below "$NETUID" "$HOTKEY_A" "$HOTKEY_A_SS58" "$PLANT" $((FLOOR * 8 / 10)) "Hostile dust"
PLANT_VALUE=$(alpha_value_tao "$NETUID" "$(get_stake "$HOTKEY_C" "$CLONE_COLDKEY" "$NETUID")")
RICHEST_SLOT_VALUE=$(alpha_value_tao "$NETUID" "$(get_stake "$HOTKEY_A" "$CLONE_COLDKEY" "$NETUID")")
python3 -c "import sys; sys.exit(0 if $PLANT_VALUE < $FLOOR and $RICHEST_SLOT_VALUE > $FLOOR else 1)" \
    || fail "Hostile dust: bad crash split (plant $PLANT_VALUE, richest slot $RICHEST_SLOT_VALUE, floor $FLOOR)"
ok "Rotated-out C now holds sub-floor foreign stake ($PLANT_VALUE RAO); victim's slot stays healthy"

log "Victim withdrawal consolidates the hostile plant and delivers in full"

# One transaction must start the roll from the richest slot (not the plant), absorb it,
# refresh the remembered set, gather across slots, and deliver. A roll started from the plant would be
# rejected by the chain at full forwarded-gas cost - the exact regression this leg pins.
TOTAL_PRE=$(vault_total_stake "$TOKEN_ID")
ASSETS_PRE=$(holder_assets "$TOKEN_ID" "$WRAPPER_ADDR")
UNWRAP_BURN=$(python3 -c "print($(vault_shares "$TOKEN_ID") * 9 // 10)")
vault_send 2500000 "Hostile dust: withdrawal over the hostile plant failed" \
    "unwrap(uint256,uint256,bytes32)" "$TOKEN_ID" "$UNWRAP_BURN" "$WRAPPER_SUB_B32"
assert_gas_within "$UNWRAP_GAS_BOUND" "Hostile dust: withdrawal over the hostile plant"
DELIVERED_FIRST=$(sum_stake "$WRAPPER_SUB_B32" "$NETUID" "$HOTKEY_A" "$HOTKEY_B" "$HOTKEY_C" "$ROTATED_IN_HOTKEY")
assert_ge "$DELIVERED_FIRST" "$(python3 -c "print($ASSETS_PRE * 9 // 10 * 98 // 100)")" \
    "Hostile dust: withdrawal under-delivered"
assert_le "$(get_stake "$HOTKEY_C" "$CLONE_COLDKEY" "$NETUID")" "$ROUNDING_DUST_SLOT_RAO" \
    "Hostile dust: hostile plant not consolidated"
if cast call "$VAULT_ADDR" "lastSeenHotkeys(uint256)(bytes32[])" "$TOKEN_ID" --rpc-url "$RPC_URL" \
    | grep -qi "${HOTKEY_C#0x}"; then
    fail "Hostile dust: consolidated hotkey still present in lastSeenHotkeys"
fi
TOTAL_POST=$(vault_total_stake "$TOKEN_ID")
assert_ge "$TOTAL_POST" "$(python3 -c "print($TOTAL_PRE - $DELIVERED_FIRST - 100)")" \
    "Hostile dust: backing lost while absorbing the plant"
ok "Withdrawal delivered $DELIVERED_FIRST alpha RAO and absorbed the plant as a holder donation"

# The remaining slice is sub-floor: the alpha rail refuses it cheaply (the TAO rail and top-ups
# remain, as covered by the dust-DoS scenarios).
assert_vault_reverts_with "WithdrawTooSmall()" 1500000 \
    "Hostile dust: sub-floor remainder did NOT revert as WithdrawTooSmall" \
    "unwrap(uint256,uint256,bytes32)" "$TOKEN_ID" "$(vault_shares "$TOKEN_ID")" "$WRAPPER_SUB_B32"
assert_gas_within "$REVERT_GAS_BOUND" "Hostile dust: sub-floor remainder refusal"
ok "Sub-floor remainder refused up front on the alpha rail"

log "Deposits keep working and the mailbox plant stays inert"

# A wrap under A must ignore the mailbox stake parked under B: mailbox accounting is per-hotkey.
MAILBOX_PLANT_BEFORE=$(get_stake "$HOTKEY_B" "$MAILBOX_COLDKEY" "$NETUID")
floor_boundary "$NETUID" "Hostile dust"
FRESH_DEPOSIT=$(python3 -c "print($FLOOR_BOUNDARY * 3 // 2)")
deposit_and_wrap "$NETUID" "$HOTKEY_A" "$HOTKEY_A_SS58" "$FRESH_DEPOSIT" 1500000 \
    "Hostile dust: wrap alongside the mailbox plant failed"
assert_gas_within "$WRAP_GAS_BOUND" "Hostile dust: wrap alongside the mailbox plant"
assert_ge "$(get_stake "$HOTKEY_B" "$MAILBOX_COLDKEY" "$NETUID")" "$MAILBOX_PLANT_BEFORE" \
    "Hostile dust: wrap under A touched the mailbox plant under B"
ok "Wrap under A succeeded and left the mailbox plant under B untouched"

# On its own the devalued plant is too small to wrap; refused with the designed error, cheaply.
assert_vault_reverts_with "DepositTooSmall()" 1500000 \
    "Hostile dust: sub-floor mailbox plant did NOT revert as DepositTooSmall" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$NETUID" "$HOTKEY_B"
assert_gas_within "$REVERT_GAS_BOUND" "Hostile dust: sub-floor mailbox wrap refusal"
ok "Wrapping only the sub-floor mailbox plant refused as DepositTooSmall"

# A real deposit under B folds the plant in: the victim gains it, and the mailbox drains.
deposit_and_wrap "$NETUID" "$HOTKEY_B" "$HOTKEY_B_SS58" "$FRESH_DEPOSIT" 1500000 \
    "Hostile dust: wrap merging the mailbox plant failed"
assert_gas_within "$WRAP_GAS_BOUND" "Hostile dust: wrap merging the mailbox plant"
assert_le "$(get_stake "$HOTKEY_B" "$MAILBOX_COLDKEY" "$NETUID")" "$ROUNDING_DUST_SLOT_RAO" \
    "Hostile dust: mailbox plant not folded into the real deposit"
ok "Real deposit under B absorbed the mailbox plant into the victim's position"

log "Full exit leaves nothing behind"

ASSETS_FINAL=$(holder_assets "$TOKEN_ID" "$WRAPPER_ADDR")
vault_send 2500000 "Hostile dust: final exit failed" \
    "unwrap(uint256,uint256,bytes32)" "$TOKEN_ID" "$(vault_shares "$TOKEN_ID")" "$WRAPPER_SUB_B32"
assert_gas_within "$UNWRAP_GAS_BOUND" "Hostile dust: final exit"
DELIVERED_TOTAL=$(sum_stake "$WRAPPER_SUB_B32" "$NETUID" "$HOTKEY_A" "$HOTKEY_B" "$HOTKEY_C" "$ROTATED_IN_HOTKEY")
assert_ge "$(python3 -c "print($DELIVERED_TOTAL - $DELIVERED_FIRST)")" \
    "$(python3 -c "print($ASSETS_FINAL * 98 // 100)")" "Hostile dust: final exit under-delivered"
[[ "$(vault_shares "$TOKEN_ID")" == "0" ]] || fail "Hostile dust: shares not fully burned"
assert_le "$(vault_total_stake "$TOKEN_ID")" "$ROUNDING_DUST_TOTAL_RAO" \
    "Hostile dust: stake left behind after the full exit"
ok "Victim exited in full, including both absorbed plants"

log "E2E (hostile dust) complete"
ok "Foreign stake anywhere around the vault is ignored or donated - never a way to stop wraps or unwraps"
