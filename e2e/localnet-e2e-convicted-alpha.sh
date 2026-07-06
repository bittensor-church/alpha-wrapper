#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper — Local Chain E2E: convicted (conviction-locked) alpha
# ============================================================================
#
# Prerequisites:
#   - Local subtensor running at ws://127.0.0.1:9944, built from a runtime with
#     conviction v2 (`SubtensorModule.lock_stake` present)
#   - btcli installed with Alice wallet (hotkey "default")
#   - forge/cast installed
#   - python3 with substrate-interface
#   - Funded EVM deployer (see DEPLOYER in e2e/e2e_common.sh)
#
# What this checks:
#   Convicted alpha is refused at wrap time and never breaks the vault.
#   Locks bind a coldkey's subnet-wide alpha: total cannot drop below the locked
#   mass, and a same-subnet transferStake moves the free portion first — only a
#   transfer dipping into locked mass carries the lock, which every contract-
#   controlled coldkey rejects (accept-locked flag defaults OFF and no precompile
#   can flip it). Concretely:
#     - a deposit exceeding the depositor's movable alpha reverts on-chain with
#       AccountRejectsLockedAlpha before the vault is ever involved; `wrap` then
#       reverts ZeroAmount with nothing persisted (Phase 8);
#     - the movable portion of a partially locked wallet wraps normally (Phase 9);
#     - vault flows (rebalance, unwrap, unwrapForTao) are untouched by other
#       stakers' locks, and a coldkey holding an active lock can still RECEIVE
#       unwrapped alpha — the vault's stake is lock-free, so transfer_lock
#       no-ops and no accept flag is needed (Phases 10-11).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

# Substrate dev Alice, SS58 form (b32 form lives in e2e_common.sh).
ALICE_COLDKEY_SS58="5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"

# Freely movable cushion left outside the lock, in RAW alpha (10 alpha).
MARGIN_RAW=10000000000

# Lock RAW alpha of Alice's stake on a subnet to a conviction hotkey. Specific to this test.
lock_stake_py() { # <hotkey_ss58> <netuid> <amount_raw>
    python3 scripts/chain_ops.py lock_stake \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --hotkey-ss58 "$1" \
        --netuid "$2" \
        --amount "$3"
}

# Current locked_mass of Alice's lock on (netuid, conviction hotkey), in RAW alpha.
alice_locked_mass() { # <netuid> <hotkey_ss58>
    python3 scripts/chain_ops.py get_lock \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --coldkey-ss58 "$ALICE_COLDKEY_SS58" \
        --netuid "$1" \
        --hotkey-ss58 "$2"
}

# Numeric assert for RAW amounts (python compare: readable and immune to future overflow).
assert_ge() { # <actual> <min_expected> <fail_msg>
    python3 -c "import sys; sys.exit(0 if $1 >= $2 else 1)" || fail "$3 ($1 < $2)"
}

e2e_bootstrap

log "Phase 6: Baseline wrap before any lock exists"

POS_NET="${NETUIDS[0]}"
POS_TID="${VAULT_IDS[0]}"
POS_HK_B32="${ALL_HK_B32S[0]}"
POS_HK_SS58="${ALL_HK_SS58S[0]}"
HK_B_B32="${ALL_HK_B32S[1]}"
HK_C_B32="${ALL_HK_B32S[2]}"

MAILBOX=$(mailbox_addr "$POS_NET")
MAILBOX_SUB=$(h160_to_substrate_b32 "$MAILBOX")
MAILBOX_SS58=$(h160_to_ss58 "$MAILBOX")

deposit_and_wrap "$POS_NET" "$POS_HK_B32" "$POS_HK_SS58" "$PER_HOTKEY_RAW" 1500000 \
    "baseline wrap failed"

BASE_SHARES=$(vault_shares "$POS_TID")
[[ "$BASE_SHARES" != "0" ]] || fail "no shares minted by the baseline wrap"
ok "Baseline position: $BASE_SHARES shares on tokenId $POS_TID"

log "Phase 7: Alice locks nearly all her remaining alpha on netuid $POS_NET"

ALICE_TOTAL=$(sum_stake "$ALICE_COLDKEY_B32" "$POS_NET" "$POS_HK_B32" "$HK_B_B32" "$HK_C_B32")
assert_ge "$ALICE_TOTAL" "$((2 * MARGIN_RAW))" "Alice's subnet stake too small to lock meaningfully"
LOCK_RAW=$((ALICE_TOTAL - MARGIN_RAW))

info "Alice subnet total: $ALICE_TOTAL RAO; locking $LOCK_RAW RAO to ${POS_HK_SS58:0:12}... (margin $MARGIN_RAW)"
lock_stake_py "$POS_HK_SS58" "$POS_NET" "$LOCK_RAW" | tail -1

LOCKED=$(alice_locked_mass "$POS_NET" "$POS_HK_SS58")
# Decay between lock and read is ~1e-6/block — 99% is a generous lower bound.
assert_ge "$LOCKED" "$((LOCK_RAW / 100 * 99))" "lock not registered on chain"
ok "Lock live on chain: locked_mass=$LOCKED RAO (movable margin ≈ $MARGIN_RAW RAO + emissions)"

log "Phase 8: Depositing MORE than the movable amount is refused by the chain"

ALICE_HK_A_PRE=$(get_stake "$POS_HK_B32" "$ALICE_COLDKEY_B32" "$POS_NET")
assert_ge "$ALICE_HK_A_PRE" "$((2 * MARGIN_RAW))" "premise broken: hk_a balance not above movable margin"

info "Attempting to transfer Alice's full hk_a balance ($ALICE_HK_A_PRE RAO) into the mailbox..."
PROBE=$(transfer_stake_py "$MAILBOX_SS58" "$POS_HK_SS58" "$POS_NET" "$ALICE_HK_A_PRE" 2>&1) \
    && fail "over-movable transferStake did NOT revert (locked alpha reached the mailbox!)"
grep -q AccountRejectsLockedAlpha <<<"$PROBE" \
    || fail "transferStake reverted but not with AccountRejectsLockedAlpha: $PROBE"
ok "Chain refused with AccountRejectsLockedAlpha (mailbox rejects locked inflow by default)"

MAILBOX_ALPHA=$(get_stake "$POS_HK_B32" "$MAILBOX_SUB" "$POS_NET")
[[ "$MAILBOX_ALPHA" == "0" ]] || fail "mailbox holds $MAILBOX_ALPHA RAO after a refused transfer"
ALICE_HK_A_POST=$(get_stake "$POS_HK_B32" "$ALICE_COLDKEY_B32" "$POS_NET")
assert_ge "$ALICE_HK_A_POST" "$ALICE_HK_A_PRE" "Alice's stake decreased despite the refused transfer"
ok "Refusal was atomic: mailbox empty, Alice's stake intact"

PRE_SHARES=$(vault_shares "$POS_TID")
vault_send_expect_revert 1500000 "wrap on an empty mailbox did NOT revert" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$POS_NET" "$POS_HK_B32"
POST_SHARES=$(vault_shares "$POS_TID")
[[ "$POST_SHARES" == "$PRE_SHARES" ]] || fail "shares changed after a reverted wrap ($PRE_SHARES → $POST_SHARES)"
ok "wrap reverted cleanly (ZeroAmount); shares unchanged ($POST_SHARES)"

log "Phase 9: The movable portion of a partially locked wallet wraps normally"

DEP_RAW=$((MARGIN_RAW / 2))
deposit_and_wrap "$POS_NET" "$POS_HK_B32" "$POS_HK_SS58" "$DEP_RAW" 1500000 \
    "wrap of the movable portion failed"

POST_SHARES=$(vault_shares "$POS_TID")
python3 -c "import sys; sys.exit(0 if $POST_SHARES > $PRE_SHARES else 1)" \
    || fail "no shares minted for the movable-portion wrap ($PRE_SHARES → $POST_SHARES)"
LOCKED_AFTER_WRAP=$(alice_locked_mass "$POS_NET" "$POS_HK_SS58")
assert_ge "$LOCKED_AFTER_WRAP" "$((LOCKED / 100 * 99))" "Alice's lock shrank from a free-portion transfer"
ok "Movable portion wrapped: $((POST_SHARES - PRE_SHARES)) new shares; Alice's lock untouched"

log "Phase 10: Unwrap pays out to a coldkey that HOLDS an active lock"

SHARES=$(vault_shares "$POS_TID")
HALF=$((SHARES / 2))
ALICE_TOTAL_PRE=$(sum_stake "$ALICE_COLDKEY_B32" "$POS_NET" "$POS_HK_B32" "$HK_B_B32" "$HK_C_B32")

vault_send 2000000 "unwrap to a lock-holding coldkey failed" \
    "unwrap(uint256,uint256,bytes32)" "$POS_TID" "$HALF" "$ALICE_COLDKEY_B32"

ALICE_TOTAL_POST=$(sum_stake "$ALICE_COLDKEY_B32" "$POS_NET" "$POS_HK_B32" "$HK_B_B32" "$HK_C_B32")
python3 -c "import sys; sys.exit(0 if $ALICE_TOTAL_POST > $ALICE_TOTAL_PRE else 1)" \
    || fail "Alice received no alpha from unwrap ($ALICE_TOTAL_PRE → $ALICE_TOTAL_POST)"
LOCKED_AFTER_UNWRAP=$(alice_locked_mass "$POS_NET" "$POS_HK_SS58")
assert_ge "$LOCKED_AFTER_UNWRAP" "$((LOCKED / 100 * 99))" "Alice's lock disturbed by receiving unwrapped alpha"
ok "Locked coldkey received $((ALICE_TOTAL_POST - ALICE_TOTAL_PRE)) RAO unlocked alpha; lock intact"

log "Phase 11: unwrapForTao (removeStake rail) unaffected by other stakers' locks"

REST=$(vault_shares "$POS_TID")
REST_ALPHA=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$POS_TID" "$REST" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
REST_QUOTE=$(alpha_to_tao_quote "$POS_NET" "$REST_ALPHA")

USER_TAO_PRE=$(user_tao_wei)
vault_send 2500000 "unwrapForTao failed on a subnet with active locks" \
    "unwrapForTao(uint256,uint256,uint256)" "$POS_TID" "$REST" 0
USER_TAO_POST=$(user_tao_wei)

REST_SHARES=$(vault_shares "$POS_TID")
[[ "$REST_SHARES" == "0" ]] || fail "shares still $REST_SHARES after unwrapForTao"
GAINED=$(assert_tao_gain "$USER_TAO_PRE" "$USER_TAO_POST" "$REST_QUOTE" \
    "unwrapForTao payout off the alpha→TAO quote")
ok "Remaining shares exited as TAO: gained $GAINED wei (quote $REST_QUOTE RAO)"

log "E2E complete (convicted alpha)"
echo "  AlphaVault:        $VAULT_ADDR"
echo "  Subnet under test: netuid $POS_NET / tokenId $POS_TID"
echo "  Alice lock:        locked_mass=$LOCKED_AFTER_UNWRAP RAO → ${POS_HK_SS58:0:12}..."
ok "All phases passed"
