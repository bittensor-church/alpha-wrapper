"""Scenario: TAO the chain strands on the vault becomes claimable by holders.

When the chain's dust threshold is raised by governance, small stake entries
are force-sold and the vault's subnet account receives native TAO that no
vault operation paid out. The vault must credit exactly the holders present
at that moment, let them withdraw it, and give none of it to later
depositors.

The threshold raise clears sub-threshold nominations on EVERY subnet and
force-sells the vault's whole (deliberately tiny) position. Nothing on chain
records that as the cause, so the attesters acknowledge the loss before the
position can be retired. The test restores the threshold it found and then
retires the swept position's shares, so sibling suites sharing the session
localnet see the subnet in a normal state.
"""
import pytest

from alpha_e2e import chain, checks, config, extrinsics

# The mainnet factor: threshold = 0.002 TAO * factor / 1e6 = 0.02 TAO, far above
# the per-validator slices the deposit below leaves on each validator.
RAISED_THRESHOLD_FACTOR = 10_000_000

# One RAO in EVM wei: native TAO balances move at this granularity.
RAO_WEI = 10**9


@pytest.mark.scenario
def test_root_sweep_tao_becomes_claimable(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkey_pubkey = env.hotkey_pubkeys[0]
    hotkey_ss58 = env.hotkey_ss58s[0]

    # A deposit sized so every per-validator slice sits far below the raised
    # threshold, but comfortably above the deposit floor.
    _, floor_boundary_alpha = env.floor_boundary(netuid, env.chain_min_stake_tao())
    deposit = floor_boundary_alpha * 3 // 2
    env.deposit_and_wrap(netuid, hotkey_pubkey, hotkey_ss58, deposit, 1_500_000, "Sweep: wrap failed")
    print(f"  Wrapped {deposit} alpha RAO on netuid {netuid}")

    clone_evm = env.clone_address(token_id)
    clone_balance_before = chain.cast_balance_wei(clone_evm)

    def claimable_tao() -> int:
        return int(chain.cast_call(
            env.vault_address, "claimableTaoOf(address,uint256)(uint256)",
            config.WRAPPER_USER_ADDRESS, token_id,
        ))

    previous_factor = extrinsics.get_nominator_min_required_stake()
    extrinsics.set_nominator_min_required_stake(RAISED_THRESHOLD_FACTOR)
    try:
        stranded = chain.cast_balance_wei(clone_evm) - clone_balance_before
        print(f"  Clearing pass stranded {stranded} wei on the subnet clone")
        assert stranded > 0, "expected the clearing pass to strand TAO on the clone"

        # The view quotes at RAO granularity, so it can sit up to one RAO below the raw
        # stranded amount (index flooring plus the RAO floor of the quote).
        claimable = claimable_tao()
        assert claimable % RAO_WEI == 0, f"claimable {claimable} is not RAO-granular"
        assert 0 <= stranded - claimable <= RAO_WEI, (
            f"claimable {claimable} != stranded {stranded} floored to the RAO"
        )

        user_balance_before = env.user_tao_wei()
        receipt = env.vault_send(
            1_500_000, "Sweep: claim failed",
            "claimTao(uint256,address)", token_id, config.WRAPPER_USER_ADDRESS,
        )
        delivered = checks.reconstructed_payout(
            user_balance_before, env.user_tao_wei(), receipt, "Sweep: claim payout",
        )
        print(f"  Claim delivered {delivered} wei")
        # The quote is a commitment: the claim delivers exactly what the view promised, and the
        # sub-RAO remainder stays reserved for the claimant below the quote's one-RAO floor.
        assert delivered == claimable, f"delivered {delivered} != quoted {claimable}"
        remaining = claimable_tao()
        assert remaining == 0, f"quote not cleared after claim: {remaining}"
    finally:
        # A raise here would mask the test's own assertion error; report and move on instead.
        try:
            extrinsics.set_nominator_min_required_stake(previous_factor)
        except Exception as restore_error:  # noqa: BLE001
            print(f"  WARNING: dust threshold not restored to {previous_factor}: {restore_error}")

    # A sweep leaves nothing on chain naming where the alpha went, and a hotkey swap whose edge the
    # chain has since cleared looks identical, so the vault will not guess and holds the
    # expectation. What it must not do is shut the holder in over it: the exit below runs with the
    # shortfall standing and no attester involved.
    swept_short = not env.backing_intact(token_id)
    if swept_short:
        print("  Position reads short by design; exiting anyway against the located "
              f"{env.vault_total_stake(token_id)} alpha RAO")

    # The clearing pass empties the vault's position but its shares remain outstanding. How
    # empty depends on the runtime build: an exactly-zero position retires shares through the
    # zero-backing unwrap, while a sub-floor residue exits through the TAO rail's full-drain sale.
    all_shares = env.vault_shares(token_id)
    if env.vault_total_stake(token_id) == 0:
        env.vault_send(
            2_500_000, "Sweep: cleanup unwrap failed",
            "unwrap(uint256,uint256,bytes32)", token_id, all_shares, env.wrapper_substrate_coldkey,
        )
    else:
        env.vault_send(
            2_500_000, "Sweep: cleanup unwrap failed",
            "unwrapForTao(uint256,uint256,uint256)", token_id, all_shares, 0,
        )
    assert env.vault_total_supply(token_id) == 0, "cleanup left outstanding shares"

    # Only new deposits wait on the attesters. Acknowledging the loss starts the window they wait
    # out; the approval is a real 2-of-2 EIP-712 message, signed and spent against the live chain.
    if swept_short:
        env.write_down_backing(token_id, 0)
        opens_from = env.deposits_open_from(token_id)
        assert opens_from > 0, "the acknowledgement did not start the deposit window"
        print(f"  Attesters acknowledged the loss; deposits reopen at {opens_from}")
