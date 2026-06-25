#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper — Local Chain End-to-End Test
# ============================================================================
#
# Prerequisites:
#   - Local subtensor running at ws://127.0.0.1:9944
#   - btcli installed with Alice wallet (hotkey "default")
#   - forge/cast installed
#   - python3 with substrate-interface
#   - Funded EVM deployer (see DEPLOYER below)
#
# Flow:
#   0. Fund deployer EVM account (10k TAO from Alice)
#   1. Create 3 subnets (Alice) + start emissions
#   2. Create 3 hotkeys per subnet, register as validators
#   3. Alice stakes TAO into each subnet (ratio 3:2:1)
#   4. Deploy contracts (DepositMailbox, SubnetClone, AlphaVault, ValidatorRegistry)
#   5. Fund user EVM account
#   6. Alice transferStakes alpha → clone addresses (substrate-interface)
#   7. wrap → mint ERC1155 shares
#   8. Verify deposit balances
#   9. Unwrap all shares → verify alpha returned to user's substrate coldkey
#  10. Observability scripts → verify event-derived state
#  11. Reclaim mailbox alpha for TAO → verify user receives native TAO
#  12. Unwrap shares for TAO → verify user receives native TAO
#  13. Emission accrual → position appreciates above deposit; holder unwraps the gain
#  14. Validator rotation orphans stake → unwrap sweeps it (no funds stranded)
#  15. unwrapForTao slippage guard against the real alpha→TAO price
#
# Phases 0-5 (chain bootstrap, contract deployment, account funding) plus the
# shared config and helpers live in scripts/e2e_common.sh; this script drives
# the wrap/unwrap scenario (phases 6-15) on top of that bootstrap.
#
# Usage:
#   chmod +x scripts/localnet-e2e.sh
#   ./scripts/localnet-e2e.sh
# ============================================================================

# Arm errexit before the source runs so a missing/failed library aborts immediately
# (e2e_common.sh re-sets this; the duplicate is harmless).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

e2e_bootstrap

log "Phase 6: Transfer alpha to clone addresses (split across 3 validators)"

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    CLONE_ADDR=$(mailbox_addr "$NET")
    ok "netuid $NET clone: $CLONE_ADDR"

    CLONE_SUB=$(h160_to_substrate_b32 "$CLONE_ADDR")
    CLONE_SS58=$(h160_to_ss58 "$CLONE_ADDR")
    ok "Clone SS58: $CLONE_SS58"

    for j in 0 1 2; do
        IDX=$((i * 3 + j))
        HK_SS58="${ALL_HK_SS58S[$IDX]}"
        HK_B32="${ALL_HK_B32S[$IDX]}"

        echo "  Transferring $PER_HOTKEY_RAW RAO on netuid $NET under ${HK_B32:0:18}... to clone"
        transfer_stake_py "$CLONE_SS58" "$HK_SS58" "$NET" "$PER_HOTKEY_RAW" | tail -1

        CLONE_STAKE=$(get_stake "$HK_B32" "$CLONE_SUB" "$NET")
        [[ "$CLONE_STAKE" == "0" ]] && fail "Clone $CLONE_ADDR has 0 alpha under ${HK_B32:0:18}... after transfer"
        ok "Clone stake under ${HK_B32:0:18}...: $CLONE_STAKE RAO"
    done
done

log "Phase 7: Process deposits (one per validator)"

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    for j in 0 1 2; do
        IDX=$((i * 3 + j))
        CHOSEN_HK="${ALL_HK_B32S[$IDX]}"

        vault_send 1000000 "wrap for netuid $NET, hotkey ${CHOSEN_HK:0:18}... failed" \
            "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$NET" "$CHOSEN_HK"
        ok "netuid $NET deposited under ${CHOSEN_HK:0:18}..."
    done
done

log "Phase 8: Verify deposits"

SHARES_CACHE=()
DEPOSIT_TOTALS=()

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    TID="${VAULT_IDS[$i]}"
    SHARES=$(vault_shares "$TID")
    TOTAL=$(vault_total_stake "$TID")
    PRICE=$(cast call "$VAULT_ADDR" "sharePrice(uint256)(uint256)" "$TID" --rpc-url "$RPC_URL" | awk '{print $1}')

    echo "  netuid $NET (tokenId $TID):"
    echo "    shares:     $SHARES"
    echo "    totalStake: $TOTAL RAO"
    echo "    sharePrice: $PRICE"

    [[ "$SHARES" == "0" ]] && fail "netuid $NET: zero shares after wrap"
    [[ "$TOTAL"  == "0" ]] && fail "netuid $NET: zero totalStake after wrap"
    [[ "$PRICE"  == "0" ]] && fail "netuid $NET: zero sharePrice after wrap"

    SHARES_CACHE+=("$SHARES")
    DEPOSIT_TOTALS+=("$TOTAL")
done
ok "All 3 vaults have positive shares / totalStake / sharePrice"

log "Phase 9: Unwrap all shares → verify alpha returned"

TOLERANCE_RAO=10

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    TID="${VAULT_IDS[$i]}"
    SHARES="${SHARES_CACHE[$i]}"
    DEPOSITED="${DEPOSIT_TOTALS[$i]}"

    info "netuid $NET: burning $SHARES shares (tokenId $TID)"

    vault_send 2000000 "unwrap for netuid $NET failed" \
        "unwrap(uint256,uint256,bytes32)" "$TID" "$SHARES" "$WRAPPER_SUB_B32"

    POST_SHARES=$(vault_shares "$TID")
    [[ "$POST_SHARES" != "0" ]] && fail "netuid $NET: shares still $POST_SHARES after full unwrap"
    ok "netuid $NET: shares burned"

    SUM=$(sum_stake "$WRAPPER_SUB_B32" "$NET" \
        "${ALL_HK_B32S[$((i * 3))]}" "${ALL_HK_B32S[$((i * 3 + 1))]}" "${ALL_HK_B32S[$((i * 3 + 2))]}")

    OK_RETURNED=$(python3 -c "print('yes' if $SUM >= max(0, $DEPOSITED - $TOLERANCE_RAO) else 'no')")
    if [[ "$OK_RETURNED" != "yes" ]]; then
        fail "netuid $NET: user only received $SUM RAO across 3 hotkeys; expected ≥ $((DEPOSITED - TOLERANCE_RAO))"
    fi
    ok "netuid $NET: user received $SUM RAO (deposited $DEPOSITED, tolerance ${TOLERANCE_RAO})"
done

log "Phase 10: Observability scripts"

BLOCK_END=$(cast block-number --rpc-url "$RPC_URL")
info "Block range: [$BLOCK_START, $BLOCK_END]"

SUBNET_COUNT=${#NETUIDS[@]}
VAULT_IDS_CSV=$(IFS=,; echo "${VAULT_IDS[*]}")
NETUIDS_CSV=$(IFS=,; echo "${NETUIDS[*]}")

# verify_script <label> <verify_csv args...> -- <script command...>
# Pipes the script's CSV stdout through scripts/verify_csv.py with the verify args.
# Fails the e2e on the first invariant violation.
verify_script() {
    local label="$1"; shift
    local v_args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do v_args+=("$1"); shift; done
    [[ "$1" == "--" ]] && shift
    "$@" | python3 scripts/verify_csv.py "${v_args[@]}"
    ok "$label"
}

verify_script "get_subnet_proxies" \
    --rows "$SUBNET_COUNT" \
    --column-set "token_id=$VAULT_IDS_CSV" \
    -- python3 scripts/get_subnet_proxies.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

verify_script "get_deposits" \
    --rows $((SUBNET_COUNT * 3)) \
    --column-set "token_id=$VAULT_IDS_CSV" \
    --column-eq "user=$WRAPPER_ADDR" \
    --column-positive assets \
    --column-positive shares \
    -- python3 scripts/get_deposits.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

verify_script "get_unwraps" \
    --rows "$SUBNET_COUNT" \
    --column-set "token_id=$VAULT_IDS_CSV" \
    --column-eq "user=$WRAPPER_ADDR" \
    --column-positive assets \
    --column-positive shares \
    -- python3 scripts/get_unwraps.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

# Per-netuid: 0 or 1 emission depending on whether post-drain leftover (emissions
# accrued between deposit and unwrap) clears `minRebalanceAmt`. Assert membership only.
verify_script "get_rebalances" \
    --column-subset "token_id=$VAULT_IDS_CSV" \
    --column-positive amount \
    -- python3 scripts/get_rebalances.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

verify_script "get_validator_updates" \
    --rows "$SUBNET_COUNT" \
    --column-set "netuid=$NETUIDS_CSV" \
    --column-eq "count=3" \
    --column-positive timestamp \
    -- python3 scripts/get_validator_updates.py \
        --rpc-url "$RPC_URL" --registry-address "$VAL_REGISTRY_ADDR" \
        --block-start "$REG_BLOCK_START" --block-end "$REG_BLOCK_END"

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    TID="${VAULT_IDS[$i]}"

    verify_script "get_volumes (netuid $NET)" \
        --rows 1 \
        --column-eq "token_id=$TID" \
        --column-eq "user=" \
        --column-eq "deposit_count=3" \
        --column-eq "unwrap_count=1" \
        --column-positive total_assets_in \
        --column-positive total_shares_minted \
        --column-positive total_assets_out \
        --column-positive total_shares_burned \
        -- python3 scripts/get_volumes.py \
            --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
            --block-start "$BLOCK_START" --block-end "$BLOCK_END" --netuid "$NET"

    verify_script "get_volumes (netuid $NET / wrapper)" \
        --rows 1 \
        --column-eq "token_id=$TID" \
        --column-eq "user=$WRAPPER_ADDR" \
        --column-eq "deposit_count=3" \
        --column-eq "unwrap_count=1" \
        -- python3 scripts/get_volumes.py \
            --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
            --block-start "$BLOCK_START" --block-end "$BLOCK_END" \
            --netuid "$NET" --user "$WRAPPER_ADDR"

    verify_script "get_vault_state (netuid $NET)" \
        --rows 1 \
        --column-eq "token_id=$TID" \
        --column-eq "total_supply=0" \
        --column-eq "share_price=" \
        --column-eq "share_price_error=NoSharesOutstanding" \
        --column-eq "validators_count=3" \
        -- python3 scripts/get_vault_state.py \
            --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
            --registry-address "$VAL_REGISTRY_ADDR" --netuid "$NET"
done

log "Phase 11: Reclaim mailbox alpha as TAO"

RECLAIM_NET="${NETUIDS[0]}"
RECLAIM_HK_IDX=0
RECLAIM_HK_B32="${ALL_HK_B32S[$RECLAIM_HK_IDX]}"
RECLAIM_HK_SS58="${ALL_HK_SS58S[$RECLAIM_HK_IDX]}"

RECLAIM_MAILBOX=$(mailbox_addr "$RECLAIM_NET")
RECLAIM_MAILBOX_SUB=$(h160_to_substrate_b32 "$RECLAIM_MAILBOX")
RECLAIM_MAILBOX_SS58=$(h160_to_ss58 "$RECLAIM_MAILBOX")
info "User mailbox on netuid $RECLAIM_NET: $RECLAIM_MAILBOX"

info "Transferring $PER_HOTKEY_RAW RAO from Alice → mailbox under ${RECLAIM_HK_B32:0:18}..."
transfer_stake_py "$RECLAIM_MAILBOX_SS58" "$RECLAIM_HK_SS58" "$RECLAIM_NET" "$PER_HOTKEY_RAW" | tail -1

MAILBOX_ALPHA_PRE=$(get_stake "$RECLAIM_HK_B32" "$RECLAIM_MAILBOX_SUB" "$RECLAIM_NET")
[[ "$MAILBOX_ALPHA_PRE" -gt 0 ]] || fail "mailbox has zero alpha before reclaim"
ok "Mailbox stake before: $MAILBOX_ALPHA_PRE RAO"

USER_TAO_PRE=$(user_tao_wei)
info "User EVM balance before: $USER_TAO_PRE wei"

vault_send 1500000 "reclaimMailboxAlphaAsTao failed" \
    "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)" "$RECLAIM_NET" "$RECLAIM_HK_B32" 0

MAILBOX_ALPHA_POST=$(get_stake "$RECLAIM_HK_B32" "$RECLAIM_MAILBOX_SUB" "$RECLAIM_NET")
[[ "$MAILBOX_ALPHA_POST" == "0" ]] || fail "mailbox still holds $MAILBOX_ALPHA_POST RAO after reclaim"
ok "Mailbox alpha drained to 0"

USER_TAO_POST=$(user_tao_wei)
info "User EVM balance after:  $USER_TAO_POST wei"
GAINED=$(assert_gain "$USER_TAO_PRE" "$USER_TAO_POST" "user did not gain TAO from reclaim")
ok "User gained $GAINED wei (net of gas)"

log "Phase 12: Unwrap shares for TAO"

WFT_NET="${NETUIDS[1]}"
WFT_TID="${VAULT_IDS[1]}"
WFT_HK_IDX=3
WFT_HK_B32="${ALL_HK_B32S[$WFT_HK_IDX]}"
WFT_HK_SS58="${ALL_HK_SS58S[$WFT_HK_IDX]}"

WFT_MAILBOX=$(mailbox_addr "$WFT_NET")
info "User mailbox on netuid $WFT_NET: $WFT_MAILBOX"

deposit_and_wrap "$WFT_NET" "$WFT_HK_B32" "$WFT_HK_SS58" "$PER_HOTKEY_RAW" 1500000 \
    "wrap for unwrapForTao setup failed"

WFT_SHARES=$(vault_shares "$WFT_TID")
[[ "$WFT_SHARES" != "0" ]] || fail "no shares minted by wrap on netuid $WFT_NET"
ok "Minted shares: $WFT_SHARES"

USER_TAO_PRE=$(user_tao_wei)
info "User EVM balance before: $USER_TAO_PRE wei"

vault_send 2500000 "unwrapForTao failed" \
    "unwrapForTao(uint256,uint256,uint256)" "$WFT_TID" "$WFT_SHARES" 0

WFT_SHARES_POST=$(vault_shares "$WFT_TID")
[[ "$WFT_SHARES_POST" == "0" ]] || fail "shares still $WFT_SHARES_POST after unwrapForTao"
ok "Shares burned to 0"

USER_TAO_POST=$(user_tao_wei)
info "User EVM balance after:  $USER_TAO_POST wei"
GAINED=$(assert_gain "$USER_TAO_PRE" "$USER_TAO_POST" "user did not gain TAO from unwrapForTao")
ok "User gained $GAINED wei (net of gas)"

log "Phase 13: Emission accrual → share-price appreciation (alpha rail)"

# Real emissions accrue on the clone's staked alpha over blocks: the position must appreciate
# above the deposit, and the holder must be able to unwrap that gain. Mocks fake emissions,
# so only a live chain exercises this core value-accrual property.
EMIT_NET="${NETUIDS[0]}"
EMIT_TID="${VAULT_IDS[0]}"
EMIT_HKS=("${ALL_HK_B32S[0]}" "${ALL_HK_B32S[1]}" "${ALL_HK_B32S[2]}")

deposit_and_wrap "$EMIT_NET" "${ALL_HK_B32S[0]}" "${ALL_HK_SS58S[0]}" 50000000000 1500000 "Phase 13 wrap failed"

EMIT_SHARES=$(vault_shares "$EMIT_TID")
EMIT_DEPOSITED=$(vault_total_stake "$EMIT_TID")
[[ "$EMIT_SHARES" != "0" ]] || fail "Phase 13: no shares minted"
ok "Deposited 50 alpha → shares=$EMIT_SHARES, deposit-synced totalStake=$EMIT_DEPOSITED RAO"

info "Waiting ~30 blocks for emissions to accrue..."
EMIT_TARGET=$(( $(cast block-number --rpc-url "$RPC_URL") + 30 ))
while [[ $(cast block-number --rpc-url "$RPC_URL") -lt "$EMIT_TARGET" ]]; do
    python3 -c "import time; time.sleep(1)"
done

EMIT_PREVIEW=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" "$EMIT_TID" "$EMIT_SHARES" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
APPRECIATED=$(python3 -c "print('yes' if $EMIT_PREVIEW > $EMIT_DEPOSITED else 'no')")
[[ "$APPRECIATED" == "yes" ]] || fail "Phase 13: no appreciation (previewUnwrap $EMIT_PREVIEW ≤ deposit $EMIT_DEPOSITED)"
ok "previewUnwrap rose to $EMIT_PREVIEW RAO (> deposit $EMIT_DEPOSITED) — emissions accrued on-chain"

# Sum the user's coldkey stake across the validators before and after, so the payout is the delta.
EMIT_BEFORE=$(sum_stake "$WRAPPER_SUB_B32" "$EMIT_NET" "${EMIT_HKS[@]}")

vault_send 2000000 "Phase 13 unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$EMIT_TID" "$EMIT_SHARES" "$WRAPPER_SUB_B32"

EMIT_AFTER=$(sum_stake "$WRAPPER_SUB_B32" "$EMIT_NET" "${EMIT_HKS[@]}")
EMIT_RECEIVED=$((EMIT_AFTER - EMIT_BEFORE))
CAPTURED=$(python3 -c "print('yes' if $EMIT_RECEIVED > $EMIT_DEPOSITED else 'no')")
[[ "$CAPTURED" == "yes" ]] || fail "Phase 13: emissions not captured (received $EMIT_RECEIVED ≤ deposit $EMIT_DEPOSITED)"
ok "User unwrapped $EMIT_RECEIVED RAO > deposited $EMIT_DEPOSITED — appreciation captured on the alpha rail"

log "Phase 14: Validator rotation orphans stake → unwrap sweeps it (no funds stranded)"

# Rotating a validator out of the registry strands the clone's stake under it. The next unwrap
# must sweep that orphan (real moveStake) and still pay the holder full value — a live-chain-only
# check of the rotation/sweep path against real staking mechanics and the minRebalanceAmt floor.
ROT_NET="${NETUIDS[1]}"
ROT_TID="${VAULT_IDS[1]}"
ROT_HK0="${ALL_HK_B32S[3]}"
ROT_HK1="${ALL_HK_B32S[4]}"
ROT_HK2="${ALL_HK_B32S[5]}"

deposit_and_wrap "$ROT_NET" "$ROT_HK0" "${ALL_HK_SS58S[3]}" 60000000000 1500000 "Phase 14 wrap failed"

ROT_SHARES=$(vault_shares "$ROT_TID")
ROT_DEPOSITED=$(vault_total_stake "$ROT_TID")
ROT_CLONE=$(cast call "$VAULT_ADDR" "subnetClone(uint256)(address)" "$ROT_TID" --rpc-url "$RPC_URL")
ROT_CLONE_SUB=$(h160_to_substrate_b32 "$ROT_CLONE")
ROT_ORPHAN=$(get_stake "$ROT_HK2" "$ROT_CLONE_SUB" "$ROT_NET")
[[ "$ROT_ORPHAN" != "0" ]] || fail "Phase 14: no stake under the 3rd validator to orphan"
ok "Deposited 60 alpha → shares=$ROT_SHARES; clone holds $ROT_ORPHAN RAO under the soon-orphaned 3rd validator"

# Drop the 3rd validator from the registry via a real EIP-712 attestation; no vault call runs,
# so the vault's last-seen snapshot still references it and its stake becomes an orphan.
set_validators_py "$ROT_NET" "$ROT_HK0,$ROT_HK1" "6000,4000" > /dev/null
ok "Rotated registry → [v0, v1]; 3rd validator dropped with $ROT_ORPHAN RAO orphaned"

ROT_BEFORE=$(sum_stake "$WRAPPER_SUB_B32" "$ROT_NET" "$ROT_HK0" "$ROT_HK1" "$ROT_HK2")

vault_send 2000000 "Phase 14 unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$ROT_TID" "$ROT_SHARES" "$WRAPPER_SUB_B32"

ROT_AFTER=$(sum_stake "$WRAPPER_SUB_B32" "$ROT_NET" "$ROT_HK0" "$ROT_HK1" "$ROT_HK2")
ROT_RECEIVED=$((ROT_AFTER - ROT_BEFORE))
ROT_ORPHAN_POST=$(get_stake "$ROT_HK2" "$ROT_CLONE_SUB" "$ROT_NET")

# The sweep adds extra moveStake/drain ops, each losing ≤1 RAO to integer rounding
# (Phase 9's simpler single unwrap uses TOLERANCE_RAO=10).
SWEPT=$(python3 -c "print('yes' if $ROT_RECEIVED >= $ROT_DEPOSITED - 100 else 'no')")
[[ "$SWEPT" == "yes" ]] || fail "Phase 14: orphan not swept (received $ROT_RECEIVED << deposit $ROT_DEPOSITED)"
[[ "$ROT_ORPHAN_POST" == "0" ]] || fail "Phase 14: orphan NOT swept (3rd validator still holds $ROT_ORPHAN_POST RAO)"
ok "Orphan swept; user received $ROT_RECEIVED RAO (≈ deposit $ROT_DEPOSITED), orphaned validator drained to 0"

log "Phase 15: unwrapForTao slippage guard against the real alpha→TAO price"

# minTaoOut must reject a payout below the threshold against the REAL realized price (mocks use a
# fixed configurable rate). An unsatisfiable minTaoOut reverts with shares intact; minTaoOut=0 pays.
SLIP_NET="${NETUIDS[2]}"
SLIP_TID="${VAULT_IDS[2]}"

deposit_and_wrap "$SLIP_NET" "${ALL_HK_B32S[6]}" "${ALL_HK_SS58S[6]}" 40000000000 1500000 "Phase 15 wrap failed"

SLIP_SHARES=$(vault_shares "$SLIP_TID")
[[ "$SLIP_SHARES" != "0" ]] || fail "Phase 15: no shares minted"
ok "Deposited 40 alpha → shares=$SLIP_SHARES"

# An unsatisfiable minTaoOut (1e30 wei) must revert and leave the shares untouched.
vault_send_expect_revert 2500000 "Phase 15: unwrapForTao with minTaoOut=1e30 did NOT revert" \
    "unwrapForTao(uint256,uint256,uint256)" "$SLIP_TID" "$SLIP_SHARES" 1000000000000000000000000000000
SLIP_SHARES_AFTER=$(vault_shares "$SLIP_TID")
[[ "$SLIP_SHARES_AFTER" == "$SLIP_SHARES" ]] || fail "Phase 15: shares changed after a reverted unwrapForTao ($SLIP_SHARES → $SLIP_SHARES_AFTER)"
ok "Slippage guard rejected an unsatisfiable minTaoOut; shares preserved ($SLIP_SHARES)"

# minTaoOut=0 succeeds against the real realized price; the user gains native TAO.
SLIP_TAO_PRE=$(user_tao_wei)
vault_send 2500000 "Phase 15 unwrapForTao(minTaoOut=0) failed" \
    "unwrapForTao(uint256,uint256,uint256)" "$SLIP_TID" "$SLIP_SHARES" 0
SLIP_SHARES_FINAL=$(vault_shares "$SLIP_TID")
[[ "$SLIP_SHARES_FINAL" == "0" ]] || fail "Phase 15: shares not burned ($SLIP_SHARES_FINAL)"
SLIP_TAO_POST=$(user_tao_wei)
SLIP_GAINED=$(assert_gain "$SLIP_TAO_PRE" "$SLIP_TAO_POST" "Phase 15: user did not gain TAO")
ok "minTaoOut=0 paid $SLIP_GAINED wei net of gas against the real price; shares burned to 0"

log "E2E complete"
echo "  AlphaVault:        $VAULT_ADDR"
echo "  DepositMailbox:    $MAILBOX_ADDR"
echo "  SubnetClone:       $SUBNET_CLONE_ADDR"
echo "  ValidatorRegistry: $VAL_REGISTRY_ADDR"
echo "  Subnets:           ${NETUIDS[*]}"
echo "  Token IDs:         ${VAULT_IDS[*]}"
echo "  Block range:       [$BLOCK_START, $BLOCK_END]"
ok "All phases passed"
