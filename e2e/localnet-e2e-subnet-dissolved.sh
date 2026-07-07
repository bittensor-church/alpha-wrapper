#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper — Local Chain E2E: subnet deregistration (dissolution)
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
#   Dissolving (deregistering) a subnet returns its staked alpha to holders as native
#   TAO. Two users wrap a shared position on a subnet (and one also parks raw alpha in
#   a mailbox); the test dissolves it and checks each user recovers their pro-rata
#   share as native TAO — from both the position and the mailbox — while the alpha-based
#   exits no longer apply (they revert without touching shares) and a position on an
#   untouched subnet keeps exiting normally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

# Dissolve (deregister) a subnet via Sudo (//Alice). Specific to this test.
dissolve_network_py() { # <netuid>
    python3 scripts/chain_ops.py dissolve_network \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --netuid "$1"
}

e2e_bootstrap

log "Phase 6: Two users wrap positions on the soon-dissolved subnet"

DEAD_NET="${NETUIDS[0]}"
DEAD_TID="${VAULT_IDS[0]}"
DEAD_HK_B32="${ALL_HK_B32S[0]}"
DEAD_HK_SS58="${ALL_HK_SS58S[0]}"

# The deployer key doubles as a second share-holder so the dissolved payout splits pro-rata.
USER2_ADDR="$DEPLOYER_ADDR"
USER2_PK="$DEPLOYER_PK"

deposit_and_wrap "$DEAD_NET" "$DEAD_HK_B32" "$DEAD_HK_SS58" "$PER_HOTKEY_RAW" 1500000 \
    "primary-user wrap failed"
deposit_and_wrap "$DEAD_NET" "$DEAD_HK_B32" "$DEAD_HK_SS58" "$PER_HOTKEY_RAW" 1500000 \
    "second-user wrap failed" "$USER2_ADDR" "$USER2_PK"

USER1_SHARES=$(vault_shares "$DEAD_TID")
USER2_SHARES=$(vault_shares "$DEAD_TID" "$USER2_ADDR")
[[ "$USER1_SHARES" != "0" ]] || fail "no shares minted for user1 on netuid $DEAD_NET"
[[ "$USER2_SHARES" != "0" ]] || fail "no shares minted for user2 on netuid $DEAD_NET"
DEAD_CLONE=$(clone_addr "$DEAD_TID")
[[ "$(vault_total_stake "$DEAD_TID")" != "0" ]] || fail "wrap on netuid $DEAD_NET left zero backing alpha"
[[ "$(evm_balance "$DEAD_CLONE")" == "0" ]] || fail "clone holds native TAO before dissolution"
ok "netuid $DEAD_NET (tokenId $DEAD_TID): user1 $USER1_SHARES + user2 $USER2_SHARES shares, clone $DEAD_CLONE backed by alpha"

log "Phase 7: Seed raw (unwrapped) alpha in the user's mailbox on the same subnet"

MAILBOX_HK_B32="${ALL_HK_B32S[1]}"
MAILBOX_HK_SS58="${ALL_HK_SS58S[1]}"
DEAD_MAILBOX=$(mailbox_addr "$DEAD_NET")
DEAD_MAILBOX_SUB=$(h160_to_substrate_b32 "$DEAD_MAILBOX")
DEAD_MAILBOX_SS58=$(h160_to_ss58 "$DEAD_MAILBOX")
info "User mailbox on netuid $DEAD_NET: $DEAD_MAILBOX"

info "Transferring $PER_HOTKEY_RAW RAO from Alice → mailbox under ${MAILBOX_HK_B32:0:18}..."
transfer_stake_py "$DEAD_MAILBOX_SS58" "$MAILBOX_HK_SS58" "$DEAD_NET" "$PER_HOTKEY_RAW" | tail -1

MAILBOX_ALPHA=$(get_stake "$MAILBOX_HK_B32" "$DEAD_MAILBOX_SUB" "$DEAD_NET")
[[ "$MAILBOX_ALPHA" -gt 0 ]] || fail "mailbox has zero alpha after seeding"
ok "Mailbox stake: $MAILBOX_ALPHA RAO under ${MAILBOX_HK_B32:0:18}..."

log "Phase 8: Seed a control position on a subnet that will NOT be dissolved"

LIVE_NET="${NETUIDS[1]}"
LIVE_TID="${VAULT_IDS[1]}"
LIVE_HK_B32="${ALL_HK_B32S[3]}"
LIVE_HK_SS58="${ALL_HK_SS58S[3]}"

deposit_and_wrap "$LIVE_NET" "$LIVE_HK_B32" "$LIVE_HK_SS58" "$PER_HOTKEY_RAW" 1500000 \
    "wrap for the control position failed"

LIVE_SHARES=$(vault_shares "$LIVE_TID")
[[ "$LIVE_SHARES" != "0" ]] || fail "no shares minted by wrap on netuid $LIVE_NET"
ok "netuid $LIVE_NET (tokenId $LIVE_TID): $LIVE_SHARES shares"

log "Phase 9: Dissolve the subnet"

dissolve_network_py "$DEAD_NET" | tail -1

# Dissolution returns the position's and mailbox's alpha as native TAO to their
# addresses, so those balances turn positive as the alpha is wiped.
DEAD_CLONE_TAO=$(evm_balance "$DEAD_CLONE")
DEAD_MAILBOX_TAO=$(evm_balance "$DEAD_MAILBOX")
assert_ge "$DEAD_CLONE_TAO" 1 "clone received no TAO refund after dissolution"
assert_ge "$DEAD_MAILBOX_TAO" 1 "mailbox received no TAO refund after dissolution"
[[ "$(vault_total_stake "$DEAD_TID")" == "0" ]] || fail "totalStake nonzero after dissolution"
cast call "$VAULT_ADDR" "sharePrice(uint256)(uint256)" "$DEAD_TID" --rpc-url "$RPC_URL" >/dev/null 2>&1 \
    && fail "sharePrice did not revert for the dissolved subnet"
ok "Dissolved: clone holds $DEAD_CLONE_TAO wei, mailbox $DEAD_MAILBOX_TAO wei; alpha zeroed, sharePrice reverts"

log "Phase 10: Alpha-selling exits revert — dissolution left no alpha to sell"

vault_send_expect_revert 2000000 "unwrapForTao did NOT revert on the dissolved subnet" \
    "unwrapForTao(uint256,uint256,uint256)" "$DEAD_TID" "$USER1_SHARES" 0
[[ "$(vault_shares "$DEAD_TID")" == "$USER1_SHARES" ]] || fail "shares changed after a reverted unwrapForTao"

vault_send_expect_revert 1500000 "reclaimMailboxAlphaAsTao did NOT revert on wiped mailbox alpha" \
    "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)" "$DEAD_NET" "$MAILBOX_HK_B32" 0
ok "Alpha-selling exits reverted; position shares preserved ($USER1_SHARES)"

log "Phase 11: Both users recover their pro-rata slice of the refund as native TAO"

CLONE_TAO_PRE=$(evm_balance "$DEAD_CLONE")
SUPPLY=$(python3 -c "print($USER1_SHARES + $USER2_SHARES)")
EXP_USER1=$(python3 -c "print($CLONE_TAO_PRE * $USER1_SHARES // $SUPPLY)")

PREVIEW_TAO=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$DEAD_TID" "$USER1_SHARES" --rpc-url "$RPC_URL" | tail -1 | awk '{print $1}')
[[ "$PREVIEW_TAO" == "$EXP_USER1" ]] \
    || fail "previewUnwrap tao ($PREVIEW_TAO) != user1's pro-rata share ($EXP_USER1) of clone $CLONE_TAO_PRE"
python3 -c "import sys; sys.exit(0 if 0 < $EXP_USER1 < $CLONE_TAO_PRE else 1)" \
    || fail "dissolved payout did not split between holders (share $EXP_USER1 of $CLONE_TAO_PRE)"

USER1_TAO_PRE=$(user_tao_wei)
vault_send 2000000 "user1 dissolved unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$DEAD_TID" "$USER1_SHARES" "$WRAPPER_SUB_B32"
[[ "$(vault_shares "$DEAD_TID")" == "0" ]] || fail "user1 shares not burned after the dissolved unwrap"
GAINED1=$(assert_gain "$USER1_TAO_PRE" "$(user_tao_wei)" "user1 gained no TAO from the dissolved unwrap")

USER2_TAO_PRE=$(evm_balance "$USER2_ADDR")
vault_send_as "$USER2_PK" 2000000 "user2 dissolved unwrap failed" \
    "unwrap(uint256,uint256,bytes32)" "$DEAD_TID" "$USER2_SHARES" "$WRAPPER_SUB_B32"
[[ "$(vault_shares "$DEAD_TID" "$USER2_ADDR")" == "0" ]] || fail "user2 shares not burned after the dissolved unwrap"
GAINED2=$(assert_gain "$USER2_TAO_PRE" "$(evm_balance "$USER2_ADDR")" "user2 gained no TAO from the dissolved unwrap")

[[ "$(evm_balance "$DEAD_CLONE")" == "0" ]] || fail "clone not fully drained after both users unwrapped"
ok "Pro-rata recovery: user1 +$GAINED1 wei (preview $EXP_USER1), user2 +$GAINED2 wei; clone drained to 0"

log "Phase 12: Recover the mailbox refund as native TAO via reclaimTaoFromMailbox"

MAILBOX_TAO_PRE=$(evm_balance "$DEAD_MAILBOX")
USER_TAO_PRE=$(user_tao_wei)
vault_send 2000000 "reclaimTaoFromMailbox failed" \
    "reclaimTaoFromMailbox(uint256)" "$DEAD_NET"

[[ "$(evm_balance "$DEAD_MAILBOX")" == "0" ]] || fail "mailbox not fully drained after reclaimTaoFromMailbox"
USER_TAO_POST=$(user_tao_wei)
GAINED=$(assert_gain "$USER_TAO_PRE" "$USER_TAO_POST" "user gained no TAO from reclaimTaoFromMailbox")
ok "Mailbox refund recovered ($MAILBOX_TAO_PRE wei); user net +$GAINED wei after gas, mailbox drained to 0"

log "Phase 13: The untouched subnet still exits normally (dissolution was scoped)"

LIVE_ALPHA=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$LIVE_TID" "$LIVE_SHARES" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
LIVE_QUOTE=$(alpha_to_tao_quote "$LIVE_NET" "$LIVE_ALPHA")

USER_TAO_PRE=$(user_tao_wei)
vault_send 2500000 "unwrapForTao on the surviving subnet failed" \
    "unwrapForTao(uint256,uint256,uint256)" "$LIVE_TID" "$LIVE_SHARES" 0

[[ "$(vault_shares "$LIVE_TID")" == "0" ]] || fail "shares still outstanding after unwrapForTao on the live subnet"
USER_TAO_POST=$(user_tao_wei)
GAINED=$(assert_tao_gain "$USER_TAO_PRE" "$USER_TAO_POST" "$LIVE_QUOTE" \
    "surviving-subnet unwrapForTao payout off the alpha→TAO quote")
ok "Surviving subnet paid $GAINED wei (matches quote $LIVE_QUOTE RAO); dissolution was scoped to netuid $DEAD_NET"