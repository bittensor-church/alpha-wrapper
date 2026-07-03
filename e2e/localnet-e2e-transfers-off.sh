#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper — Local Chain E2E: alpha transfers switched off
# ============================================================================
#
# Prerequisites:
#   - Local subtensor running at ws://127.0.0.1:9944
#   - btcli installed with Alice wallet (hotkey "default")
#   - forge/cast installed
#   - python3 with substrate-interface
#   - Funded EVM deployer (see DEPLOYER in e2e/e2e_common.sh)
#
# What this checks:
#   When a subnet's `TransferToggle` is off, the chain rejects alpha `transferStake`
#   (`TransferDisallowed`) but still allows `removeStake`/`moveStake`. The vault's
#   alpha rail (unwrap → clone `flush` → `transferStake`) is therefore closed, but
#   both TAO-rail exits still pay out: they only ever `removeStake` alpha → TAO.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

# Flip a subnet's alpha TransferToggle via Sudo (//Alice). Specific to this test.
toggle_transfer_py() { # <netuid> <true|false>
    python3 scripts/chain_ops.py toggle_transfer \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --netuid "$1" \
        --enabled "$2"
}

e2e_bootstrap

log "Phase 6: Seed a wrapped position in the deposit clone (transfers ON)"

POS_NET="${NETUIDS[0]}"
POS_TID="${VAULT_IDS[0]}"
POS_HK_IDX=0
POS_HK_B32="${ALL_HK_B32S[$POS_HK_IDX]}"
POS_HK_SS58="${ALL_HK_SS58S[$POS_HK_IDX]}"

deposit_and_wrap "$POS_NET" "$POS_HK_B32" "$POS_HK_SS58" "$PER_HOTKEY_RAW" 1500000 \
    "wrap for transfers-off setup failed"

POS_SHARES=$(vault_shares "$POS_TID")
[[ "$POS_SHARES" != "0" ]] || fail "no shares minted by wrap on netuid $POS_NET"
# Guard the Phase 9 premise: the position must actually back alpha, else unwrap would revert
# early with NothingToUnwrap and the revert assertion would pass for the wrong reason.
POS_TOTAL=$(vault_total_stake "$POS_TID")
[[ "$POS_TOTAL" != "0" ]] || fail "wrap on netuid $POS_NET left zero backing alpha"
ok "netuid $POS_NET (tokenId $POS_TID): minted $POS_SHARES shares, backing $POS_TOTAL RAO"

log "Phase 7: Seed raw alpha in the user's mailbox (transfers ON)"

SEED_NET="${NETUIDS[1]}"
SEED_HK_IDX=3
SEED_HK_B32="${ALL_HK_B32S[$SEED_HK_IDX]}"
SEED_HK_SS58="${ALL_HK_SS58S[$SEED_HK_IDX]}"

SEED_MAILBOX=$(mailbox_addr "$SEED_NET")
SEED_MAILBOX_SUB=$(h160_to_substrate_b32 "$SEED_MAILBOX")
SEED_MAILBOX_SS58=$(h160_to_ss58 "$SEED_MAILBOX")
info "User mailbox on netuid $SEED_NET: $SEED_MAILBOX"

info "Transferring $PER_HOTKEY_RAW RAO from Alice → mailbox under ${SEED_HK_B32:0:18}..."
transfer_stake_py "$SEED_MAILBOX_SS58" "$SEED_HK_SS58" "$SEED_NET" "$PER_HOTKEY_RAW" | tail -1

SEED_ALPHA=$(get_stake "$SEED_HK_B32" "$SEED_MAILBOX_SUB" "$SEED_NET")
[[ "$SEED_ALPHA" -gt 0 ]] || fail "mailbox has zero alpha after seeding"
ok "Mailbox stake: $SEED_ALPHA RAO"

log "Phase 8: Switch alpha transfers OFF on every subnet"

for NET in "${NETUIDS[@]}"; do
    toggle_transfer_py "$NET" false | tail -1
    ok "netuid $NET: alpha transfers disabled (TransferToggle=false)"
done

info "Confirming raw transferStake now reverts with TransferDisallowed on netuid $POS_NET..."
PROBE=$(python3 scripts/chain_ops.py transfer_stake \
    --chain-endpoint "$CHAIN_ENDPOINT" \
    --dest-ss58 "$SEED_MAILBOX_SS58" --hotkey-ss58 "$POS_HK_SS58" \
    --netuid "$POS_NET" --alpha-amount "$PER_HOTKEY_RAW" 2>&1) \
    && fail "transferStake did NOT revert with transfers off on netuid $POS_NET"
grep -q TransferDisallowed <<<"$PROBE" \
    || fail "transferStake reverted but not with TransferDisallowed: $PROBE"
ok "netuid $POS_NET: transferStake reverts TransferDisallowed"

log "Phase 9: Alpha rail is closed — unwrap(...) must revert"

# The alpha rail ends in clone `flush` → `transferStake`, which now reverts `TransferDisallowed`
# (asserted directly in Phase 8), rolling back the whole unwrap and leaving the shares intact.
PRE_SHARES=$(vault_shares "$POS_TID")
vault_send_expect_revert 2000000 "unwrap (alpha rail) did NOT revert with transfers off" \
    "unwrap(uint256,uint256,bytes32)" "$POS_TID" "$PRE_SHARES" "$WRAPPER_SUB_B32"

POST_SHARES=$(vault_shares "$POS_TID")
[[ "$POST_SHARES" == "$PRE_SHARES" ]] || fail "shares changed after a reverted unwrap ($PRE_SHARES → $POST_SHARES)"
ok "Alpha-rail unwrap reverted; shares preserved ($POST_SHARES)"

log "Phase 10: Withdraw the deposit clone as TAO (unwrapForTao)"

# Live backing alpha this position will sell, and its alpha→TAO quote — both captured pre-swap.
POS_ALPHA=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$POS_TID" "$POS_SHARES" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
POS_QUOTE=$(alpha_to_tao_quote "$POS_NET" "$POS_ALPHA")

USER_TAO_PRE=$(user_tao_wei)
info "User EVM balance before: $USER_TAO_PRE wei"

vault_send 2500000 "unwrapForTao failed with transfers off" \
    "unwrapForTao(uint256,uint256,uint256)" "$POS_TID" "$POS_SHARES" 0

POS_SHARES_POST=$(vault_shares "$POS_TID")
[[ "$POS_SHARES_POST" == "0" ]] || fail "shares still $POS_SHARES_POST after unwrapForTao"
ok "Shares burned to 0"

USER_TAO_POST=$(user_tao_wei)
info "User EVM balance after:  $USER_TAO_POST wei"
GAINED=$(assert_tao_gain "$USER_TAO_PRE" "$USER_TAO_POST" "$POS_QUOTE" \
    "unwrapForTao payout off the alpha→TAO quote")
ok "Deposit clone withdrawn as TAO; user gained $GAINED wei (matches quote $POS_QUOTE RAO)"

log "Phase 11: Withdraw the mailbox itself as TAO (reclaimMailboxAlphaAsTao)"

# Live mailbox alpha (re-read: accrued emissions since Phase 7) and its alpha→TAO quote,
# both captured pre-swap.
RECLAIM_ALPHA=$(get_stake "$SEED_HK_B32" "$SEED_MAILBOX_SUB" "$SEED_NET")
RECLAIM_QUOTE=$(alpha_to_tao_quote "$SEED_NET" "$RECLAIM_ALPHA")

USER_TAO_PRE=$(user_tao_wei)
info "User EVM balance before: $USER_TAO_PRE wei"

vault_send 1500000 "reclaimMailboxAlphaAsTao failed with transfers off" \
    "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)" "$SEED_NET" "$SEED_HK_B32" 0

SEED_ALPHA_POST=$(get_stake "$SEED_HK_B32" "$SEED_MAILBOX_SUB" "$SEED_NET")
[[ "$SEED_ALPHA_POST" == "0" ]] || fail "mailbox still holds $SEED_ALPHA_POST RAO after reclaim"
ok "Mailbox alpha drained to 0"

USER_TAO_POST=$(user_tao_wei)
info "User EVM balance after:  $USER_TAO_POST wei"
GAINED=$(assert_tao_gain "$USER_TAO_PRE" "$USER_TAO_POST" "$RECLAIM_QUOTE" \
    "reclaim payout off the alpha→TAO quote")
ok "Mailbox withdrawn as TAO; user gained $GAINED wei (matches quote $RECLAIM_QUOTE RAO)"

log "E2E complete (alpha transfers off)"
echo "  AlphaVault:        $VAULT_ADDR"
echo "  DepositMailbox:    $MAILBOX_ADDR"
echo "  SubnetClone:       $SUBNET_CLONE_ADDR"
echo "  ValidatorRegistry: $VAL_REGISTRY_ADDR"
echo "  Subnets:           ${NETUIDS[*]} (TransferToggle off)"
echo "  Clone position:    netuid $POS_NET / tokenId $POS_TID"
echo "  Mailbox position:  netuid $SEED_NET"
ok "All phases passed"
