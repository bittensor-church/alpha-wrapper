#!/usr/bin/env python3

"""
Standalone CLI over the e2e framework's chain operations (address mapping +
substrate/EVM writes) driving the localnet chain.

The implementations live in the alpha_e2e package (used in-process by the
pytest e2e suite; see the docstrings there for full semantics); this wrapper
keeps each operation available as a shell command for manual localnet work.
Each subcommand prints its result to stdout; errors go to stderr and exit 1.

Subcommands:
    h160_to_substrate_b32   EVM address -> substrate account id (32-byte hex)
    h160_to_ss58            EVM address -> SS58 address (network prefix 42)
    transfer_stake          move staked alpha to another coldkey, as //Alice
    add_stake               stake TAO to a validator hotkey, as //Alice
    remove_stake            sell staked alpha back to the pool for TAO, as //Alice
    lock_stake              conviction-lock alpha to a hotkey, as //Alice
    get_lock                print a (coldkey, netuid, hotkey) lock's alpha amount
    set_validators          submit a signed validator-set update to the registry
    toggle_transfer         flip a subnet's alpha transfer toggle via Sudo
    set_admin_freeze_window set the global admin freeze window via Sudo
    dissolve_network        dissolve (deregister) a subnet via Sudo
"""

import argparse
import sys

from alpha_e2e import extrinsics, substrate, validators


def _run_extrinsic(operation) -> None:
    try:
        result = operation()
    except extrinsics.ExtrinsicError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
    print(result)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("h160_to_substrate_b32")
    p.add_argument("h160")

    p = sub.add_parser("h160_to_ss58")
    p.add_argument("h160")

    p = sub.add_parser("transfer_stake")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--dest-ss58", required=True)
    p.add_argument("--hotkey-ss58", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--alpha-amount", required=True, type=int)

    p = sub.add_parser("add_stake")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--hotkey-ss58", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--amount", required=True, type=int,
                   help="TAO amount to stake, in RAW (rao)")

    p = sub.add_parser("remove_stake")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--hotkey-ss58", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--amount", required=True, type=int,
                   help="alpha amount to unstake, in RAW (rao)")

    p = sub.add_parser("lock_stake")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--hotkey-ss58", required=True,
                   help="Conviction hotkey the lock points at")
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--amount", required=True, type=int,
                   help="Alpha amount to lock, in RAW (rao)")

    p = sub.add_parser("get_lock")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--coldkey-ss58", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--hotkey-ss58", required=True)

    p = sub.add_parser("toggle_transfer")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--enabled", required=True, choices=["true", "false"],
                   help="Whether alpha transfer_stake is allowed on the subnet")
    p.add_argument("--attempts", type=int, default=10)

    p = sub.add_parser("set_admin_freeze_window")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--window", required=True, type=int,
                   help="Terminal blocks per tempo during which admin ops are frozen (0 disables)")

    p = sub.add_parser("dissolve_network")
    p.add_argument("--chain-endpoint", required=True)
    p.add_argument("--netuid", required=True, type=int)

    p = sub.add_parser("set_validators")
    p.add_argument("--rpc-url", required=True)
    p.add_argument("--registry", required=True)
    p.add_argument("--signer-pk", required=True, action="append", dest="signer_pks",
                   help="Repeat for each signer. First listed pays the transaction.")
    p.add_argument("--netuid", required=True, type=int)
    p.add_argument("--hotkeys", required=True, help="Comma-separated bytes32 hex hotkeys")
    p.add_argument("--weights", required=True, help="Comma-separated BPS weights summing to 10000")

    args = parser.parse_args()

    if args.cmd == "h160_to_substrate_b32":
        print(substrate.h160_to_substrate_b32(args.h160))
    elif args.cmd == "h160_to_ss58":
        print(substrate.h160_to_ss58(args.h160))
    elif args.cmd == "transfer_stake":
        _run_extrinsic(lambda: "ok block=" + extrinsics.transfer_stake(
            args.dest_ss58, args.hotkey_ss58, args.netuid, args.alpha_amount,
            chain_endpoint=args.chain_endpoint,
        ))
    elif args.cmd == "add_stake":
        _run_extrinsic(lambda: "ok block=" + extrinsics.add_stake(
            args.hotkey_ss58, args.netuid, args.amount,
            chain_endpoint=args.chain_endpoint,
        ))
    elif args.cmd == "remove_stake":
        _run_extrinsic(lambda: "ok block=" + extrinsics.remove_stake(
            args.hotkey_ss58, args.netuid, args.amount,
            chain_endpoint=args.chain_endpoint,
        ))
    elif args.cmd == "lock_stake":
        _run_extrinsic(lambda: "ok block=" + extrinsics.lock_stake(
            args.hotkey_ss58, args.netuid, args.amount,
            chain_endpoint=args.chain_endpoint,
        ))
    elif args.cmd == "get_lock":
        print(extrinsics.get_lock(
            args.coldkey_ss58, args.netuid, args.hotkey_ss58,
            chain_endpoint=args.chain_endpoint,
        ))
    elif args.cmd == "toggle_transfer":
        _run_extrinsic(lambda: (
            f"ok netuid={args.netuid} toggle={args.enabled} block="
            + extrinsics.toggle_transfer(
                args.netuid, args.enabled == "true", attempts=args.attempts,
                chain_endpoint=args.chain_endpoint,
            )
        ))
    elif args.cmd == "set_admin_freeze_window":
        _run_extrinsic(lambda: (
            f"ok admin_freeze_window={args.window} block="
            + extrinsics.set_admin_freeze_window(
                args.window, chain_endpoint=args.chain_endpoint,
            )
        ))
    elif args.cmd == "dissolve_network":
        _run_extrinsic(lambda: (
            f"ok netuid={args.netuid} dissolved block="
            + extrinsics.dissolve_network(
                args.netuid, chain_endpoint=args.chain_endpoint,
            )
        ))
    elif args.cmd == "set_validators":
        try:
            transaction_hash = validators.set_validators(
                args.registry, args.signer_pks, args.netuid,
                args.hotkeys.split(","),
                [int(weight) for weight in args.weights.split(",")],
                rpc_url=args.rpc_url,
            )
        except validators.ValidatorUpdateError as error:
            print(f"FAIL: {error}", file=sys.stderr)
            sys.exit(1)
        print(f"ok netuid={args.netuid} signers={len(args.signer_pks)} tx={transaction_hash}")


if __name__ == "__main__":
    main()
