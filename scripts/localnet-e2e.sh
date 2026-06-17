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
# Usage:
#   chmod +x scripts/localnet-e2e.sh
#   ./scripts/localnet-e2e.sh
# ============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

CHAIN_ENDPOINT="ws://127.0.0.1:9944"
RPC_URL="http://127.0.0.1:9944"
CHAIN_ID=42

ALICE_WALLET="alice"
ALICE_HOTKEY_NAME="default"
# Substrate dev Alice: 5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY
ALICE_COLDKEY_SEED="0xe5be9a5092b81bca64be81d212e7f2f9eba183bb7a90954f7b76361f6edb5c0a"
ALICE_COLDKEY_B32="0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d"

# Well-known localnet-only keys (not secrets).
DEPLOYER_ADDR="0x7bD3E0F025FC388e08dd2A63595dbcaB486F335b"
DEPLOYER_PK="0x58a595a0863f6894cf22d465014abf7c7ca5b46fc8dd7e7e932d158002c33039"
DEPLOYER_SS58="5CroES7MYzgDoY6VFJct81eEPT2yQH3T6czzfmD5DD78wffA"

WRAPPER_ADDR="0xd10375caed456c5902D7B155117Dd155398145C7"
WRAPPER_PK="0xf784bf897e423437b1d2a1584a7fc5c99b0ec3f34d70ff74a0643094ccfd4bbe"
WRAPPER_SS58="5H9xN1Y6KqdhcK9wPqFSPHC7yeaRC5y4CL3nNF2GX6hJrmpT"

STAKING="0x0000000000000000000000000000000000000805"

STAKE_RATIOS=(600 400 200)
TRANSFER_AMOUNT=100
HK_SUFFIXES=(a b c)

# Bittensor EVM: gas estimation fails; always use legacy tx with explicit gas.
EVM_FLAGS="--legacy --gas-price 10000000000"
FORGE_FLAGS="$EVM_FLAGS --gas-limit 5000000 --broadcast"
CAST_FLAGS="$EVM_FLAGS --gas-limit 500000"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
ok()   { echo -e "  \033[1;32m✓\033[0m $1"; }
info() { echo -e "  \033[0;33m→\033[0m $1"; }
fail() { echo -e "  \033[1;31m✗ $1\033[0m"; exit 1; }

h160_to_substrate_b32() { python3 scripts/e2e_helpers.py h160_to_substrate_b32 "$1"; }
h160_to_ss58()          { python3 scripts/e2e_helpers.py h160_to_ss58 "$1"; }

btcli_cmd() { btcli "$@" --network "$CHAIN_ENDPOINT"; }

transfer_stake_py() {
    python3 scripts/e2e_helpers.py transfer_stake \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --dest-ss58 "$1" \
        --hotkey-ss58 "$2" \
        --netuid "$3" \
        --alpha-amount "$4"
}

set_validators_py() {
    python3 scripts/e2e_helpers.py set_validators \
        --rpc-url "$RPC_URL" \
        --registry "$VAL_REGISTRY_ADDR" \
        --signer-pk "$DEPLOYER_PK" \
        --signer-pk "$WRAPPER_PK" \
        --netuid "$1" \
        --hotkeys "$2" \
        --weights "$3"
}

create_subnet() {
    printf '\n\n\n\n\n\n\n\n\n\n' | btcli_cmd subnets create \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" \
        --no-mev-protection \
        --no-prompt --subnet-name "$1" 2>&1
}

read_hotkey_pubkey() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('publicKey',''))"
}

read_hotkey_ss58() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('ss58Address',''))"
}

# ─── Pre-flight ──────────────────────────────────────────────────────────────

log "Pre-flight checks"
cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1 || fail "Cannot connect to $RPC_URL"
ok "Chain reachable (chain-id: $(cast chain-id --rpc-url "$RPC_URL"))"
ok "Deployer balance: $(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

# Ensure alice wallet is the dev Alice. Regen from seed if missing or wrong.
ALICE_COLDKEY_FILE="$HOME/.bittensor/wallets/$ALICE_WALLET/coldkeypub.txt"
NEED_REGEN=false

if [[ ! -d "$HOME/.bittensor/wallets/$ALICE_WALLET" ]]; then
    NEED_REGEN=true
elif [[ -f "$ALICE_COLDKEY_FILE" ]]; then
    if ! grep -q "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY" "$ALICE_COLDKEY_FILE" 2>/dev/null; then
        echo "  ⚠ Existing alice wallet is NOT the dev Alice — regenerating from dev seed..."
        rm -rf "$HOME/.bittensor/wallets/$ALICE_WALLET"
        NEED_REGEN=true
    fi
else
    NEED_REGEN=true
fi

if [[ "$NEED_REGEN" == "true" ]]; then
    echo "  Setting up dev Alice wallet from seed..."
    btcli wallet regen-coldkey --wallet-name "$ALICE_WALLET" \
        --wallet-path "$HOME/.bittensor/wallets" \
        --seed "$ALICE_COLDKEY_SEED" --no-use-password --overwrite 2>&1 | tail -3
    [[ -f "$HOME/.bittensor/wallets/$ALICE_WALLET/coldkeypub.txt" ]] || fail "Failed to regenerate Alice coldkey"
    ok "Alice coldkey regenerated from dev seed (5Grwva...)"
fi

if [[ ! -f "$HOME/.bittensor/wallets/$ALICE_WALLET/hotkeys/$ALICE_HOTKEY_NAME" ]]; then
    echo "  Creating hotkey '$ALICE_HOTKEY_NAME' for wallet '$ALICE_WALLET'..."
    btcli wallet new-hotkey --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" \
        --n-words 12 --no-use-password 2>&1 | tail -1
    ok "Created hotkey '$ALICE_HOTKEY_NAME'"
else
    ok "Alice hotkey '$ALICE_HOTKEY_NAME' exists"
fi
ok "Alice wallet ready"

FUND_AMOUNT=10000

DEPLOYER_BAL=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether)
[[ -n "$DEPLOYER_BAL" ]] || fail "Could not read deployer balance"
DEPLOYER_BAL_INT=$(echo "$DEPLOYER_BAL" | python3 -c "import sys; print(int(sys.stdin.read().strip().split('.')[0]))")

if [[ "$DEPLOYER_BAL_INT" -lt 50 ]]; then
    log "Phase 0: Fund deployer (${FUND_AMOUNT} TAO)"
    btcli_cmd wallet transfer \
        --wallet-name "$ALICE_WALLET" \
        --dest "$DEPLOYER_SS58" \
        --amount "$FUND_AMOUNT" \
        --allow-death \
        --no-prompt 2>&1 | tail -2
    ok "Transferred ${FUND_AMOUNT} TAO → $DEPLOYER_ADDR ($DEPLOYER_SS58)"
    ok "New balance: $(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether) TAO"
else
    log "Phase 0: Deployer already funded"
    ok "Balance: ${DEPLOYER_BAL} TAO (>50, skipping transfer)"
fi

log "Phase 1: Create 3 subnets"
NETUIDS=()
for i in 1 2 3; do
    echo "  Creating subnet alpha_e2e_$i ..."
    OUTPUT=$(create_subnet "alpha_e2e_$i")
    NETUID=$(echo "$OUTPUT" | sed -n 's/.*netuid: \([0-9]*\).*/\1/p' | tail -1)
    [[ -z "$NETUID" ]] && { echo "  $OUTPUT"; fail "Could not extract netuid"; }
    NETUIDS+=("$NETUID")
    ok "netuid $NETUID"
done

log "Start emissions + increase max_regs_per_block"
for NETUID in "${NETUIDS[@]}"; do
    btcli_cmd subnets start --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" --no-prompt 2>&1 | tail -1
    ok "netuid $NETUID emissions started"

    btcli_cmd sudo set --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --param max_regs_per_block --value 8 --no-prompt 2>&1 | tail -1
    ok "netuid $NETUID max_regs_per_block → 8"
done

log "Phase 2: Hotkeys & validators (3 per subnet)"

# Flat arrays: index = subnet_idx * 3 + suffix_idx
ALL_HK_NAMES=()
ALL_HK_B32S=()
ALL_HK_SS58S=()

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    SUBNET_NUM=$((i + 1))

    for j in 0 1 2; do
        SUFFIX="${HK_SUFFIXES[$j]}"
        HK="hk_e2e_${SUBNET_NUM}${SUFFIX}"
        IDX=$((i * 3 + j))

        [[ ! -f "$HOME/.bittensor/wallets/$ALICE_WALLET/hotkeys/$HK" ]] && \
            btcli wallet new-hotkey --wallet-name "$ALICE_WALLET" --hotkey "$HK" \
                --n-words 12 --no-use-password 2>&1 | tail -1

        # Retry register with 6s block delay — rate-limited even at max_regs_per_block=8.
        for attempt in 1 2 3; do
            REG_OUT=$(btcli_cmd subnets register --netuid "$NET" --wallet-name "$ALICE_WALLET" --hotkey "$HK" --no-prompt 2>&1)
            if echo "$REG_OUT" | grep -q "Registered\|Already"; then
                break
            fi
            echo "  Retry $attempt for $HK (waiting for next block)..."
            sleep 6
        done
        if ! echo "$REG_OUT" | grep -q "Registered\|Already"; then
            echo "$REG_OUT"
            fail "register failed for $HK on netuid $NET after 3 attempts"
        fi

        ALL_HK_NAMES+=("$HK")
        ALL_HK_B32S+=("$(read_hotkey_pubkey "$ALICE_WALLET" "$HK")")
        ALL_HK_SS58S+=("$(read_hotkey_ss58 "$ALICE_WALLET" "$HK")")
        ok "$HK registered on netuid $NET: ${ALL_HK_B32S[$IDX]:0:18}..."
    done
done

log "Phase 3: Stake TAO per validator (ratio 3:2:1)"

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"

    for j in 0 1 2; do
        IDX=$((i * 3 + j))
        AMOUNT="${STAKE_RATIOS[$j]}"
        HK="${ALL_HK_NAMES[$IDX]}"

        btcli_cmd stake add --wallet-name "$ALICE_WALLET" --hotkey "$HK" \
            --amount "$AMOUNT" --netuid "$NET" --no-mev-protection \
            --no-prompt --unsafe 2>&1 | tail -2
        STAKE=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" \
            "${ALL_HK_B32S[$IDX]}" "$ALICE_COLDKEY_B32" "$NET" --rpc-url "$RPC_URL")
        ok "netuid $NET $HK: ${AMOUNT} TAO → $STAKE RAO"
    done
done

log "Phase 4: Deploy"

# Block range for Phase 10 observability scripts.
BLOCK_START=$(cast block-number --rpc-url "$RPC_URL")
info "Observability block range start: $BLOCK_START"

forge build --quiet || fail "Build failed"
ok "Compiled"

MAILBOX_ADDR=$(forge create src/DepositMailbox.sol:DepositMailbox \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "DepositMailbox: $MAILBOX_ADDR"

SUBNET_CLONE_ADDR=$(forge create src/SubnetClone.sol:SubnetClone \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "SubnetClone: $SUBNET_CLONE_ADDR"

VAULT_ADDR=$(forge create src/AlphaVault.sol:AlphaVault \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
    --constructor-args "https://api.tao20.io/{id}.json" "$MAILBOX_ADDR" "$SUBNET_CLONE_ADDR" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "AlphaVault: $VAULT_ADDR"

# DEPLOYER (0x7bD3...) < WRAPPER (0xd103...) hex-ascending — required by ValidatorRegistry's sorted-signers check.
VAL_REGISTRY_ADDR=$(forge create src/ValidatorRegistry.sol:ValidatorRegistry \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
    --constructor-args "$DEPLOYER_ADDR" "[$DEPLOYER_ADDR,$WRAPPER_ADDR]" 2 \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "ValidatorRegistry: $VAL_REGISTRY_ADDR (admin=$DEPLOYER_ADDR, signers=[DEPLOYER,WRAPPER], threshold=2)"

VAULT_IDS=()
for NET in "${NETUIDS[@]}"; do
    TID=$(cast call "$VAULT_ADDR" "currentTokenId(uint256)(uint256)" "$NET" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}')
    [[ -z "$TID" || "$TID" == "0" ]] && fail "currentTokenId returned 0 for netuid $NET (subnet not registered?)"
    VAULT_IDS+=("$TID")
    info "netuid $NET -> tokenId $TID"
done

cast send "$VAULT_ADDR" "setValidatorRegistry(address)" \
    "$VAL_REGISTRY_ADDR" \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" \
    $CAST_FLAGS --json > /dev/null 2>&1
ok "Vault → ValidatorRegistry linked"

REG_BLOCK_START=$(cast block-number --rpc-url "$RPC_URL")
for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    HK_A="${ALL_HK_B32S[$((i * 3 + 0))]}"
    HK_B="${ALL_HK_B32S[$((i * 3 + 1))]}"
    HK_C="${ALL_HK_B32S[$((i * 3 + 2))]}"
    set_validators_py "$NET" "$HK_A,$HK_B,$HK_C" "5000,3000,2000" > /dev/null
    ok "netuid $NET validators set (50/30/20): ${HK_A:0:18}..., ${HK_B:0:18}..., ${HK_C:0:18}..."
done
REG_BLOCK_END=$(cast block-number --rpc-url "$RPC_URL")

for NET in "${NETUIDS[@]}"; do
    cast send "$VAULT_ADDR" "createSubnetProxy(uint256)" \
        "$NET" \
        --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" \
        $CAST_FLAGS --json > /dev/null 2>&1
    ok "Subnet proxy created for netuid $NET"
done

log "Phase 5: Fund user account"

ok "User account: $WRAPPER_ADDR"

WRAPPER_BAL=$(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" --ether)
[[ -n "$WRAPPER_BAL" ]] || fail "Could not read wrapper balance"
WRAPPER_BAL_INT=$(echo "$WRAPPER_BAL" | python3 -c "import sys; print(int(sys.stdin.read().strip().split('.')[0]))")

if [[ "$WRAPPER_BAL_INT" -lt 5 ]]; then
    btcli_cmd wallet transfer \
        --wallet-name "$ALICE_WALLET" \
        --dest "$WRAPPER_SS58" \
        --amount 100 \
        --allow-death \
        --no-prompt 2>&1 | tail -2
    ok "Transferred 100 TAO → $WRAPPER_ADDR ($WRAPPER_SS58)"
else
    ok "Already funded: ${WRAPPER_BAL} TAO"
fi
ok "Balance: $(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

WRAPPER_SUB_B32=$(h160_to_substrate_b32 "$WRAPPER_ADDR")
info "Wrapper substrate coldkey: $WRAPPER_SUB_B32"

log "Phase 6: Transfer alpha to clone addresses (split across 3 validators)"

PER_HOTKEY_RAW=$((TRANSFER_AMOUNT * 1000000000 / 3))

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    CLONE_ADDR=$(cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" \
        "$WRAPPER_ADDR" "$NET" --rpc-url "$RPC_URL")
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

        CLONE_STAKE=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" \
            "$HK_B32" "$CLONE_SUB" "$NET" --rpc-url "$RPC_URL")
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

        TX_JSON=$(cast send "$VAULT_ADDR" \
            "wrap(address,uint256,bytes32)" \
            "$WRAPPER_ADDR" "$NET" "$CHOSEN_HK" \
            --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
            $EVM_FLAGS --gas-limit 1000000 --json || true)

        STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
        if [[ "$STATUS" != "0x1" ]]; then
            echo "$TX_JSON"
            fail "wrap for netuid $NET, hotkey ${CHOSEN_HK:0:18}... failed (status=$STATUS)"
        fi
        ok "netuid $NET deposited under ${CHOSEN_HK:0:18}..."
    done
done

log "Phase 8: Verify deposits"

SHARES_CACHE=()
DEPOSIT_TOTALS=()

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    TID="${VAULT_IDS[$i]}"
    SHARES=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$TID" --rpc-url "$RPC_URL" | awk '{print $1}')
    TOTAL=$(cast call "$VAULT_ADDR" "totalStake(uint256)(uint256)" "$TID" --rpc-url "$RPC_URL" | awk '{print $1}')
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

    TX_JSON=$(cast send "$VAULT_ADDR" \
        "unwrap(uint256,uint256,bytes32)" \
        "$TID" "$SHARES" "$WRAPPER_SUB_B32" \
        --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
        $EVM_FLAGS --gas-limit 2000000 --json || true)

    STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
    if [[ "$STATUS" != "0x1" ]]; then
        echo "$TX_JSON"
        fail "unwrap for netuid $NET failed (status=$STATUS)"
    fi

    POST_SHARES=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$TID" --rpc-url "$RPC_URL" | awk '{print $1}')
    [[ "$POST_SHARES" != "0" ]] && fail "netuid $NET: shares still $POST_SHARES after full unwrap"
    ok "netuid $NET: shares burned"

    SUM=0
    for j in 0 1 2; do
        IDX=$((i * 3 + j))
        HK_B32="${ALL_HK_B32S[$IDX]}"
        BAL=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" \
            "$HK_B32" "$WRAPPER_SUB_B32" "$NET" --rpc-url "$RPC_URL" | awk '{print $1}')
        SUM=$((SUM + BAL))
    done

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

RECLAIM_MAILBOX=$(cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" \
    "$WRAPPER_ADDR" "$RECLAIM_NET" --rpc-url "$RPC_URL")
RECLAIM_MAILBOX_SUB=$(h160_to_substrate_b32 "$RECLAIM_MAILBOX")
RECLAIM_MAILBOX_SS58=$(h160_to_ss58 "$RECLAIM_MAILBOX")
info "User mailbox on netuid $RECLAIM_NET: $RECLAIM_MAILBOX"

RECLAIM_AMOUNT_RAW=$((TRANSFER_AMOUNT * 1000000000 / 3))
info "Transferring $RECLAIM_AMOUNT_RAW RAO from Alice → mailbox under ${RECLAIM_HK_B32:0:18}..."
transfer_stake_py "$RECLAIM_MAILBOX_SS58" "$RECLAIM_HK_SS58" "$RECLAIM_NET" "$RECLAIM_AMOUNT_RAW" | tail -1

MAILBOX_ALPHA_PRE=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" \
    "$RECLAIM_HK_B32" "$RECLAIM_MAILBOX_SUB" "$RECLAIM_NET" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$MAILBOX_ALPHA_PRE" -gt 0 ]] || fail "mailbox has zero alpha before reclaim"
ok "Mailbox stake before: $MAILBOX_ALPHA_PRE RAO"

USER_TAO_PRE=$(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')
info "User EVM balance before: $USER_TAO_PRE wei"

TX_JSON=$(cast send "$VAULT_ADDR" \
    "reclaimMailboxAlphaAsTao(uint256,bytes32,uint256)" \
    "$RECLAIM_NET" "$RECLAIM_HK_B32" 0 \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 1500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "reclaimMailboxAlphaAsTao failed (status=$STATUS)"
fi

MAILBOX_ALPHA_POST=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" \
    "$RECLAIM_HK_B32" "$RECLAIM_MAILBOX_SUB" "$RECLAIM_NET" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$MAILBOX_ALPHA_POST" == "0" ]] || fail "mailbox still holds $MAILBOX_ALPHA_POST RAO after reclaim"
ok "Mailbox alpha drained to 0"

USER_TAO_POST=$(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')
info "User EVM balance after:  $USER_TAO_POST wei"
GAINED=$(python3 -c "print($USER_TAO_POST - $USER_TAO_PRE)")
# Bash arithmetic is signed 64-bit; wei deltas routinely exceed 2^63-1, so compare via Python.
python3 -c "import sys; sys.exit(0 if $GAINED > 0 else 1)" \
    || fail "user did not gain TAO from reclaim (net change: $GAINED wei)"
ok "User gained $GAINED wei (net of gas)"

log "Phase 12: Unwrap shares for TAO"

WFT_NET="${NETUIDS[1]}"
WFT_TID="${VAULT_IDS[1]}"
WFT_HK_IDX=3
WFT_HK_B32="${ALL_HK_B32S[$WFT_HK_IDX]}"
WFT_HK_SS58="${ALL_HK_SS58S[$WFT_HK_IDX]}"

WFT_MAILBOX=$(cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" \
    "$WRAPPER_ADDR" "$WFT_NET" --rpc-url "$RPC_URL")
WFT_MAILBOX_SS58=$(h160_to_ss58 "$WFT_MAILBOX")
info "User mailbox on netuid $WFT_NET: $WFT_MAILBOX"

WFT_AMOUNT_RAW=$((TRANSFER_AMOUNT * 1000000000 / 3))
info "Transferring $WFT_AMOUNT_RAW RAO from Alice → mailbox under ${WFT_HK_B32:0:18}..."
transfer_stake_py "$WFT_MAILBOX_SS58" "$WFT_HK_SS58" "$WFT_NET" "$WFT_AMOUNT_RAW" | tail -1

TX_JSON=$(cast send "$VAULT_ADDR" \
    "wrap(address,uint256,bytes32)" \
    "$WRAPPER_ADDR" "$WFT_NET" "$WFT_HK_B32" \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 1500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "wrap for unwrapForTao setup failed (status=$STATUS)"
fi

WFT_SHARES=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" \
    "$WRAPPER_ADDR" "$WFT_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$WFT_SHARES" != "0" ]] || fail "no shares minted by wrap on netuid $WFT_NET"
ok "Minted shares: $WFT_SHARES"

USER_TAO_PRE=$(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')
info "User EVM balance before: $USER_TAO_PRE wei"

TX_JSON=$(cast send "$VAULT_ADDR" \
    "unwrapForTao(uint256,uint256,uint256)" \
    "$WFT_TID" "$WFT_SHARES" 0 \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 2500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "unwrapForTao failed (status=$STATUS)"
fi

WFT_SHARES_POST=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" \
    "$WRAPPER_ADDR" "$WFT_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$WFT_SHARES_POST" == "0" ]] || fail "shares still $WFT_SHARES_POST after unwrapForTao"
ok "Shares burned to 0"

USER_TAO_POST=$(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')
info "User EVM balance after:  $USER_TAO_POST wei"
GAINED=$(python3 -c "print($USER_TAO_POST - $USER_TAO_PRE)")
python3 -c "import sys; sys.exit(0 if $GAINED > 0 else 1)" \
    || fail "user did not gain TAO from unwrapForTao (net change: $GAINED wei)"
ok "User gained $GAINED wei (net of gas)"

log "Phase 13: Emission accrual → share-price appreciation (alpha rail)"

# Real emissions accrue on the clone's staked alpha over blocks: the position must appreciate
# above the deposit, and the holder must be able to unwrap that gain. Mocks fake emissions,
# so only a live chain exercises this core value-accrual property.
EMIT_NET="${NETUIDS[0]}"
EMIT_TID="${VAULT_IDS[0]}"

EMIT_MAILBOX=$(cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" \
    "$WRAPPER_ADDR" "$EMIT_NET" --rpc-url "$RPC_URL")
info "Transferring 50 alpha from Alice → mailbox under ${ALL_HK_B32S[0]:0:18}..."
transfer_stake_py "$(h160_to_ss58 "$EMIT_MAILBOX")" "${ALL_HK_SS58S[0]}" "$EMIT_NET" 50000000000 | tail -1

TX_JSON=$(cast send "$VAULT_ADDR" \
    "wrap(address,uint256,bytes32)" \
    "$WRAPPER_ADDR" "$EMIT_NET" "${ALL_HK_B32S[0]}" \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 1500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "Phase 13 wrap failed (status=$STATUS)"
fi

EMIT_SHARES=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$EMIT_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
EMIT_DEPOSITED=$(cast call "$VAULT_ADDR" "totalStake(uint256)(uint256)" "$EMIT_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
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
EMIT_BEFORE=0
for j in 0 1 2; do
    BAL=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" "${ALL_HK_B32S[$j]}" "$WRAPPER_SUB_B32" "$EMIT_NET" --rpc-url "$RPC_URL" | awk '{print $1}')
    EMIT_BEFORE=$((EMIT_BEFORE + BAL))
done

TX_JSON=$(cast send "$VAULT_ADDR" \
    "unwrap(uint256,uint256,bytes32)" \
    "$EMIT_TID" "$EMIT_SHARES" "$WRAPPER_SUB_B32" \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 2000000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "Phase 13 unwrap failed (status=$STATUS)"
fi

EMIT_AFTER=0
for j in 0 1 2; do
    BAL=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" "${ALL_HK_B32S[$j]}" "$WRAPPER_SUB_B32" "$EMIT_NET" --rpc-url "$RPC_URL" | awk '{print $1}')
    EMIT_AFTER=$((EMIT_AFTER + BAL))
done
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

ROT_MAILBOX=$(cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" \
    "$WRAPPER_ADDR" "$ROT_NET" --rpc-url "$RPC_URL")
info "Transferring 60 alpha from Alice → mailbox under ${ROT_HK0:0:18}..."
transfer_stake_py "$(h160_to_ss58 "$ROT_MAILBOX")" "${ALL_HK_SS58S[3]}" "$ROT_NET" 60000000000 | tail -1

TX_JSON=$(cast send "$VAULT_ADDR" \
    "wrap(address,uint256,bytes32)" \
    "$WRAPPER_ADDR" "$ROT_NET" "$ROT_HK0" \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 1500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "Phase 14 wrap failed (status=$STATUS)"
fi

ROT_SHARES=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$ROT_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
ROT_DEPOSITED=$(cast call "$VAULT_ADDR" "totalStake(uint256)(uint256)" "$ROT_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
ROT_CLONE=$(cast call "$VAULT_ADDR" "subnetClone(uint256)(address)" "$ROT_TID" --rpc-url "$RPC_URL")
ROT_CLONE_SUB=$(h160_to_substrate_b32 "$ROT_CLONE")
ROT_ORPHAN=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" "$ROT_HK2" "$ROT_CLONE_SUB" "$ROT_NET" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$ROT_ORPHAN" != "0" ]] || fail "Phase 14: no stake under the 3rd validator to orphan"
ok "Deposited 60 alpha → shares=$ROT_SHARES; clone holds $ROT_ORPHAN RAO under the soon-orphaned 3rd validator"

# Drop the 3rd validator from the registry via a real EIP-712 attestation; no vault call runs,
# so the vault's last-seen snapshot still references it and its stake becomes an orphan.
set_validators_py "$ROT_NET" "$ROT_HK0,$ROT_HK1" "6000,4000" > /dev/null
ok "Rotated registry → [v0, v1]; 3rd validator dropped with $ROT_ORPHAN RAO orphaned"

ROT_BEFORE=0
for HK in "$ROT_HK0" "$ROT_HK1" "$ROT_HK2"; do
    BAL=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" "$HK" "$WRAPPER_SUB_B32" "$ROT_NET" --rpc-url "$RPC_URL" | awk '{print $1}')
    ROT_BEFORE=$((ROT_BEFORE + BAL))
done

TX_JSON=$(cast send "$VAULT_ADDR" \
    "unwrap(uint256,uint256,bytes32)" \
    "$ROT_TID" "$ROT_SHARES" "$WRAPPER_SUB_B32" \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 2000000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "Phase 14 unwrap failed (status=$STATUS)"
fi

ROT_AFTER=0
for HK in "$ROT_HK0" "$ROT_HK1" "$ROT_HK2"; do
    BAL=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" "$HK" "$WRAPPER_SUB_B32" "$ROT_NET" --rpc-url "$RPC_URL" | awk '{print $1}')
    ROT_AFTER=$((ROT_AFTER + BAL))
done
ROT_RECEIVED=$((ROT_AFTER - ROT_BEFORE))
ROT_ORPHAN_POST=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" "$ROT_HK2" "$ROT_CLONE_SUB" "$ROT_NET" --rpc-url "$RPC_URL" | awk '{print $1}')

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

SLIP_MAILBOX=$(cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" \
    "$WRAPPER_ADDR" "$SLIP_NET" --rpc-url "$RPC_URL")
info "Transferring 40 alpha from Alice → mailbox under ${ALL_HK_B32S[6]:0:18}..."
transfer_stake_py "$(h160_to_ss58 "$SLIP_MAILBOX")" "${ALL_HK_SS58S[6]}" "$SLIP_NET" 40000000000 | tail -1

TX_JSON=$(cast send "$VAULT_ADDR" \
    "wrap(address,uint256,bytes32)" \
    "$WRAPPER_ADDR" "$SLIP_NET" "${ALL_HK_B32S[6]}" \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 1500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "Phase 15 wrap failed (status=$STATUS)"
fi

SLIP_SHARES=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$SLIP_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$SLIP_SHARES" != "0" ]] || fail "Phase 15: no shares minted"
ok "Deposited 40 alpha → shares=$SLIP_SHARES"

# An unsatisfiable minTaoOut (1e30 wei) must revert and leave the shares untouched.
TX_JSON=$(cast send "$VAULT_ADDR" \
    "unwrapForTao(uint256,uint256,uint256)" \
    "$SLIP_TID" "$SLIP_SHARES" 1000000000000000000000000000000 \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 2500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
[[ "$STATUS" != "0x1" ]] || fail "Phase 15: unwrapForTao with minTaoOut=1e30 did NOT revert"
SLIP_SHARES_AFTER=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$SLIP_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$SLIP_SHARES_AFTER" == "$SLIP_SHARES" ]] || fail "Phase 15: shares changed after a reverted unwrapForTao ($SLIP_SHARES → $SLIP_SHARES_AFTER)"
ok "Slippage guard rejected an unsatisfiable minTaoOut; shares preserved ($SLIP_SHARES)"

# minTaoOut=0 succeeds against the real realized price; the user gains native TAO.
SLIP_TAO_PRE=$(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')
TX_JSON=$(cast send "$VAULT_ADDR" \
    "unwrapForTao(uint256,uint256,uint256)" \
    "$SLIP_TID" "$SLIP_SHARES" 0 \
    --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
    $EVM_FLAGS --gas-limit 2500000 --json || true)
STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
if [[ "$STATUS" != "0x1" ]]; then
    echo "$TX_JSON"
    fail "Phase 15 unwrapForTao(minTaoOut=0) failed (status=$STATUS)"
fi
SLIP_SHARES_FINAL=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$SLIP_TID" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$SLIP_SHARES_FINAL" == "0" ]] || fail "Phase 15: shares not burned ($SLIP_SHARES_FINAL)"
SLIP_TAO_POST=$(cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')
SLIP_GAINED=$(python3 -c "print($SLIP_TAO_POST - $SLIP_TAO_PRE)")
python3 -c "import sys; sys.exit(0 if $SLIP_GAINED > 0 else 1)" \
    || fail "Phase 15: user did not gain TAO (net $SLIP_GAINED wei)"
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
