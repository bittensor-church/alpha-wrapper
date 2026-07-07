#!/usr/bin/env bash
# ============================================================================
# alpha-wrapper — Local Chain E2E: precompile-driven min-stake floor
# ============================================================================
# Proves the POC end-to-end against a live subtensor: the staking precompile's
# getStakeOperationThreshold() returns the chain's real min-stake (DefaultMinStake),
# and the vault reads it *live from inside the contract* to recognise stake the
# chain would refuse to move/transfer.
#
# The proof is bracketed — (1) the precompile alone, (2-5) the contract, (6) the
# chain alone — so the contract's own read is pinned between two independent
# cross-checks:
#   1. getStakeOperationThreshold() == the chain's DefaultMinStake (2e6 RAO).
#   2. With the owner fallback deliberately set to a DIFFERENT value (50e6), the
#      contract's effectiveStakeFloor() still returns 2e6 — only possible if
#      _stakeFloor() actually called the precompile.
#   3. Transfer rail: a wrap of a deposit worth MORE than the chain floor but LESS
#      than the fallback floor — i.e. in the (chain, fallback) gap — succeeds; it
#      would revert DepositTooSmall if the vault gated on the fallback.
#   4. Move rail: a rebalance move worth an amount in that same gap EXECUTES; it
#      would be skipped if gated on the fallback (isolated from the deposit gate
#      by sizing the deposit above the fallback floor).
#   5. Recognition: a rebalance whose corrective move is genuinely sub-floor is
#      SKIPPED — the vault recognises the unmovable stake and stays in-budget
#      rather than attempting a move the chain would reject.
#   6. The chain independently refuses a clearly sub-floor transfer_stake with
#      AmountTooLow — the same DefaultMinStake gate the precompile reports.
#
# Note: there is deliberately no "vault rejects a sub-floor deposit" assertion.
# On a live chain a sub-floor position cannot be created — every stake-creating
# op (including the transfer that seeds a deposit) enforces DefaultMinStake — so
# the vault's DepositTooSmall is only reachable inside a sub-RAO price-quantum
# gap. That boundary precision is covered by the mock unit tests; here we prove
# the live integration.
#
# Prerequisites:
#   - Local subtensor running at ws://127.0.0.1:9944, built from a runtime that
#     ships getStakeOperationThreshold() (group 1 fails loudly if it does not).
#   - btcli installed with Alice wallet (hotkey "default"); forge/cast; python3
#     with substrate-interface; funded EVM deployer (see e2e/e2e_common.sh).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

# The chain's DefaultMinStake (SubtensorInitialMinStake), in RAO. A runtime
# constant; group 1 asserts the precompile returns exactly this.
CHAIN_FLOOR_EXPECTED=2000000
# Owner fallback, deliberately far from the chain floor and below STAKE_FLOOR_CAP
# (100e6). The gap (2e6, 50e6) is where "gated on chain" and "gated on fallback"
# give observably different outcomes.
FALLBACK_SENTINEL=50000000

# ─── Local helpers ───────────────────────────────────────────────────────────

# uint256 view on the vault, decimal.
vault_uint() { cast call "$VAULT_ADDR" "$1" --rpc-url "$RPC_URL" | awk '{print $1}'; }

# Owner (deployer) tx to the vault; assert success.
owner_send() { # <gas> <fail_msg> <sig> [args...]
    local gas="$1" msg="$2" status
    shift 2
    status=$(cast send "$VAULT_ADDR" "$@" \
        --private-key "$DEPLOYER_PK" --rpc-url "$RPC_URL" \
        $EVM_FLAGS --gas-limit "$gas" --json \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "fail")
    [[ "$status" == "0x1" ]] || fail "$msg"
}

# Substrate coldkey a token's subnet clone stakes under, needed to read its stake.
clone_coldkey() { # <tokenId>
    local clone
    clone=$(cast call "$VAULT_ADDR" "subnetClone(uint256)(address)" "$1" --rpc-url "$RPC_URL")
    h160_to_substrate_b32 "$clone"
}

# Smallest alpha-RAO deposit whose TAO value clears FLOOR, from the live price.
# Used purely as a "≈ one chain-floor of TAO" unit for sizing deposits.
# Sets FLOOR_PRICE and FLOOR_BOUNDARY; requires FLOOR to be set first.
floor_boundary() { # <netuid> <phase_label>
    local netuid="$1" phase="$2"
    FLOOR_PRICE=$(cast call "$ALPHA_PRECOMPILE" "getAlphaPrice(uint16)(uint256)" "$netuid" --rpc-url "$RPC_URL" | awk '{print $1}')
    [[ "$FLOOR_PRICE" != "0" ]] || fail "$phase: alpha price reads 0 (oracle unavailable)"
    FLOOR_BOUNDARY=$(python3 -c "print(($FLOOR * 10**18 + $FLOOR_PRICE - 1) // $FLOOR_PRICE)")
}

e2e_bootstrap

# ─── 1. The precompile is live and returns the chain floor ───────────────────

log "1. Precompile returns the chain's DefaultMinStake"

if ! CHAIN_FLOOR=$(cast call "$STAKING" "getStakeOperationThreshold()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}'); then
    fail "getStakeOperationThreshold() call failed — the node's runtime does not ship the precompile view"
fi
[[ -n "$CHAIN_FLOOR" ]] || fail "getStakeOperationThreshold() returned nothing"
[[ "$CHAIN_FLOOR" == "$CHAIN_FLOOR_EXPECTED" ]] \
    || fail "getStakeOperationThreshold()=$CHAIN_FLOOR, expected $CHAIN_FLOOR_EXPECTED (chain DefaultMinStake)"
ok "getStakeOperationThreshold() = $CHAIN_FLOOR RAO (chain DefaultMinStake, precompile live)"

# ─── 2. The contract reads it live — disambiguated from the fallback ─────────

log "2. effectiveStakeFloor() reads the precompile, not the owner fallback"

owner_send 200000 "setMinStakeTaoFloor($FALLBACK_SENTINEL) failed" \
    "setMinStakeTaoFloor(uint256)" "$FALLBACK_SENTINEL"
STORED_FALLBACK=$(vault_uint "minStakeTaoFloor()(uint256)")
[[ "$STORED_FALLBACK" == "$FALLBACK_SENTINEL" ]] \
    || fail "minStakeTaoFloor()=$STORED_FALLBACK, expected the $FALLBACK_SENTINEL we just set"
info "owner fallback minStakeTaoFloor = $STORED_FALLBACK RAO (distinct from the chain floor)"

EFFECTIVE=$(vault_uint "effectiveStakeFloor()(uint256)")
[[ "$EFFECTIVE" == "$CHAIN_FLOOR" ]] \
    || fail "effectiveStakeFloor()=$EFFECTIVE, expected the chain floor $CHAIN_FLOOR (fallback is $STORED_FALLBACK — did the contract read the precompile?)"
ok "effectiveStakeFloor() = $EFFECTIVE RAO == chain floor, with the fallback at $STORED_FALLBACK -> the contract read the precompile"

# ─── 3. The contract gates the TRANSFER rail on the chain value ──────────────

log "3. Wrap gates the deposit on the chain floor, not the (higher) owner fallback"

T_NETUID="${NETUIDS[0]}"
T_HOTKEY="${ALL_HK_B32S[0]}"
T_HOTKEY_SS58="${ALL_HK_SS58S[0]}"
# Single-validator set so the whole deposit lands on one hotkey (no rebalance here).
set_validators_py "$T_NETUID" "$T_HOTKEY" "10000" > /dev/null
FLOOR=$CHAIN_FLOOR
floor_boundary "$T_NETUID" "Transfer rail"
info "chain-floor unit = $FLOOR_BOUNDARY alpha RAO (price $FLOOR_PRICE)"

# A deposit worth ~5x the chain floor — above chain (2e6), below fallback (50e6).
# Succeeds ONLY if the wrap gated on the chain floor (it would revert
# DepositTooSmall if gated on the 50e6 fallback).
GAP_DEPOSIT=$((FLOOR_BOUNDARY * 5))
deposit_and_wrap "$T_NETUID" "$T_HOTKEY" "$T_HOTKEY_SS58" "$GAP_DEPOSIT" 1500000 \
    "3: gap-deposit wrap reverted — vault gated on the $FALLBACK_SENTINEL fallback, not the chain floor"
ok "3: deposit worth ~5x the chain floor wrapped while the fallback was $FALLBACK_SENTINEL -> gated on the chain value"

# ─── 4. The contract gates the MOVE rail on the chain value ──────────────────

log "4. Rebalance executes a move gated on the chain floor, not the fallback"

M_NETUID="${NETUIDS[1]}"
M_TOKEN_ID="${VAULT_IDS[1]}"
M_OVER="${ALL_HK_B32S[3]}"
M_UNDER="${ALL_HK_B32S[4]}"
M_OVER_SS58="${ALL_HK_SS58S[3]}"
# 50/50 target: the whole deposit lands on M_OVER, then ~half must move to M_UNDER.
set_validators_py "$M_NETUID" "$M_OVER,$M_UNDER" "5000,5000" > /dev/null
FLOOR=$CHAIN_FLOOR
floor_boundary "$M_NETUID" "Move rail (execute)"

# Deposit worth ~30x the chain floor (~60e6 TAO) clears the deposit gate under
# EITHER gating (> the 50e6 fallback), so only the ~half corrective move (~30e6,
# in the (2e6, 50e6) gap) can distinguish chain- from fallback-gating.
M_DEPOSIT=$((FLOOR_BOUNDARY * 30))
deposit_and_wrap "$M_NETUID" "$M_OVER" "$M_OVER_SS58" "$M_DEPOSIT" 2500000 \
    "4: move-rail wrap failed"
M_CLONE_COLDKEY=$(clone_coldkey "$M_TOKEN_ID")
M_UNDER_STAKE=$(get_stake "$M_UNDER" "$M_CLONE_COLDKEY" "$M_NETUID")
[[ "$M_UNDER_STAKE" != "0" ]] \
    || fail "4: corrective move (~15x floor) was skipped — vault gated the move on the $FALLBACK_SENTINEL fallback, not the chain floor"
ok "4: rebalance moved ~15x the chain floor to the under-validator ($M_UNDER_STAKE RAO) while the fallback was $FALLBACK_SENTINEL -> moveStake gated on the chain value"

# ─── 5. The contract recognises unmovable stake and skips the move ───────────

log "5. Rebalance skips a genuinely sub-floor move (recognises unmovable stake)"

S_NETUID="${NETUIDS[2]}"
S_TOKEN_ID="${VAULT_IDS[2]}"
S_OVER="${ALL_HK_B32S[6]}"
S_UNDER="${ALL_HK_B32S[7]}"
S_OVER_SS58="${ALL_HK_SS58S[6]}"
set_validators_py "$S_NETUID" "$S_OVER,$S_UNDER" "5000,5000" > /dev/null
FLOOR=$CHAIN_FLOOR
floor_boundary "$S_NETUID" "Move rail (skip)"

# Deposit worth ~1.5x the chain floor: clears the deposit gate, but the ~half
# corrective move (~0.75x floor) is genuinely sub-floor, so the vault must skip
# it (a chain moveStake would revert AmountTooLow) and leave the split drifted.
S_DEPOSIT=$((FLOOR_BOUNDARY * 3 / 2))
deposit_and_wrap "$S_NETUID" "$S_OVER" "$S_OVER_SS58" "$S_DEPOSIT" 1500000 \
    "5: sub-floor-move wrap failed (doomed move attempted instead of skipped?)"
S_CLONE_COLDKEY=$(clone_coldkey "$S_TOKEN_ID")
S_UNDER_STAKE=$(get_stake "$S_UNDER" "$S_CLONE_COLDKEY" "$S_NETUID")
[[ "$S_UNDER_STAKE" == "0" ]] \
    || fail "5: a sub-floor move was executed ($S_UNDER_STAKE RAO moved) — vault did not recognise it as unmovable"
ok "5: vault recognised the sub-floor corrective move as unmovable and skipped it (under-validator stayed 0)"

# ─── 6. The chain independently refuses the same threshold ───────────────────

log "6. The chain refuses a sub-floor transfer_stake (unmovable/untransferable)"

R_NETUID="${NETUIDS[0]}"
R_HOTKEY_SS58="${ALL_HK_SS58S[0]}"
FLOOR=$CHAIN_FLOOR
floor_boundary "$R_NETUID" "Chain refusal"

# Half the chain-floor unit is unambiguously sub-floor even at full chain
# precision (the unit is computed from the quantised EVM price), so the chain
# must reject the transfer.
R_SUBFLOOR=$((FLOOR_BOUNDARY / 2))
[[ "$R_SUBFLOOR" -gt 0 ]] || fail "6: floor unit too small to halve ($FLOOR_BOUNDARY)"
if transfer_stake_py "$DEPLOYER_SS58" "$R_HOTKEY_SS58" "$R_NETUID" "$R_SUBFLOOR" > /dev/null 2>&1; then
    fail "6: a clearly sub-floor transfer_stake ($R_SUBFLOOR alpha RAO) did NOT revert — chain did not enforce AmountTooLow"
fi
ok "6: chain refused a clearly sub-floor transfer_stake ($R_SUBFLOOR alpha RAO) with AmountTooLow"

# Control: the same op with a clearly above-floor amount succeeds.
R_ABOVE=$((FLOOR_BOUNDARY * 3))
transfer_stake_py "$DEPLOYER_SS58" "$R_HOTKEY_SS58" "$R_NETUID" "$R_ABOVE" | tail -1
ok "6: chain accepted an above-floor transfer_stake ($R_ABOVE alpha RAO) — the same gate, above the threshold"

log "E2E (precompile min-stake floor) complete"
ok "Precompile returns the chain floor; the contract reads it live and gates both rails on it; it recognises unmovable stake and skips; the chain enforces the same threshold"
