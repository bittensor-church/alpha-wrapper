#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper — Local Chain E2E: min-stake floor handling
# ============================================================================
# Live-chain coverage of how the vault handles the chain's minimum-stake floor,
# in three scenarios:
#   1. Wrap enforces the floor at the exact boundary: a deposit one RAO below the
#      floor is rejected, a deposit exactly at the floor is accepted.
#   2. Sub-floor dust orphaned by a validator rotation is folded into the next
#      wrap and consolidated over the floor — nothing is forfeited.
#   3. A rebalance move that would land below the floor is skipped up front, so
#      the wrap stays within its gas budget; the drift clears on a later
#      above-floor deposit.
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

# Substrate coldkey a token's subnet clone stakes under, needed to read its on-chain stake.
clone_coldkey() { # <tokenId>
    local clone
    clone=$(cast call "$VAULT_ADDR" "subnetClone(uint256)(address)" "$1" --rpc-url "$RPC_URL")
    h160_to_substrate_b32 "$clone"
}

# Smallest alpha-RAO deposit whose TAO value clears the min-stake floor, from the live price.
# Sets FLOOR_PRICE and FLOOR_BOUNDARY; requires FLOOR to be set first.
floor_boundary() { # <netuid> <phase_label>
    local netuid="$1" phase="$2"
    FLOOR_PRICE=$(cast call "$ALPHA_PRECOMPILE" "getAlphaPrice(uint16)(uint256)" "$netuid" --rpc-url "$RPC_URL" | awk '{print $1}')
    [[ "$FLOOR_PRICE" != "0" ]] || fail "$phase: alpha price reads 0 (oracle unavailable)"
    FLOOR_BOUNDARY=$(python3 -c "print(($FLOOR * 10**18 + $FLOOR_PRICE - 1) // $FLOOR_PRICE)")
}

# gasUsed of the most recent vault_send, parsed from the shared receipt.
last_gas_used() {
    echo "$LAST_TX_RECEIPT" | python3 -c "
import json, sys
value = json.load(sys.stdin)['gasUsed']
print(value if isinstance(value, int) else int(str(value), 0))
" 2>/dev/null || echo 99999999
}

e2e_bootstrap

FLOOR=$(cast call "$VAULT_ADDR" "minStakeTaoFloor()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
info "minStakeTaoFloor = $FLOOR RAO"

log "Wrap enforces the stake floor at the exact boundary"

# The classifier's fixed-point floor must agree with the chain at the exact boundary. Compute the
# boundary alpha from the live price and prove wrap rejects one RAO below it and accepts exactly it
# — a live-chain-only check the unit mocks (fixed price) cannot provide.
FLOOR_NETUID="${NETUIDS[0]}"
FLOOR_HOTKEY="${ALL_HK_B32S[0]}"
FLOOR_HOTKEY_SS58="${ALL_HK_SS58S[0]}"
floor_boundary "$FLOOR_NETUID" "Floor boundary"
BOUNDARY_ALPHA=$FLOOR_BOUNDARY
BELOW_FLOOR_ALPHA=$((BOUNDARY_ALPHA - 1))
ok "Alpha price=$FLOOR_PRICE -> floor boundary=$BOUNDARY_ALPHA alpha RAO"

BOUNDARY_MAILBOX=$(mailbox_addr "$FLOOR_NETUID")
transfer_stake_py "$(h160_to_ss58 "$BOUNDARY_MAILBOX")" "$FLOOR_HOTKEY_SS58" "$FLOOR_NETUID" "$BELOW_FLOOR_ALPHA" | tail -1
vault_send_expect_revert 1500000 "Floor boundary: sub-floor wrap did NOT revert" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$FLOOR_NETUID" "$FLOOR_HOTKEY"
ok "wrap rejected a deposit just below the floor ($BELOW_FLOOR_ALPHA alpha RAO) as DepositTooSmall"

# Top the mailbox up to exactly the boundary; wrap must now succeed.
transfer_stake_py "$(h160_to_ss58 "$BOUNDARY_MAILBOX")" "$FLOOR_HOTKEY_SS58" "$FLOOR_NETUID" 1 | tail -1
vault_send 1500000 "Floor boundary: boundary wrap failed" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$FLOOR_NETUID" "$FLOOR_HOTKEY"
ok "wrap accepted exactly the floor boundary ($BOUNDARY_ALPHA alpha RAO)"
# A healthy first wrap (clone deploys + flush + skipped sub-floor moves) anchors the gas budget below.
WRAP_GAS_BASELINE=$(last_gas_used)
info "Healthy first-wrap gas baseline: $WRAP_GAS_BASELINE"

log "Rotated-out dust is consolidated by the next wrap"

# Park sub-floor dust under a soon-rotated hotkey. After rotation the next wrap flushes its fresh
# deposit first, seeding the roller so the whole pile (deposit + dust) rolls over the chain floor and
# the dust is consolidated in the same transaction — no keeper, no forfeiture.
DUST_NETUID="${NETUIDS[2]}"
DUST_TOKEN_ID="${VAULT_IDS[2]}"
DUST_HOTKEY="${ALL_HK_B32S[6]}"
ROTATED_IN_HOTKEY="${ALL_HK_B32S[7]}"
DUST_HOTKEY_SS58="${ALL_HK_SS58S[6]}"
ROTATED_IN_HOTKEY_SS58="${ALL_HK_SS58S[7]}"

# Single-validator set so the whole deposit lands on the dust hotkey.
set_validators_py "$DUST_NETUID" "$DUST_HOTKEY" "10000" > /dev/null
floor_boundary "$DUST_NETUID" "Dust consolidation"
DUST_PRICE=$FLOOR_PRICE
DUST_BOUNDARY=$FLOOR_BOUNDARY
DUST_DEPOSIT=$((DUST_BOUNDARY * 3))
deposit_and_wrap "$DUST_NETUID" "$DUST_HOTKEY" "$DUST_HOTKEY_SS58" "$DUST_DEPOSIT" 1500000 "Dust consolidation: wrap failed"

DUST_SHARES=$(vault_shares "$DUST_TOKEN_ID")
DUST_CLONE_COLDKEY=$(clone_coldkey "$DUST_TOKEN_ID")

# Burn 5/6 of the shares: delivers ~2.5x the boundary and leaves ~0.5x the boundary (sub-floor) dust.
DUST_BURN=$(python3 -c "print($DUST_SHARES * 5 // 6)")
vault_send 2500000 "Dust consolidation: partial unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$DUST_TOKEN_ID" "$DUST_BURN" "$WRAPPER_SUB_B32"
DUST_RESIDUE=$(get_stake "$DUST_HOTKEY" "$DUST_CLONE_COLDKEY" "$DUST_NETUID")
DUST_IS_SUBFLOOR=$(python3 -c "print('yes' if $DUST_RESIDUE * $DUST_PRICE // 10**18 < $FLOOR else 'no')")
[[ "$DUST_IS_SUBFLOOR" == "yes" ]] || fail "Dust consolidation: residual $DUST_RESIDUE is not sub-floor (price $DUST_PRICE)"
ok "Left sub-floor dust of $DUST_RESIDUE alpha RAO under the rotated-out hotkey"

# Rotate the dust hotkey out, the new one in, then wrap a fresh above-floor deposit on the new validator.
set_validators_py "$DUST_NETUID" "$ROTATED_IN_HOTKEY" "10000" > /dev/null
DUST_TOTAL_BEFORE=$(vault_total_stake "$DUST_TOKEN_ID")
deposit_and_wrap "$DUST_NETUID" "$ROTATED_IN_HOTKEY" "$ROTATED_IN_HOTKEY_SS58" "$DUST_DEPOSIT" 2500000 "Dust consolidation: consolidating wrap failed"

DUST_RESIDUE_POST=$(get_stake "$DUST_HOTKEY" "$DUST_CLONE_COLDKEY" "$DUST_NETUID")
[[ "$DUST_RESIDUE_POST" == "0" ]] || fail "Dust consolidation: rotated dust NOT consolidated (rotated-out hotkey still holds $DUST_RESIDUE_POST RAO)"
ok "Next wrap consolidated the rotated dust: rotated-out hotkey drained to 0"

# The snapshot no longer references the drained hotkey, and the backing folded in the fresh deposit
# plus the reclaimed dust (nothing forfeited).
DUST_LAST_SEEN=$(cast call "$VAULT_ADDR" "lastSeenHotkeys(uint256)(bytes32[3])" "$DUST_TOKEN_ID" --rpc-url "$RPC_URL")
if echo "$DUST_LAST_SEEN" | grep -qi "${DUST_HOTKEY#0x}"; then
    fail "Dust consolidation: consolidated hotkey still present in lastSeenHotkeys"
fi
DUST_TOTAL_AFTER=$(vault_total_stake "$DUST_TOKEN_ID")
CONSERVED=$(python3 -c "print('yes' if $DUST_TOTAL_AFTER >= $DUST_TOTAL_BEFORE + $DUST_DEPOSIT - 100 else 'no')")
[[ "$CONSERVED" == "yes" ]] || fail "Dust consolidation: backing did not fold in deposit + reclaimed dust ($DUST_TOTAL_AFTER)"
ok "Backing folded in the fresh deposit and the reclaimed dust; snapshot refreshed to the current set"

log "A sub-floor rebalance move is skipped, not attempted"

# A two-validator 50/50 split of a deposit worth between 1x and 2x the floor leaves a corrective
# move below the floor. The chain rejects such a move as an EVM error that consumes all forwarded
# gas, so attempting it would blow the fixed limit (or silently multiply the wrap's cost); the
# vault must skip it pre-call, complete in a normal gas envelope, and leave the split drifted.
SKIP_NETUID="${NETUIDS[1]}"
SKIP_TOKEN_ID="${VAULT_IDS[1]}"
OVER_HOTKEY="${ALL_HK_B32S[3]}"
UNDER_HOTKEY="${ALL_HK_B32S[4]}"
OVER_HOTKEY_SS58="${ALL_HK_SS58S[3]}"
set_validators_py "$SKIP_NETUID" "$OVER_HOTKEY,$UNDER_HOTKEY" "5000,5000" > /dev/null

floor_boundary "$SKIP_NETUID" "Sub-floor skip"
SKIP_BOUNDARY=$FLOOR_BOUNDARY
# 1.5x the boundary clears the deposit floor while both 50/50 halves stay below it.
SKIP_DEPOSIT=$(python3 -c "print($SKIP_BOUNDARY * 3 // 2)")
deposit_and_wrap "$SKIP_NETUID" "$OVER_HOTKEY" "$OVER_HOTKEY_SS58" "$SKIP_DEPOSIT" 1500000 \
    "Sub-floor skip: wrap with sub-floor residue failed (doomed move attempted?)"
SKIP_GAS_USED=$(last_gas_used)

SKIP_CLONE_COLDKEY=$(clone_coldkey "$SKIP_TOKEN_ID")
UNDER_HOTKEY_STAKE=$(get_stake "$UNDER_HOTKEY" "$SKIP_CLONE_COLDKEY" "$SKIP_NETUID")
[[ "$UNDER_HOTKEY_STAKE" == "0" ]] || fail "Sub-floor skip: sub-floor move was executed ($UNDER_HOTKEY_STAKE RAO moved)"
# Bound derived from the healthy first wrap so it tracks chain-side gas re-pricing; a doomed
# move burns toward the 1.5M limit, far past baseline + 25%.
SKIP_GAS_BOUND=$(python3 -c "print($WRAP_GAS_BASELINE * 5 // 4)")
python3 -c "import sys; sys.exit(0 if $SKIP_GAS_USED <= $SKIP_GAS_BOUND else 1)" \
    || fail "Sub-floor skip: wrap consumed $SKIP_GAS_USED gas (bound $SKIP_GAS_BOUND; doomed move burned the budget)"
ok "Sub-floor residue skipped: wrap used $SKIP_GAS_USED gas (bound $SKIP_GAS_BOUND), split left drifted"

# A later above-floor deposit produces a movable residual and clears the drift.
deposit_and_wrap "$SKIP_NETUID" "$OVER_HOTKEY" "$OVER_HOTKEY_SS58" "$((SKIP_BOUNDARY * 4))" 1500000 \
    "Sub-floor skip: follow-up wrap failed"
UNDER_HOTKEY_STAKE=$(get_stake "$UNDER_HOTKEY" "$SKIP_CLONE_COLDKEY" "$SKIP_NETUID")
[[ "$UNDER_HOTKEY_STAKE" != "0" ]] || fail "Sub-floor skip: drift did not clear on the follow-up deposit"
ok "Follow-up deposit cleared the drift: $UNDER_HOTKEY_STAKE RAO now on the second validator"

log "E2E (min-stake floor) complete"
ok "Min-stake floor enforced on wrap; rotated dust consolidated; sub-floor rebalance skipped in-budget"
