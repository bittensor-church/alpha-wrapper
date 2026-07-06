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
#   Conviction locks bind a coldkey's subnet-wide alpha, and contract-controlled
#   coldkeys reject locked inflow (the accept-locked flag defaults OFF and no
#   precompile can flip it). A deposit dipping into locked mass therefore
#   reverts at the depositor's own transferStake, before the vault is involved;
#   the free portion wraps normally; and vault flows — rebalance, unwrap
#   (including to a coldkey that itself holds a lock), unwrapForTao — never
#   touch lock state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

UNLOCKED_MARGIN_RAW=10000000000 # 10 alpha

lock_stake_py() { # <hotkey_ss58> <netuid> <amount_raw>
    python3 scripts/chain_ops.py lock_stake \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --hotkey-ss58 "$1" \
        --netuid "$2" \
        --amount "$3"
}

alice_locked_mass() { # <netuid> <hotkey_ss58>
    python3 scripts/chain_ops.py get_lock \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --coldkey-ss58 "$ALICE_COLDKEY_SS58" \
        --netuid "$1" \
        --hotkey-ss58 "$2"
}

# RAW/share magnitudes can exceed bash's signed-64-bit arithmetic; compare in python.
assert_ge() { # <actual> <min_expected> <fail_msg>
    python3 -c "import sys; sys.exit(0 if $1 >= $2 else 1)" || fail "$3 ($1 < $2)"
}

# Locks bind Alice's subnet-wide alpha across ALL her hotkeys, including the
# subnet-owner hotkey. getTotalColdkeyStakeOnSubnet cannot size the lock: it
# returns TAO value (sim-swap), not the alpha the lock is denominated in.
alice_subnet_alpha() { # <netuid>
    sum_stake "$ALICE_COLDKEY_B32" "$1" \
        "$ALICE_OWNER_HK_B32" "${ALL_HK_B32S[0]}" "${ALL_HK_B32S[1]}" "${ALL_HK_B32S[2]}"
}

e2e_bootstrap

log "Phase 6: Baseline wrap before any lock exists"

POS_NET="${NETUIDS[0]}"
POS_TID="${VAULT_IDS[0]}"
POS_HK_B32="${ALL_HK_B32S[0]}"
POS_HK_SS58="${ALL_HK_SS58S[0]}"

MAILBOX=$(mailbox_addr "$POS_NET")
MAILBOX_SUB=$(h160_to_substrate_b32 "$MAILBOX")
MAILBOX_SS58=$(h160_to_ss58 "$MAILBOX")
ALICE_OWNER_HK_B32=$(read_hotkey_pubkey "$ALICE_WALLET" "$ALICE_HOTKEY_NAME")

deposit_and_wrap "$POS_NET" "$POS_HK_B32" "$POS_HK_SS58" "$PER_HOTKEY_RAW" 1500000 \
    "baseline wrap failed"

BASE_SHARES=$(vault_shares "$POS_TID")
[[ "$BASE_SHARES" != "0" ]] || fail "no shares minted by the baseline wrap"
ok "Baseline position: $BASE_SHARES shares on tokenId $POS_TID"

log "Phase 7: Alice locks nearly all her remaining alpha on netuid $POS_NET"

ALICE_TOTAL=$(alice_subnet_alpha "$POS_NET")
assert_ge "$ALICE_TOTAL" "$((2 * UNLOCKED_MARGIN_RAW))" "Alice's subnet stake too small to lock meaningfully"
LOCK_RAW=$((ALICE_TOTAL - UNLOCKED_MARGIN_RAW))

info "Alice subnet total: $ALICE_TOTAL RAO; locking $LOCK_RAW RAO to ${POS_HK_SS58:0:12}... (margin $UNLOCKED_MARGIN_RAW)"
lock_stake_py "$POS_HK_SS58" "$POS_NET" "$LOCK_RAW" | tail -1

INITIAL_LOCKED_MASS=$(alice_locked_mass "$POS_NET" "$POS_HK_SS58")
# 99% bound absorbs the ~1e-6/block decay between lock and read.
assert_ge "$INITIAL_LOCKED_MASS" "$((LOCK_RAW / 100 * 99))" "lock not registered on chain"
ok "Lock live on chain: locked_mass=$INITIAL_LOCKED_MASS RAO (movable margin ≈ $UNLOCKED_MARGIN_RAW RAO + emissions)"

log "Phase 8: Depositing MORE than the movable amount is refused by the chain"

# The chain clamps: a transfer within the movable amount passes legitimately, so
# the probe below must exceed movable (which keeps growing with emissions).
ALICE_HK_A_PRE=$(get_stake "$POS_HK_B32" "$ALICE_COLDKEY_B32" "$POS_NET")
MOVABLE_NOW=$(python3 -c "print(max(0, $(alice_subnet_alpha "$POS_NET") - $(alice_locked_mass "$POS_NET" "$POS_HK_SS58")))")
assert_ge "$ALICE_HK_A_PRE" "$((MOVABLE_NOW + 2 * UNLOCKED_MARGIN_RAW))" \
    "premise broken: hk_a balance does not exceed movable ($MOVABLE_NOW RAO) by 2x margin"

# The Phase 6 flush can leave <=1 RAO of share-rounding dust on the mailbox, so
# atomicity means "unchanged across the refused transfer", not "zero".
MAILBOX_ALPHA_PRE=$(get_stake "$POS_HK_B32" "$MAILBOX_SUB" "$POS_NET")

info "Attempting to transfer Alice's full hk_a balance ($ALICE_HK_A_PRE RAO) into the mailbox..."
PROBE=$(transfer_stake_py "$MAILBOX_SS58" "$POS_HK_SS58" "$POS_NET" "$ALICE_HK_A_PRE" 2>&1) \
    && fail "over-movable transferStake did NOT revert (locked alpha reached the mailbox!)"
grep -q AccountRejectsLockedAlpha <<<"$PROBE" \
    || fail "transferStake reverted but not with AccountRejectsLockedAlpha: $PROBE"
ok "Chain refused with AccountRejectsLockedAlpha (mailbox rejects locked inflow by default)"

MAILBOX_ALPHA_POST=$(get_stake "$POS_HK_B32" "$MAILBOX_SUB" "$POS_NET")
[[ "$MAILBOX_ALPHA_POST" == "$MAILBOX_ALPHA_PRE" ]] \
    || fail "mailbox balance changed by a refused transfer ($MAILBOX_ALPHA_PRE → $MAILBOX_ALPHA_POST RAO)"
ALICE_HK_A_POST=$(get_stake "$POS_HK_B32" "$ALICE_COLDKEY_B32" "$POS_NET")
assert_ge "$ALICE_HK_A_POST" "$ALICE_HK_A_PRE" "Alice's stake decreased despite the refused transfer"
ok "Refusal was atomic: mailbox unchanged ($MAILBOX_ALPHA_POST RAO), Alice's stake intact"

PRE_SHARES=$(vault_shares "$POS_TID")
vault_send_expect_revert 1500000 "wrap with no arrived deposit did NOT revert" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$POS_NET" "$POS_HK_B32"
POST_SHARES=$(vault_shares "$POS_TID")
[[ "$POST_SHARES" == "$PRE_SHARES" ]] || fail "shares changed after a reverted wrap ($PRE_SHARES → $POST_SHARES)"
ok "wrap reverted cleanly (ZeroAmount/DepositTooSmall); shares unchanged ($POST_SHARES)"

log "Phase 9: The movable portion of a partially locked wallet wraps normally"

DEP_RAW=$((UNLOCKED_MARGIN_RAW / 2))
deposit_and_wrap "$POS_NET" "$POS_HK_B32" "$POS_HK_SS58" "$DEP_RAW" 1500000 \
    "wrap of the movable portion failed"

POST_SHARES=$(vault_shares "$POS_TID")
python3 -c "import sys; sys.exit(0 if $POST_SHARES > $PRE_SHARES else 1)" \
    || fail "no shares minted for the movable-portion wrap ($PRE_SHARES → $POST_SHARES)"
LOCKED_AFTER_WRAP=$(alice_locked_mass "$POS_NET" "$POS_HK_SS58")
assert_ge "$LOCKED_AFTER_WRAP" "$((INITIAL_LOCKED_MASS / 100 * 99))" "Alice's lock shrank from a free-portion transfer"
MINTED=$(python3 -c "print($POST_SHARES - $PRE_SHARES)")
ok "Movable portion wrapped: $MINTED new shares; Alice's lock untouched"

log "Phase 10: Unwrap pays out to a coldkey that HOLDS an active lock"

TOTAL_SHARES=$(vault_shares "$POS_TID")
HALF_SHARES=$(python3 -c "print($TOTAL_SHARES // 2)")
PREVIEWED_ALPHA=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$POS_TID" "$HALF_SHARES" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
ALICE_TOTAL_PRE=$(alice_subnet_alpha "$POS_NET")

vault_send 2000000 "unwrap to a lock-holding coldkey failed" \
    "unwrap(uint256,uint256,bytes32)" "$POS_TID" "$HALF_SHARES" "$ALICE_COLDKEY_B32"

ALICE_TOTAL_POST=$(alice_subnet_alpha "$POS_NET")
ALICE_GAIN=$(python3 -c "print($ALICE_TOTAL_POST - $ALICE_TOTAL_PRE)")
# Emissions between the reads only add, so the preview (less drift allowance)
# is a safe lower bound proving a real half-position payout.
assert_ge "$ALICE_GAIN" "$((PREVIEWED_ALPHA / 100 * 85))" \
    "unwrap paid a lock-holding coldkey far less than previewed ($ALICE_GAIN vs $PREVIEWED_ALPHA)"
LOCKED_AFTER_UNWRAP=$(alice_locked_mass "$POS_NET" "$POS_HK_SS58")
assert_ge "$LOCKED_AFTER_UNWRAP" "$((INITIAL_LOCKED_MASS / 100 * 99))" "Alice's lock disturbed by receiving unwrapped alpha"
ok "Locked coldkey received $ALICE_GAIN RAO unlocked alpha (preview $PREVIEWED_ALPHA); lock intact"

log "Phase 11: unwrapForTao (removeStake rail) unaffected by other stakers' locks"

REST_SHARES=$(vault_shares "$POS_TID")
REST_ALPHA=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$POS_TID" "$REST_SHARES" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
REST_QUOTE=$(alpha_to_tao_quote "$POS_NET" "$REST_ALPHA")

USER_TAO_PRE=$(user_tao_wei)
vault_send 2500000 "unwrapForTao failed on a subnet with active locks" \
    "unwrapForTao(uint256,uint256,uint256)" "$POS_TID" "$REST_SHARES" 0
USER_TAO_POST=$(user_tao_wei)

FINAL_SHARES=$(vault_shares "$POS_TID")
[[ "$FINAL_SHARES" == "0" ]] || fail "shares still $FINAL_SHARES after unwrapForTao"
GAINED=$(assert_tao_gain "$USER_TAO_PRE" "$USER_TAO_POST" "$REST_QUOTE" \
    "unwrapForTao payout off the alpha→TAO quote")
ok "Remaining shares exited as TAO: gained $GAINED wei (quote $REST_QUOTE RAO)"

log "E2E complete (convicted alpha)"
echo "  AlphaVault:        $VAULT_ADDR"
echo "  Subnet under test: netuid $POS_NET / tokenId $POS_TID"
echo "  Alice lock:        locked_mass=$LOCKED_AFTER_UNWRAP RAO → ${POS_HK_SS58:0:12}..."
ok "All phases passed"
