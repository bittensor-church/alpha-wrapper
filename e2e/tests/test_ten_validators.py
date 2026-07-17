"""Scenario: the core user flow against a ten-validator set.

The registry accepts attested sets of up to 64 validators; this scenario runs
the basic wrap/unwrap flow against a ten-validator set with distinct weights:

  - seven extra hotkeys registered next to the bootstrap's three
  - all ten attested in one EIP-712 update
  - wrap: the deposit spreads across all ten validators by weight
  - unwrap: the user receives the whole backing back, every slot drained

Setup (chain, subnets, validators, contracts, funding) is the session `env`
fixture (alpha_e2e.bootstrap.build_environment); this test picks up right after it.
"""
import pytest

from alpha_e2e import bootstrap, checks, config
from alpha_e2e.checks import run_observability_script

VALIDATOR_COUNT = 10
VALIDATOR_WEIGHTS = [1900, 1700, 1500, 1300, 1100, 900, 700, 400, 300, 200]
DEPOSIT_RAO = 60_000_000_000
# Ten balance reads plus nine alignment moves dominate the wrap; the unwrap adds
# the gather hops. The bounds hold headroom over that, while a rejected dispatch
# (which burns everything forwarded to it) still overshoots them.
TEN_VALIDATOR_WRAP_GAS_BOUND = 2_500_000
TEN_VALIDATOR_UNWRAP_GAS_BOUND = 3_500_000
# A wrap or unwrap touches up to one slot per validator and each touch can round
# a RAO away.
ROUNDING_TOLERANCE_RAO = config.ROUNDING_DUST_SLOT_RAO * VALIDATOR_COUNT


@pytest.mark.scenario
def test_ten_validators(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]

    # --- Register seven extra hotkeys next to the bootstrap's three -------------
    # Registration is rate-limited per interval as well as per block; lift the
    # interval target so seven back-to-back registrations land quickly.
    # Best-effort: register_hotkey retries across intervals anyway, this only
    # shortens the wait.
    bootstrap.set_subnet_hyperparameter(netuid, "target_regs_per_interval", 10, check=False)

    hotkey_pubkeys = list(env.subnet_hotkey_pubkeys(0))
    for suffix in ("d", "e", "f", "g", "h", "i", "j"):
        hotkey_name = f"hk_e2e_1{suffix}"
        pubkey, _ = bootstrap.register_hotkey(netuid, hotkey_name)
        hotkey_pubkeys.append(pubkey)
        print(f"  {hotkey_name} registered on netuid {netuid}: {pubkey[:18]}...")
    assert len(hotkey_pubkeys) == VALIDATOR_COUNT

    # --- Attest all ten validators in one update ---------------------------------
    env.set_validators(netuid, hotkey_pubkeys, VALIDATOR_WEIGHTS)
    resolved_validators = env.current_validators(netuid)
    assert len(resolved_validators) == VALIDATOR_COUNT, (
        f"vault resolves {len(resolved_validators)} validators, expected {VALIDATOR_COUNT}"
    )
    checks.assert_csv(
        run_observability_script(
            "get_vault_state", "--netuid", str(netuid),
            address_args=[
                "--vault-address", env.vault_address,
                "--registry-address", env.validator_registry_address,
            ],
        ),
        rows=1,
        column_eq={"token_id": str(token_id), "validators_count": str(VALIDATOR_COUNT)},
    )
    print(f"  netuid {netuid} attested with {VALIDATOR_COUNT} validators")

    # --- Wrap a deposit -> stake spreads across all ten validators by weight -----
    wrap_receipt = env.deposit_and_wrap(
        netuid, hotkey_pubkeys[0], env.hotkey_ss58s[0], DEPOSIT_RAO,
        4_000_000, "ten-validator wrap failed",
    )
    checks.assert_gas_within(
        wrap_receipt, TEN_VALIDATOR_WRAP_GAS_BOUND, "ten-validator wrap gas",
    )

    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the ten-validator wrap"
    deposited = env.vault_total_stake(token_id)
    assert deposited >= DEPOSIT_RAO - ROUNDING_TOLERANCE_RAO, (
        f"wrap lost more than rounding dust ({deposited} of {DEPOSIT_RAO})"
    )
    print(f"  Wrapped: shares={shares}, totalStake={deposited} RAO")

    # Targets derive from the transferred amount, not the live total: emissions
    # accrued since the wrap only push slot balances up, so the lower bounds stay
    # stable.
    clone_coldkey = env.clone_coldkey(token_id)
    for index, (hotkey_pubkey, weight) in enumerate(zip(hotkey_pubkeys, VALIDATOR_WEIGHTS)):
        slot_stake = env.stake(hotkey_pubkey, clone_coldkey, netuid)
        target = DEPOSIT_RAO * weight // 10_000
        assert slot_stake >= target - 1_000, (
            f"validator {index} below its weight target ({slot_stake} < ~{target})"
        )
        print(f"  validator {index} holds {slot_stake} RAO (target ~{target})")

    last_seen = env.last_seen_hotkeys(token_id)
    assert len(last_seen) == VALIDATOR_COUNT, (
        f"remembered set has {len(last_seen)} entries, expected {VALIDATOR_COUNT}"
    )
    print(f"  Remembered set tracks all {VALIDATOR_COUNT} validators")

    # --- Unwrap all shares -> the whole backing comes back, every slot drained ---
    delivered_before = env.total_stake_across(
        env.wrapper_substrate_coldkey, netuid, hotkey_pubkeys,
    )
    unwrap_receipt = env.vault_send(
        5_000_000, "ten-validator unwrap failed",
        "unwrap(uint256,uint256,bytes32)", token_id, shares, env.wrapper_substrate_coldkey,
    )
    checks.assert_gas_within(
        unwrap_receipt, TEN_VALIDATOR_UNWRAP_GAS_BOUND, "ten-validator unwrap gas",
    )

    remaining_shares = env.vault_shares(token_id)
    assert remaining_shares == 0, f"shares still {remaining_shares} after full unwrap"

    delivered_after = env.total_stake_across(
        env.wrapper_substrate_coldkey, netuid, hotkey_pubkeys,
    )
    received = delivered_after - delivered_before
    assert received >= deposited - ROUNDING_TOLERANCE_RAO, (
        f"user received {received} RAO of {deposited} deposited"
    )
    print(f"  User received {received} RAO across ten validators (deposited {deposited})")

    for index, hotkey_pubkey in enumerate(hotkey_pubkeys):
        slot_stake = env.stake(hotkey_pubkey, clone_coldkey, netuid)
        assert slot_stake <= config.ROUNDING_DUST_SLOT_RAO, (
            f"clone slot {index} still holds {slot_stake} RAO after full unwrap"
        )
    print("  All ten clone slots drained to dust")
