#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper - Local Chain E2E: convicted (conviction-locked) alpha
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
#   Conviction locks bind a coldkey's subnet-wide alpha, and contract-controlled
#   coldkeys reject locked inflow (the accept-locked flag defaults OFF and no
#   precompile can flip it). A deposit dipping into locked mass therefore
#   reverts at the depositor's own transferStake, before the vault is involved;
#   the free portion wraps normally; and vault flows - rebalance, unwrap
#   (including to a coldkey that itself holds a lock), unwrapForTao - never
#   touch lock state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

UNLOCKED_MARGIN_RAW=30000000000 # 30 alpha

lock_stake_py() {
    python3 e2e/chain_ops.py lock_stake \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --hotkey-ss58 "$1" \
        --netuid "$2" \
        --amount "$3"
}

alice_locked_alpha() {
    python3 e2e/chain_ops.py get_lock \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --coldkey-ss58 "$ALICE_COLDKEY_SS58" \
        --netuid "$1" \
        --hotkey-ss58 "$2"
}

# Locks bind Alice's subnet-wide alpha across ALL her hotkeys, including the
# subnet-owner hotkey. getTotalColdkeyStakeOnSubnet cannot size the lock: it
# returns TAO value (sim-swap), not the alpha the lock is denominated in.
alice_subnet_alpha() { # <netuid>
    sum_stake "$ALICE_COLDKEY_B32" "$1" \
        "$ALICE_OWNER_HOTKEY_B32" "${ALL_HK_B32S[0]}" "${ALL_HK_B32S[1]}" "${ALL_HK_B32S[2]}"
}

e2e_bootstrap

TEST_NETUID="${NETUIDS[0]}"
TEST_TOKEN_ID="${VAULT_IDS[0]}"
TEST_HOTKEY_B32="${ALL_HK_B32S[0]}"
TEST_HOTKEY_SS58="${ALL_HK_SS58S[0]}"

USER_MAILBOX_H160=$(mailbox_addr "$TEST_NETUID")
USER_MAILBOX_COLDKEY_B32=$(h160_to_substrate_b32 "$USER_MAILBOX_H160")
USER_MAILBOX_COLDKEY_SS58=$(h160_to_ss58 "$USER_MAILBOX_H160")
ALICE_OWNER_HOTKEY_B32=$(read_hotkey_pubkey "$ALICE_WALLET" "$ALICE_HOTKEY_NAME")

log "Phase 6: Alice locks all but the movable margin of her netuid $TEST_NETUID stake"

ALICE_SUBNET_ALPHA_BEFORE_LOCK=$(alice_subnet_alpha "$TEST_NETUID")
assert_ge "$ALICE_SUBNET_ALPHA_BEFORE_LOCK" "$((2 * UNLOCKED_MARGIN_RAW))" \
    "Alice's subnet stake too small to lock meaningfully"
LOCK_AMOUNT_RAW=$((ALICE_SUBNET_ALPHA_BEFORE_LOCK - UNLOCKED_MARGIN_RAW))

info "Alice subnet total: $ALICE_SUBNET_ALPHA_BEFORE_LOCK RAO; locking $LOCK_AMOUNT_RAW RAO to ${TEST_HOTKEY_SS58:0:12}... (margin $UNLOCKED_MARGIN_RAW)"
lock_stake_py "$TEST_HOTKEY_SS58" "$TEST_NETUID" "$LOCK_AMOUNT_RAW" | tail -1

INITIAL_LOCKED_ALPHA=$(alice_locked_alpha "$TEST_NETUID" "$TEST_HOTKEY_SS58")
[[ "$INITIAL_LOCKED_ALPHA" == "$LOCK_AMOUNT_RAW" ]] \
    || fail "lock not registered exactly (asked $LOCK_AMOUNT_RAW, stored $INITIAL_LOCKED_ALPHA)"
ok "Lock live on chain: $INITIAL_LOCKED_ALPHA RAO locked (movable margin ~ $UNLOCKED_MARGIN_RAW RAO + emissions)"

log "Phase 7: Depositing MORE than the movable amount is refused by the chain"

# The chain clamps: a transfer within the movable amount passes legitimately, so
# the refused transfer must exceed movable (which keeps growing with emissions).
OVER_MOVABLE_AMOUNT=$(get_stake "$TEST_HOTKEY_B32" "$ALICE_COLDKEY_B32" "$TEST_NETUID")
ALICE_MOVABLE_ALPHA=$(python3 -c "print(max(0, $(alice_subnet_alpha "$TEST_NETUID") - $(alice_locked_alpha "$TEST_NETUID" "$TEST_HOTKEY_SS58")))")
assert_ge "$OVER_MOVABLE_AMOUNT" "$((ALICE_MOVABLE_ALPHA + 2 * UNLOCKED_MARGIN_RAW))" \
    "premise broken: Alice's test-hotkey stake does not exceed movable ($ALICE_MOVABLE_ALPHA RAO) by 2x margin"

MAILBOX_ALPHA_BEFORE=$(get_stake "$TEST_HOTKEY_B32" "$USER_MAILBOX_COLDKEY_B32" "$TEST_NETUID")
[[ "$MAILBOX_ALPHA_BEFORE" == "0" ]] \
    || fail "mailbox not virgin before the refused transfer ($MAILBOX_ALPHA_BEFORE RAO)"

info "Attempting to transfer $OVER_MOVABLE_AMOUNT RAO (Alice's full test-hotkey stake) into the mailbox..."
REFUSED_TRANSFER_OUTPUT=$(transfer_stake_py "$USER_MAILBOX_COLDKEY_SS58" "$TEST_HOTKEY_SS58" "$TEST_NETUID" "$OVER_MOVABLE_AMOUNT" 2>&1) \
    && fail "over-movable transferStake did NOT revert (locked alpha reached the mailbox!)"
grep -q AccountRejectsLockedAlpha <<<"$REFUSED_TRANSFER_OUTPUT" \
    || fail "transferStake reverted but not with AccountRejectsLockedAlpha: $REFUSED_TRANSFER_OUTPUT"
ok "Chain refused with AccountRejectsLockedAlpha (mailbox rejects locked inflow by default)"

MAILBOX_ALPHA_AFTER=$(get_stake "$TEST_HOTKEY_B32" "$USER_MAILBOX_COLDKEY_B32" "$TEST_NETUID")
[[ "$MAILBOX_ALPHA_AFTER" == "$MAILBOX_ALPHA_BEFORE" ]] \
    || fail "mailbox balance changed by a refused transfer ($MAILBOX_ALPHA_BEFORE -> $MAILBOX_ALPHA_AFTER RAO)"
ALICE_TEST_HOTKEY_STAKE_AFTER=$(get_stake "$TEST_HOTKEY_B32" "$ALICE_COLDKEY_B32" "$TEST_NETUID")
assert_ge "$ALICE_TEST_HOTKEY_STAKE_AFTER" "$OVER_MOVABLE_AMOUNT" "Alice's stake decreased despite the refused transfer"
ok "Refusal was atomic: mailbox unchanged ($MAILBOX_ALPHA_AFTER RAO), Alice's stake intact"

SHARES_BEFORE_REVERTED_WRAP=$(vault_shares "$TEST_TOKEN_ID")
vault_send_expect_revert 1500000 "wrap with no arrived deposit did NOT revert" \
    "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$TEST_NETUID" "$TEST_HOTKEY_B32"
SHARES_AFTER_REVERTED_WRAP=$(vault_shares "$TEST_TOKEN_ID")
[[ "$SHARES_AFTER_REVERTED_WRAP" == "$SHARES_BEFORE_REVERTED_WRAP" ]] \
    || fail "shares changed after a reverted wrap ($SHARES_BEFORE_REVERTED_WRAP -> $SHARES_AFTER_REVERTED_WRAP)"
ok "wrap reverted (ZeroAmount: mailbox is provably empty); shares unchanged ($SHARES_AFTER_REVERTED_WRAP)"

log "Phase 8: The movable portion of the locked wallet wraps normally"

MOVABLE_DEPOSIT_RAW=$((UNLOCKED_MARGIN_RAW / 2))
deposit_and_wrap "$TEST_NETUID" "$TEST_HOTKEY_B32" "$TEST_HOTKEY_SS58" "$MOVABLE_DEPOSIT_RAW" 1500000 \
    "wrap of the movable portion failed"

SHARES_AFTER_MOVABLE_WRAP=$(vault_shares "$TEST_TOKEN_ID")
python3 -c "import sys; sys.exit(0 if $SHARES_AFTER_MOVABLE_WRAP > $SHARES_AFTER_REVERTED_WRAP else 1)" \
    || fail "no shares minted for the movable-portion wrap"
LOCKED_ALPHA_AFTER_MOVABLE_WRAP=$(alice_locked_alpha "$TEST_NETUID" "$TEST_HOTKEY_SS58")
# Touching the lock re-persists its lazily-decayed locked amount (factor
# e^(-1/UnlockRate) ~= 1 - 1e-6 per block); 99% is a generous floor here.
assert_ge "$LOCKED_ALPHA_AFTER_MOVABLE_WRAP" "$((INITIAL_LOCKED_ALPHA / 100 * 99))" \
    "Alice's lock shrank from a free-portion transfer"
assert_ge "$INITIAL_LOCKED_ALPHA" "$LOCKED_ALPHA_AFTER_MOVABLE_WRAP" \
    "Alice's lock grew during a free-portion wrap (a lock migrated unexpectedly)"
ok "Movable portion wrapped: $SHARES_AFTER_MOVABLE_WRAP shares; Alice's lock untouched"

log "Phase 9: Unwrap pays out to a coldkey that HOLDS an active lock"

# Share balances are 1e18-scale; all share math goes through python.
TOTAL_SHARES=$(vault_shares "$TEST_TOKEN_ID")
HALF_SHARES=$(python3 -c "print($TOTAL_SHARES // 2)")
PREVIEWED_HALF_ALPHA=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$TEST_TOKEN_ID" "$HALF_SHARES" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
ALICE_SUBNET_ALPHA_BEFORE_UNWRAP=$(alice_subnet_alpha "$TEST_NETUID")

vault_send 2000000 "unwrap to a lock-holding coldkey failed" \
    "unwrap(uint256,uint256,bytes32)" "$TEST_TOKEN_ID" "$HALF_SHARES" "$ALICE_COLDKEY_B32"

ALICE_SUBNET_ALPHA_AFTER_UNWRAP=$(alice_subnet_alpha "$TEST_NETUID")
ALICE_RECEIVED_ALPHA=$(python3 -c "print($ALICE_SUBNET_ALPHA_AFTER_UNWRAP - $ALICE_SUBNET_ALPHA_BEFORE_UNWRAP)")
# Emissions between the reads only add, so the preview (less drift allowance)
# is a safe lower bound proving a real half-position payout.
assert_ge "$ALICE_RECEIVED_ALPHA" "$((PREVIEWED_HALF_ALPHA / 100 * 85))" \
    "unwrap paid a lock-holding coldkey far less than previewed ($ALICE_RECEIVED_ALPHA vs $PREVIEWED_HALF_ALPHA)"
LOCKED_ALPHA_AFTER_UNWRAP=$(alice_locked_alpha "$TEST_NETUID" "$TEST_HOTKEY_SS58")
assert_ge "$LOCKED_ALPHA_AFTER_UNWRAP" "$((INITIAL_LOCKED_ALPHA / 100 * 99))" \
    "Alice's lock disturbed by receiving unwrapped alpha"
assert_ge "$INITIAL_LOCKED_ALPHA" "$LOCKED_ALPHA_AFTER_UNWRAP" \
    "Alice's lock grew from receiving unwrapped alpha (a lock arrived with the transfer)"
ok "Locked coldkey received $ALICE_RECEIVED_ALPHA RAO unlocked alpha (preview $PREVIEWED_HALF_ALPHA); lock intact"

log "Phase 10: unwrapForTao (removeStake rail) works while a large lock exists on the subnet"

REMAINING_SHARES=$(vault_shares "$TEST_TOKEN_ID")
PREVIEWED_REMAINING_ALPHA=$(cast call "$VAULT_ADDR" "previewUnwrap(uint256,uint256)(uint256,uint256)" \
    "$TEST_TOKEN_ID" "$REMAINING_SHARES" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')
REMAINING_TAO_QUOTE=$(alpha_to_tao_quote "$TEST_NETUID" "$PREVIEWED_REMAINING_ALPHA")

USER_TAO_WEI_BEFORE=$(user_tao_wei)
vault_send 2500000 "unwrapForTao failed on a subnet with active locks" \
    "unwrapForTao(uint256,uint256,uint256)" "$TEST_TOKEN_ID" "$REMAINING_SHARES" 0
USER_TAO_WEI_AFTER=$(user_tao_wei)

FINAL_SHARES=$(vault_shares "$TEST_TOKEN_ID")
[[ "$FINAL_SHARES" == "0" ]] || fail "shares still $FINAL_SHARES after unwrapForTao"
TAO_GAINED_WEI=$(assert_tao_gain "$USER_TAO_WEI_BEFORE" "$USER_TAO_WEI_AFTER" "$REMAINING_TAO_QUOTE" \
    "unwrapForTao payout off the alpha->TAO quote")
ok "Remaining shares exited as TAO: gained $TAO_GAINED_WEI wei (quote $REMAINING_TAO_QUOTE RAO)"

log "E2E complete (convicted alpha)"
echo "  AlphaVault:        $VAULT_ADDR"
echo "  Subnet under test: netuid $TEST_NETUID / tokenId $TEST_TOKEN_ID"
echo "  Alice lock:        $LOCKED_ALPHA_AFTER_UNWRAP RAO locked -> ${TEST_HOTKEY_SS58:0:12}..."
ok "All phases passed"
