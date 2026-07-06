#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper — Local Chain E2E shared library
# ============================================================================
#
# Sourced by the localnet e2e test scripts. Holds everything the tests share:
#   - Configuration (well-known localnet keys, contract/staking constants)
#   - Logging + chain read/write helpers (cast/btcli/substrate-interface wrappers)
#   - e2e_bootstrap: pre-flight + phases 0-5 (fund deployer, create subnets,
#     register validators, stake, deploy contracts, fund the user account).
#
# After `source e2e/e2e_common.sh; e2e_bootstrap`, the following globals are
# populated for the test to drive its own scenario:
#   NETUIDS, VAULT_IDS, ALL_HK_NAMES/ALL_HK_B32S/ALL_HK_SS58S,
#   MAILBOX_ADDR, SUBNET_CLONE_ADDR, VAULT_ADDR, VAL_REGISTRY_ADDR,
#   WRAPPER_SUB_B32, BLOCK_START, REG_BLOCK_START, REG_BLOCK_END.
#
# All relative paths (scripts/..., src/...) assume the repo root is the CWD,
# i.e. the test is invoked as `./e2e/<test>.sh` from the project root.
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
# Alpha precompile (index 2056): exposes the chain's own alpha→TAO swap simulation.
ALPHA_PRECOMPILE="0x0000000000000000000000000000000000000808"

STAKE_RATIOS=(600 400 200)
TRANSFER_AMOUNT=100
# Per-validator transfer amount in RAO (TRANSFER_AMOUNT TAO split across the 3 validators).
PER_HOTKEY_RAW=$((TRANSFER_AMOUNT * 1000000000 / 3))
HK_SUFFIXES=(a b c)

# Bittensor EVM: gas estimation fails; always use legacy tx with explicit gas.
EVM_FLAGS="--legacy --gas-price 10000000000"
FORGE_FLAGS="$EVM_FLAGS --gas-limit 5000000 --broadcast"
CAST_FLAGS="$EVM_FLAGS --gas-limit 500000"

# Subtensor's EVM omits `mixHash` from eth_getBlockByNumber, so forge/cast's
# receipt-wait block poller logs a benign deserialization ERROR per broadcast.
# Silence that module; keep error-level logging otherwise.
export RUST_LOG="${RUST_LOG:-error,alloy_provider::blocks=off}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
ok()   { echo -e "  \033[1;32m✓\033[0m $1"; }
info() { echo -e "  \033[0;33m→\033[0m $1"; }
fail() { echo -e "  \033[1;31m✗ $1\033[0m" >&2; exit 1; }

h160_to_substrate_b32() { python3 scripts/chain_ops.py h160_to_substrate_b32 "$1"; }
h160_to_ss58()          { python3 scripts/chain_ops.py h160_to_ss58 "$1"; }

btcli_cmd() { btcli "$@" --network "$CHAIN_ENDPOINT"; }

transfer_stake_py() {
    python3 scripts/chain_ops.py transfer_stake \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --dest-ss58 "$1" \
        --hotkey-ss58 "$2" \
        --netuid "$3" \
        --alpha-amount "$4"
}

# Stake TAO from Alice via a direct extrinsic. Recent btcli's `stake add` queries
# `Swap.AlphaSqrtPrice`, which localnet runtimes may lack — this path has no such
# dependency.
add_stake_py() { # <hotkey_ss58> <netuid> <amount_rao>
    python3 scripts/chain_ops.py add_stake \
        --chain-endpoint "$CHAIN_ENDPOINT" \
        --hotkey-ss58 "$1" \
        --netuid "$2" \
        --amount "$3"
}

set_validators_py() {
    python3 scripts/chain_ops.py set_validators \
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

# ─── Chain read/write wrappers (DRY helpers over cast) ────────────────────────

# Alpha stake for a single (hotkey, coldkey, netuid) from the staking precompile.
get_stake() { # <hotkey_b32> <coldkey_b32> <netuid>
    cast call "$STAKING" "getStake(bytes32,bytes32,uint256)(uint256)" "$1" "$2" "$3" \
        --rpc-url "$RPC_URL" | awk '{print $1}'
}

# Total alpha stake for a coldkey summed across one or more hotkeys on a subnet.
sum_stake() { # <coldkey_b32> <netuid> <hotkey_b32>...
    local coldkey="$1" netuid="$2" total=0 hk bal
    shift 2
    for hk in "$@"; do
        bal=$(get_stake "$hk" "$coldkey" "$netuid")
        total=$((total + bal))
    done
    echo "$total"
}

# User's ERC1155 share balance for a tokenId.
vault_shares() { # <tokenId>
    cast call "$VAULT_ADDR" "balanceOf(address,uint256)(uint256)" "$WRAPPER_ADDR" "$1" \
        --rpc-url "$RPC_URL" | awk '{print $1}'
}

# Vault's tracked total alpha for a tokenId.
vault_total_stake() { # <tokenId>
    cast call "$VAULT_ADDR" "totalStake(uint256)(uint256)" "$1" --rpc-url "$RPC_URL" | awk '{print $1}'
}

# Deterministic per-user mailbox deposit address for a subnet.
mailbox_addr() { # <netuid>
    cast call "$VAULT_ADDR" "getDepositAddress(address,uint256)(address)" "$WRAPPER_ADDR" "$1" \
        --rpc-url "$RPC_URL"
}

# User's native TAO balance, in wei.
user_tao_wei() {
    cast balance "$WRAPPER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}'
}

# Broadcast a tx to the vault from the user key; capture the JSON receipt and its status in
# LAST_TX_RECEIPT / LAST_TX_STATUS ("fail" if the send or receipt parse errored).
vault_broadcast() { # <gas_limit> <sig> [args...]
    local gas="$1" sig="$2"
    shift 2
    LAST_TX_RECEIPT=$(cast send "$VAULT_ADDR" "$sig" "$@" \
        --private-key "$WRAPPER_PK" --rpc-url "$RPC_URL" \
        $EVM_FLAGS --gas-limit "$gas" --json || true)
    LAST_TX_STATUS=$(echo "$LAST_TX_RECEIPT" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
}

# Send a tx to the vault from the user key and assert it succeeded (status 0x1).
vault_send() { # <gas_limit> <fail_msg> <sig> [args...]
    local gas="$1" msg="$2"
    shift 2
    vault_broadcast "$gas" "$@"
    [[ "$LAST_TX_STATUS" == "0x1" ]] || { echo "$LAST_TX_RECEIPT"; fail "$msg"; }
}

# Send a tx to the vault that is EXPECTED to revert; assert it did not succeed.
vault_send_expect_revert() { # <gas_limit> <fail_msg> <sig> [args...]
    local gas="$1" msg="$2"
    shift 2
    vault_broadcast "$gas" "$@"
    [[ "$LAST_TX_STATUS" != "0x1" ]] || fail "$msg"
}

# Assert a strictly positive wei delta and echo it. Wei deltas routinely exceed bash's
# signed-64-bit range, so the comparison is done in Python.
assert_gain() { # <pre_wei> <post_wei> <fail_msg>
    local delta
    delta=$(python3 -c "print($2 - $1)")
    python3 -c "import sys; sys.exit(0 if $delta > 0 else 1)" || fail "$3 (net $delta wei)"
    echo "$delta"
}

# Chain's own alpha→TAO quote (RAO out) for selling <alpha_rao> on <netuid>. Capture it *before*
# the swap that pays out: simSwapAlphaForTao re-prices against live reserves and the curve is
# concave, so a quote taken after the swap understates the payout by its own price impact
# (a ~33 alpha exit re-quotes ~13% low — past assert_tao_gain's ±10%).
alpha_to_tao_quote() { # <netuid> <alpha_rao>
    cast call "$ALPHA_PRECOMPILE" "simSwapAlphaForTao(uint16,uint64)(uint256)" "$1" "$2" \
        --rpc-url "$RPC_URL" | awk '{print $1}'
}

# Assert the caller's native-TAO gain ≈ a pre-captured alpha→TAO <quote_rao> (within ±10%, which
# absorbs gas and a block or two of emission drift) — a real value check, not just a positive
# delta. The precompile quotes in RAO, so ×1e9 → wei. Echoes the wei gain.
assert_tao_gain() { # <pre_wei> <post_wei> <quote_rao> <fail_msg>
    local gain
    gain=$(python3 -c "print($2 - $1)")
    python3 -c "import sys; e=$3*10**9; sys.exit(0 if e*9//10 <= $gain <= e*11//10 else 1)" \
        || fail "$4 (gained $gain wei, quote $3 RAO)"
    echo "$gain"
}

# Transfer alpha from Alice into the user's mailbox under a hotkey, then wrap it into the vault.
deposit_and_wrap() { # <netuid> <hotkey_b32> <hotkey_ss58> <amount_raw> <gas_limit> <fail_msg>
    local netuid="$1" hk_b32="$2" hk_ss58="$3" amount="$4" gas="$5" msg="$6" mailbox
    mailbox=$(mailbox_addr "$netuid")
    info "Transferring $amount RAO from Alice → mailbox under ${hk_b32:0:18}..."
    transfer_stake_py "$(h160_to_ss58 "$mailbox")" "$hk_ss58" "$netuid" "$amount" | tail -1
    vault_send "$gas" "$msg" "wrap(address,uint256,bytes32)" "$WRAPPER_ADDR" "$netuid" "$hk_b32"
}

# ─── Bootstrap: pre-flight + phases 0-5 ──────────────────────────────────────
#
# Brings a fresh localnet to the point where a position can be deposited: funded
# deployer, 3 emitting subnets with 3 registered+staked validators each, deployed
# contracts wired to a 2-of-2 ValidatorRegistry, and a funded user account.
e2e_bootstrap() {
    # All bootstrap/helper paths are repo-root-relative; fail fast if invoked elsewhere.
    [[ -f scripts/chain_ops.py && -d src ]] || fail "Run from the repo root (CWD must contain scripts/ and src/)."

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

    # Fast-runtime's admin freeze window lets owner/root hyperparameter writes (max_regs_per_block
    # below, TransferToggle in the transfers-off test) land only near each subnet's epoch boundary
    # and otherwise silently miss (see set_admin_freeze_window). Disable it so they apply first try.
    log "Disable admin freeze window (deterministic sudo hyperparameter writes)"
    python3 scripts/chain_ops.py set_admin_freeze_window \
        --chain-endpoint "$CHAIN_ENDPOINT" --window 0 | tail -1
    ok "AdminFreezeWindow → 0"

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

            add_stake_py "${ALL_HK_SS58S[$IDX]}" "$NET" "$((AMOUNT * 1000000000))" | tail -1
            STAKE=$(get_stake "${ALL_HK_B32S[$IDX]}" "$ALICE_COLDKEY_B32" "$NET")
            [[ "$STAKE" -gt 0 ]] || fail "stake add landed but $HK reads 0 RAO on netuid $NET"
            ok "netuid $NET $HK: ${AMOUNT} TAO → $STAKE RAO"
        done
    done

    log "Phase 4: Deploy"

    # Capture the deploy block so a downstream observability phase can scope its event queries.
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

    # DEPLOYER (0x7bD3...) < WRAPPER (0xd103...) hex-ascending — required by ValidatorRegistry's sorted-signers check.
    VAL_REGISTRY_ADDR=$(forge create src/ValidatorRegistry.sol:ValidatorRegistry \
        --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
        --constructor-args "$DEPLOYER_ADDR" "[$DEPLOYER_ADDR,$WRAPPER_ADDR]" 2 \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
    ok "ValidatorRegistry: $VAL_REGISTRY_ADDR (admin=$DEPLOYER_ADDR, signers=[DEPLOYER,WRAPPER], threshold=2)"

    # AlphaVault binds the registry as an immutable constructor arg (setValidatorRegistry was
    # removed), so ValidatorRegistry must be deployed first.
    VAULT_ADDR=$(forge create src/AlphaVault.sol:AlphaVault \
        --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" $FORGE_FLAGS --json \
        --constructor-args "https://api.tao20.io/{id}.json" "$MAILBOX_ADDR" "$SUBNET_CLONE_ADDR" "$VAL_REGISTRY_ADDR" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])")
    ok "AlphaVault: $VAULT_ADDR"

    VAULT_IDS=()
    for NET in "${NETUIDS[@]}"; do
        TID=$(cast call "$VAULT_ADDR" "currentTokenId(uint256)(uint256)" "$NET" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}')
        [[ -z "$TID" || "$TID" == "0" ]] && fail "currentTokenId returned 0 for netuid $NET (subnet not registered?)"
        VAULT_IDS+=("$TID")
        info "netuid $NET -> tokenId $TID"
    done

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
}
