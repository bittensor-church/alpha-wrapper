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
#   7. processDeposit → mint ERC1155 shares
#   8. Verify deposit balances
#   9. Withdraw all shares → verify alpha returned to user's substrate coldkey
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

# Capture the block range boundary before any event-emitting tx (setValidators,
# createSubnetProxy, processDeposit, rebalance, withdraw). Used by Phase 10 to
# narrow the get_logs range passed to the Python observability scripts.
BLOCK_START=$(cast block-number --rpc-url "$RPC_URL")
info "Observability block range start: $BLOCK_START"

forge build --quiet || fail "Build failed"
ok "Compiled"

MAILBOX_ADDR=$(forge create src/DepositMailbox.sol:DepositMailbox \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json 2>&1 \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "DepositMailbox: $MAILBOX_ADDR"

SUBNET_CLONE_ADDR=$(forge create src/SubnetClone.sol:SubnetClone \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json 2>&1 \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "SubnetClone: $SUBNET_CLONE_ADDR"

VAULT_ADDR=$(forge create src/AlphaVault.sol:AlphaVault \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
    --constructor-args "https://api.tao20.io/{id}.json" "$MAILBOX_ADDR" "$SUBNET_CLONE_ADDR" 2>&1 \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "AlphaVault: $VAULT_ADDR"

VAL_REGISTRY_ADDR=$(forge create src/ValidatorRegistry.sol:ValidatorRegistry \
    --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
    --constructor-args "$DEPLOYER_ADDR" "$DEPLOYER_ADDR" 2>&1 \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
ok "ValidatorRegistry: $VAL_REGISTRY_ADDR"

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

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    HK_A="${ALL_HK_B32S[$((i * 3 + 0))]}"
    HK_B="${ALL_HK_B32S[$((i * 3 + 1))]}"
    HK_C="${ALL_HK_B32S[$((i * 3 + 2))]}"
    cast send "$VAL_REGISTRY_ADDR" "setValidators(uint256,bytes32[],uint16[])" \
        "$NET" "[$HK_A,$HK_B,$HK_C]" "[5000,3000,2000]" \
        --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" \
        $CAST_FLAGS --json > /dev/null 2>&1
    ok "netuid $NET validators set (50/30/20): ${HK_A:0:18}..., ${HK_B:0:18}..., ${HK_C:0:18}..."
done

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

log "Phase 6: Transfer alpha → clone addresses"

CLONE_SUB_B32S=()

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    FIRST_IDX=$((i * 3))

    CLONE_ADDR=$(cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" \
        "$WRAPPER_ADDR" "$NET" --rpc-url "$RPC_URL")
    ok "netuid $NET clone: $CLONE_ADDR"

    CLONE_SUB=$(h160_to_substrate_b32 "$CLONE_ADDR")
    CLONE_SS58=$(h160_to_ss58 "$CLONE_ADDR")
    CLONE_SUB_B32S+=("$CLONE_SUB")
    ok "Clone SS58: $CLONE_SS58"

    echo "  Transferring $TRANSFER_AMOUNT alpha on netuid $NET → clone ..."
    HK_SS58="${ALL_HK_SS58S[$FIRST_IDX]}"
    RAW=$((TRANSFER_AMOUNT * 1000000000))
    transfer_stake_py "$CLONE_SS58" "$HK_SS58" "$NET" "$RAW" | tail -1

    CLONE_STAKE=$(cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" \
        "${ALL_HK_B32S[$FIRST_IDX]}" "$CLONE_SUB" "$NET" --rpc-url "$RPC_URL")
    [[ "$CLONE_STAKE" == "0" ]] && fail "Clone $CLONE_ADDR has 0 alpha after transfer"
    ok "Clone stake: $CLONE_STAKE RAO"
done

log "Phase 7: Process deposits"

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    CLONE_SUB="${CLONE_SUB_B32S[$i]}"

    TX_JSON=$(cast send "$VAULT_ADDR" \
        "processDeposit(address,uint256,bytes32)" \
        "$WRAPPER_ADDR" "$NET" "$CLONE_SUB" \
        --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
        $EVM_FLAGS --gas-limit 1000000 --json 2>&1 || true)

    STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
    if [[ "$STATUS" != "0x1" ]]; then
        echo "$TX_JSON"
        fail "processDeposit for netuid $NET failed (status=$STATUS)"
    fi
    ok "netuid $NET deposited"
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

    [[ "$SHARES" == "0" ]] && fail "netuid $NET: zero shares after processDeposit"
    [[ "$TOTAL"  == "0" ]] && fail "netuid $NET: zero totalStake after processDeposit"
    [[ "$PRICE"  == "0" ]] && fail "netuid $NET: zero sharePrice after processDeposit"

    SHARES_CACHE+=("$SHARES")
    DEPOSIT_TOTALS+=("$TOTAL")
done
ok "All 3 vaults have positive shares / totalStake / sharePrice"

log "Phase 9: Withdraw all shares → verify alpha returned"

TOLERANCE_RAO=10

for i in 0 1 2; do
    NET="${NETUIDS[$i]}"
    TID="${VAULT_IDS[$i]}"
    SHARES="${SHARES_CACHE[$i]}"
    DEPOSITED="${DEPOSIT_TOTALS[$i]}"

    info "netuid $NET: burning $SHARES shares (tokenId $TID)"

    TX_JSON=$(cast send "$VAULT_ADDR" \
        "withdraw(uint256,uint256,bytes32)" \
        "$TID" "$SHARES" "$WRAPPER_SUB_B32" \
        --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
        $EVM_FLAGS --gas-limit 2000000 --json 2>&1 || true)

    STATUS=$(echo "$TX_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
    if [[ "$STATUS" != "0x1" ]]; then
        echo "$TX_JSON"
        fail "withdraw for netuid $NET failed (status=$STATUS)"
    fi

    POST_SHARES=$(cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$TID" --rpc-url "$RPC_URL" | awk '{print $1}')
    [[ "$POST_SHARES" != "0" ]] && fail "netuid $NET: shares still $POST_SHARES after full withdraw"
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
NETUIDS_CSV=$(IFS=,; echo "${NETUIDS[*]}")

# Run a Python observability script, assert the number of CSV data rows equals
# `expected`. Script stderr (the "Found N events" summary) flows through to the
# terminal; stdout is captured and row-counted (awk ignores \r inside lines, so
# csv.DictWriter's \r\n terminators count correctly).
assert_script_rows() {
    local label="$1" expected="$2"; shift 2
    local out
    out=$("$@")
    local actual
    actual=$(awk 'END { print NR - 1 }' <<< "$out")
    if (( actual != expected )); then
        echo "--- output (first 5 lines) ---"
        head -5 <<< "$out"
        fail "$label: expected $expected rows, got $actual"
    fi
    ok "$label: $actual rows"
}

assert_script_rows "get_subnet_proxies" "$SUBNET_COUNT" \
    python3 scripts/get_subnet_proxies.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

assert_script_rows "get_deposits" "$SUBNET_COUNT" \
    python3 scripts/get_deposits.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

assert_script_rows "get_withdrawals" "$SUBNET_COUNT" \
    python3 scripts/get_withdrawals.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

assert_script_rows "get_validator_updates" "$SUBNET_COUNT" \
    python3 scripts/get_validator_updates.py \
        --rpc-url "$RPC_URL" --registry-address "$VAL_REGISTRY_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

assert_script_rows "get_validator_batch_updates" 0 \
    python3 scripts/get_validator_batch_updates.py \
        --rpc-url "$RPC_URL" --registry-address "$VAL_REGISTRY_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END"

assert_script_rows "get_volumes (by token_id)" "$SUBNET_COUNT" \
    python3 scripts/get_volumes.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END" --by token_id

assert_script_rows "get_volumes (by user)" 1 \
    python3 scripts/get_volumes.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --block-start "$BLOCK_START" --block-end "$BLOCK_END" --by user

assert_script_rows "get_vault_state" "$SUBNET_COUNT" \
    python3 scripts/get_vault_state.py \
        --rpc-url "$RPC_URL" --vault-address "$VAULT_ADDR" \
        --registry-address "$VAL_REGISTRY_ADDR" --netuids "$NETUIDS_CSV"

log "E2E complete"
echo "  AlphaVault:        $VAULT_ADDR"
echo "  DepositMailbox:    $MAILBOX_ADDR"
echo "  SubnetClone:       $SUBNET_CLONE_ADDR"
echo "  ValidatorRegistry: $VAL_REGISTRY_ADDR"
echo "  Subnets:           ${NETUIDS[*]}"
echo "  Token IDs:         ${VAULT_IDS[*]}"
echo "  Block range:       [$BLOCK_START, $BLOCK_END]"
ok "All phases passed"
