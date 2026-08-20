"""The deployed-localnet handle every scenario drives.

Environment bundles the addresses and ids produced by
bootstrap.build_environment() with typed on-chain getters (stakes, shares,
prices, quotes) and scenario actions (vault sends, deposits, share transfers,
validator rotations, revert assertions).
"""
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

from . import chain, config, extrinsics, substrate, validators


def read_stake(hotkey_pubkey: str, coldkey_pubkey: str, netuid: int) -> int:
    """Alpha stake (RAO) for a single (hotkey, coldkey, netuid) from the
    staking precompile."""
    return int(chain.cast_call(
        config.STAKING_PRECOMPILE, "getStake(bytes32,bytes32,uint256)(uint256)",
        hotkey_pubkey, coldkey_pubkey, netuid,
    ))


@dataclass
class Environment:
    netuids: List[int]
    token_ids: List[int]
    # Flat, parallel lists: index = subnet_index * VALIDATORS_PER_SUBNET + validator_index.
    hotkey_names: List[str]
    hotkey_pubkeys: List[str]
    hotkey_ss58s: List[str]
    vault_address: str
    mailbox_implementation_address: str
    subnet_clone_implementation_address: str
    validator_registry_address: str
    wrapper_substrate_coldkey: str
    observation_block_start: int
    registry_block_start: int
    registry_block_end: int

    # --- On-chain getters -----------------------------------------------------
    def subnet_hotkey_pubkeys(self, subnet_index: int) -> List[str]:
        """The three validator hotkeys registered on the subnet at `subnet_index`."""
        start = subnet_index * config.VALIDATORS_PER_SUBNET
        return self.hotkey_pubkeys[start:start + config.VALIDATORS_PER_SUBNET]

    def stake(self, hotkey_pubkey: str, coldkey_pubkey: str, netuid: int) -> int:
        """Alpha stake (RAO) for a single (hotkey, coldkey, netuid) from the
        staking precompile."""
        return read_stake(hotkey_pubkey, coldkey_pubkey, netuid)

    def total_stake_across(
        self, coldkey_pubkey: str, netuid: int, hotkey_pubkeys: List[str],
    ) -> int:
        """Total alpha stake (RAO) for a coldkey summed across hotkeys on a subnet."""
        return sum(
            self.stake(hotkey_pubkey, coldkey_pubkey, netuid)
            for hotkey_pubkey in hotkey_pubkeys
        )

    def vault_shares(self, token_id: int, holder: Optional[str] = None) -> int:
        """ERC1155 share balance of `holder` (default: the wrapper user)."""
        return int(chain.cast_call(
            self.vault_address, "balanceOf(address,uint256)(uint256)",
            holder or config.WRAPPER_USER_ADDRESS, token_id,
        ))

    def vault_total_supply(self, token_id: int) -> int:
        return int(chain.cast_call(
            self.vault_address, "totalSupply(uint256)(uint256)", token_id,
        ))

    def vault_total_stake(self, token_id: int) -> int:
        """The vault's tracked total alpha (RAO) for a token id. Refuses while the position cannot
        account for itself; use `vault_located_stake` to read it in that state."""
        return int(chain.cast_call(
            self.vault_address, "totalStake(uint256)(uint256)", token_id,
        ))

    def vault_located_stake(self, token_id: int) -> int:
        """Alpha (RAO) the vault can currently find for a token id, short or not."""
        return int(chain.cast_call(
            self.vault_address, "locatedStake(uint256)(uint256)", token_id,
        ))

    def share_price(self, token_id: int) -> int:
        return int(chain.cast_call(
            self.vault_address, "sharePrice(uint256)(uint256)", token_id,
        ))

    def mailbox_address(self, netuid: int, user: Optional[str] = None) -> str:
        """Deterministic mailbox deposit address for `user` (default: the wrapper
        user) on a subnet."""
        return chain.cast_call(
            self.vault_address, "getDepositAddress(address,uint256)(address)",
            user or config.WRAPPER_USER_ADDRESS, netuid,
        )

    def clone_address(self, token_id: int) -> str:
        """Per-token subnet clone address holding the position's alpha."""
        return chain.cast_call(
            self.vault_address, "subnetClone(uint256)(address)", token_id,
        )

    def clone_coldkey(self, token_id: int) -> str:
        """Substrate coldkey a token's subnet clone stakes under, needed to read
        its on-chain stake."""
        return substrate.h160_to_substrate_b32(self.clone_address(token_id))

    def preview_unwrap(self, token_id: int, shares: int) -> Tuple[int, int]:
        """(alpha RAO, native-TAO wei) legs an unwrap of `shares` would pay out."""
        lines = chain.cast_call_lines(
            self.vault_address, "previewUnwrap(uint256,uint256)(uint256,uint256)",
            token_id, shares,
        )
        return int(lines[0]), int(lines[1])

    def chain_min_stake_tao(self) -> int:
        """The minimum the vault reads on every floor check. A runtime constant."""
        return int(chain.cast_call(config.STAKING_PRECOMPILE, "getDefaultMinStake()(uint256)"))

    def backing_intact(self, token_id: int) -> bool:
        """Whether the vault can account for the alpha it expects under every
        validator it records."""
        return chain.cast_call(
            self.vault_address, "isBackingIntact(uint256)(bool)", token_id,
        ).strip() == "true"

    def hotkey_in_last_seen(self, token_id: int, hotkey_pubkey: str) -> bool:
        """Whether the vault's remembered validator set still references `hotkey_pubkey`."""
        remembered = chain.run(
            ["cast", "call", self.vault_address, "lastSeenHotkeys(uint256)(bytes32[])",
             str(token_id), "--rpc-url", config.RPC_URL],
        ).stdout
        return hotkey_pubkey.removeprefix("0x").lower() in remembered.lower()

    def alpha_price(self, netuid: int) -> int:
        """Current alpha price for a subnet (TAO per alpha, e18 scale)."""
        return int(chain.cast_call(
            config.ALPHA_PRECOMPILE, "getAlphaPrice(uint16)(uint256)", netuid,
        ))

    def alpha_in_pool(self, netuid: int) -> int:
        """Alpha sitting in a subnet's pool (RAO), the chain's liquidity bound for swaps."""
        return int(chain.cast_call(
            config.ALPHA_PRECOMPILE, "getAlphaInPool(uint16)(uint64)", netuid,
        ))

    def is_subnet_dissolving(self, netuid: int) -> Optional[bool]:
        """Whether the chain still reports the netuid mid-dissolution; None when
        the probe fails (the RPC can flap while the chain tears a subnet down)."""
        probe = chain.run(
            ["cast", "call", config.SUBNET_PRECOMPILE,
             "isSubnetDissolving(uint16)(bool)", str(netuid),
             "--rpc-url", config.RPC_URL],
            check=False,
        )
        if probe.returncode != 0:
            return None
        return probe.stdout.strip() == "true"

    def wait_for_dissolution_cleanup(self, netuid: int) -> None:
        """Block until the chain finishes draining a dissolved netuid.

        The dissolve extrinsic only starts the drain, and the vault freezes the
        subnet's flows until it completes, so scenarios must wait it out before
        asserting refunds. A failed probe counts as still dissolving."""
        for _ in range(60):
            if self.is_subnet_dissolving(netuid) is False:
                return
            time.sleep(2)
        raise AssertionError(
            f"netuid {netuid} still dissolving (or subnet precompile unreachable) after 120s"
        )

    def alpha_value_tao(self, netuid: int, alpha_rao: int) -> int:
        """Spot TAO value (RAO) of an alpha amount at the current oracle price."""
        return alpha_rao * self.alpha_price(netuid) // 10**18

    def floor_boundary(self, netuid: int, floor_rao: int) -> Tuple[int, int]:
        """(alpha price, boundary): the smallest alpha-RAO deposit whose TAO value
        clears `floor_rao` at the current price."""
        price = self.alpha_price(netuid)
        assert price != 0, f"netuid {netuid}: alpha price reads 0 (oracle unavailable)"
        boundary = (floor_rao * 10**18 + price - 1) // price
        return price, boundary

    def alpha_to_tao_quote(self, netuid: int, alpha_rao: int) -> int:
        """Chain's own alpha->TAO quote (RAO out) for selling `alpha_rao` on `netuid`.
        Capture it BEFORE the swap that pays out: the simulation re-prices against
        live reserves and the curve is concave, so a quote taken after the swap
        understates the payout by its own price impact."""
        return int(chain.cast_call(
            config.ALPHA_PRECOMPILE, "simSwapAlphaForTao(uint16,uint64)(uint256)",
            netuid, alpha_rao,
        ))

    def holder_assets(self, token_id: int, holder: str) -> int:
        """A holder's pro-rata alpha backing (RAO)."""
        shares = self.vault_shares(token_id, holder)
        supply = self.vault_total_supply(token_id)
        total = self.vault_total_stake(token_id)
        return 0 if supply == 0 else shares * total // supply

    def user_tao_wei(self) -> int:
        """The wrapper user's native TAO balance, in wei."""
        return chain.cast_balance_wei(config.WRAPPER_USER_ADDRESS)

    # --- Vault transactions -----------------------------------------------------
    def vault_broadcast(
        self, gas_limit: int, signature: str, *args,
        private_key: Optional[str] = None,
    ) -> dict:
        """Broadcast a vault transaction and return its receipt (a failed send
        surfaces as a receipt without a success status)."""
        return chain.cast_send(
            self.vault_address, signature, *args,
            private_key=private_key or config.WRAPPER_USER_PRIVATE_KEY,
            gas_limit=gas_limit,
        )

    def vault_send(
        self, gas_limit: int, message: str, signature: str, *args,
        private_key: Optional[str] = None,
    ) -> dict:
        """Broadcast a vault transaction and assert it succeeded."""
        receipt = self.vault_broadcast(gas_limit, signature, *args, private_key=private_key)
        assert chain.receipt_ok(receipt), f"{message}: {receipt}"
        return receipt

    def vault_send_expect_revert(
        self, gas_limit: int, message: str, signature: str, *args,
        private_key: Optional[str] = None,
    ) -> dict:
        """Broadcast a vault transaction that is EXPECTED to revert; assert it did
        not succeed."""
        receipt = self.vault_broadcast(gas_limit, signature, *args, private_key=private_key)
        assert not chain.receipt_ok(receipt), message
        return receipt

    def assert_vault_reverts_with(
        self, error_signature: str, gas_limit: int, message: str,
        signature: str, *args,
        private_key: Optional[str] = None, sender: Optional[str] = None,
    ) -> dict:
        """Assert a vault call reverts with a SPECIFIC custom error: an eth_call
        must surface the error (decoded name, or its selector in the revert
        data), then the broadcast must also fail on-chain. A bare status check
        would also pass on gas exhaustion or the wrong revert. Returns the
        broadcast receipt so callers can bound its gas."""
        error_name = error_signature.split("(")[0]
        selector = chain.cast_sig(error_signature)
        probe = chain.run(
            ["cast", "call", self.vault_address, signature, *[str(a) for a in args],
             "--from", sender or config.WRAPPER_USER_ADDRESS, "--rpc-url", config.RPC_URL],
            check=False,
        )
        probe_output = (probe.stdout + probe.stderr).lower()
        assert error_name.lower() in probe_output or selector.lower() in probe_output, (
            f"{message} (missing {error_signature} in: {probe.stdout + probe.stderr})"
        )
        receipt = self.vault_broadcast(gas_limit, signature, *args, private_key=private_key)
        assert not chain.receipt_ok(receipt), message
        return receipt

    # --- Scenario actions -------------------------------------------------------
    def transfer_shares(
        self, token_id: int, sender: str, recipient: str, shares: int, message: str,
        *, private_key: str,
    ) -> dict:
        """Move vault shares between holders, as a secondary-market sale would. Resizes
        a holder's slice without touching the alpha price or the vault's on-chain stake."""
        return self.vault_send(
            300_000, message, "safeTransferFrom(address,address,uint256,uint256,bytes)",
            sender, recipient, token_id, shares, "0x",
            private_key=private_key,
        )

    def deposit_and_wrap(
        self, netuid: int, hotkey_pubkey: str, hotkey_ss58: str,
        amount_rao: int, gas_limit: int, message: str,
        user: Optional[str] = None, private_key: Optional[str] = None,
    ) -> dict:
        """Transfer alpha from Alice into a user's mailbox under a hotkey, then
        wrap it into the vault. Defaults to the wrapper user; pass `user` and
        `private_key` to run it for another holder. Returns the wrap receipt."""
        user = user or config.WRAPPER_USER_ADDRESS
        mailbox = self.mailbox_address(netuid, user)
        print(f"  Transferring {amount_rao} RAO from Alice -> mailbox under {hotkey_pubkey[:18]}...")
        extrinsics.transfer_stake(
            substrate.h160_to_ss58(mailbox), hotkey_ss58, netuid, amount_rao,
        )
        return self.vault_send(
            gas_limit, message, "wrap(uint256,bytes32)", netuid, hotkey_pubkey,
            private_key=private_key or config.WRAPPER_USER_PRIVATE_KEY,
        )

    def set_validators(self, netuid: int, hotkey_pubkeys: List[str], weights: List[int]) -> None:
        """Rotate the registry's validator set for `netuid` via a real 2-of-2
        EIP-712 attestation."""
        validators.set_validators(
            self.validator_registry_address,
            [config.DEPLOYER_PRIVATE_KEY, config.WRAPPER_USER_PRIVATE_KEY],
            netuid, hotkey_pubkeys, weights,
        )

    def declare_shortfall(self, token_id: int) -> None:
        """Put `token_id`'s unaccounted loss on file, starting the window after which the record
        gives up on it. The rails refuse a shortfall no chain fact explains - the chain's dust sweep
        leaves none - so this is what eventually reopens such a token. Anyone may call it."""
        validators.declare_shortfall(
            self.vault_address, config.WRAPPER_USER_PRIVATE_KEY, token_id,
        )

    def deposits_open_from(self, token_id: int) -> int:
        """Unix time at which a recorded loss stops holding quotes and deposits shut; 0 when none is
        on file. Exits never wait on it."""
        return int(chain.cast_call(
            self.vault_address, "depositsOpenFrom(uint256)(uint256)", token_id,
        ))

    def crash_price_until_below(
        self, netuid: int, hotkey_pubkey: str, hotkey_ss58: str,
        alpha_rao: int, target_tao_rao: int, context: str,
    ) -> None:
        """Alice sells her stake under the hotkey in pool-bounded chunks until
        `alpha_rao` is worth less than `target_tao_rao` RAO. Chunks are capped at
        a quarter of the pool's alpha so a single sell cannot overshoot the
        target band. Alice's stake under one hotkey can move the price by about
        half, so deeper targets are out of reach."""
        for _ in range(18):
            if self.alpha_value_tao(netuid, alpha_rao) < target_tao_rao:
                return
            alice_stake = self.stake(hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, netuid)
            pool_alpha = self.alpha_in_pool(netuid)
            chunk = min(alice_stake // 3, max(pool_alpha // 4, 1))
            if chunk == 0:
                break
            try:
                extrinsics.remove_stake(hotkey_ss58, netuid, chunk)
            except extrinsics.ExtrinsicError as error:
                raise AssertionError(f"{context}: alpha sell rejected") from error
        assert self.alpha_value_tao(netuid, alpha_rao) < target_tao_rao, (
            f"{context}: could not crash the price "
            f"({alpha_rao} alpha RAO still worth >= {target_tao_rao} RAO)"
        )
