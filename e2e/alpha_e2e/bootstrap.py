"""One-time localnet setup shared by every scenario.

build_environment() brings a fresh localnet to the point where a position can
be deposited:

  pre-flight  chain reachable, dev Alice wallet present (regen from seed if not)
  Phase 0     fund the deployer EVM account from Alice
  Phase 1     create 3 subnets, disable the admin freeze window, start
              emissions, raise the per-block registration limit
  Phase 2     create + register 3 validator hotkeys per subnet
  Phase 3     stake TAO per validator at ratio 3:2:1
  Phase 4     deploy the contracts, wire the validator registry (2-of-2), attest
              the initial 50/30/20 validator sets, create the subnet proxies
  Phase 5     fund the wrapper user account

btcli calls go through chain.btcli() (auto-appends --network) or
chain.btcli_json() where the outcome is read back; wallet regen/creation calls
go through chain.run(["btcli", ...]) directly because they touch only local key
files and must not carry the --network flag.
"""
import os
import shutil
import time
from typing import List, NamedTuple, Tuple

from . import chain, config, extrinsics, substrate, validators
from .environment import Environment, read_stake

INITIAL_VALIDATOR_WEIGHTS = [5000, 3000, 2000]


class DeployedContracts(NamedTuple):
    vault_address: str
    lens_address: str
    mailbox_implementation_address: str
    subnet_clone_implementation_address: str
    validator_registry_address: str


def _log(message: str) -> None:
    print(f"\n=== {message} ===", flush=True)


# --- Chain ops shared with the scenarios ---------------------------------------

def create_subnet() -> int:
    """Create a subnet and return the netuid the chain assigned it."""
    result = chain.btcli_json(
        ["subnets", "create", "--wallet", config.ALICE_WALLET,
         "--wallet-hotkey", config.ALICE_HOTKEY_NAME, "--yes"],
    )
    netuid = result.get("data", {}).get("netuid")
    if netuid is None:
        raise RuntimeError(f"Could not extract netuid: {result}")
    return int(netuid)


# A repeat registration is turned away for the hotkey already holding a slot,
# which is exactly the state this function is asked to reach.
_ALREADY_REGISTERED = "HotKeyAlreadyRegisteredInSubNet"


def register_hotkey(netuid: int, hotkey_name: str) -> Tuple[str, str]:
    """Create the hotkey if missing and register it on a subnet, retrying across
    blocks (registration is rate-limited even at the raised per-block limit).
    Returns the hotkey's (bytes32 pubkey, SS58 address)."""
    hotkey_file = substrate.hotkey_file_path(config.ALICE_WALLET, hotkey_name)
    if not os.path.isfile(hotkey_file):
        chain.run(
            ["btcli", "wallet", "new-hotkey", "--wallet", config.ALICE_WALLET,
             "--wallet-hotkey", hotkey_name, "--n-words", "12"],
            check=False,
        )

    pubkey = substrate.read_hotkey_pubkey(config.ALICE_WALLET, hotkey_name)
    ss58 = substrate.read_hotkey_ss58(config.ALICE_WALLET, hotkey_name)

    refusal = None
    for attempt in (1, 2, 3):
        try:
            extrinsics.burned_register(ss58, netuid)
            return pubkey, ss58
        except extrinsics.ExtrinsicError as error:
            if _ALREADY_REGISTERED in str(error):
                return pubkey, ss58
            refusal = error
        print(f"  Retry {attempt} for {hotkey_name} (waiting for next block)...")
        time.sleep(6)

    raise RuntimeError(
        f"register failed for {hotkey_name} on netuid {netuid} after 3 attempts: {refusal}"
    )


# --- Pre-flight -----------------------------------------------------------------

def _check_repo_root() -> None:
    if not (os.path.isdir("src") and os.path.isdir("e2e")):
        raise RuntimeError("Run from the repo root (CWD must contain e2e/ and src/).")


def _check_chain_reachable() -> None:
    _log("Pre-flight checks")
    try:
        chain_id = chain.cast_chain_id()
    except chain.ChainError as error:
        raise RuntimeError(f"Cannot connect to {config.RPC_URL}") from error
    print(f"  Chain reachable (chain-id: {chain_id})")
    try:
        balance = chain.cast_balance_ether(config.DEPLOYER_ADDRESS)
    except chain.ChainError:
        balance = 0.0
    print(f"  Deployer balance: {balance} TAO")


def _ensure_alice_wallet() -> None:
    """Make sure the local alice wallet is the dev Alice (regenerating it from
    the dev seed if it is missing or a different key) and has a hotkey."""
    wallet_dir = os.path.expanduser(f"~/.bittensor/wallets/{config.ALICE_WALLET}")
    coldkey_file = os.path.join(wallet_dir, "coldkeypub.txt")
    need_regen = False

    if not os.path.isdir(wallet_dir):
        need_regen = True
    elif os.path.isfile(coldkey_file):
        with open(coldkey_file) as coldkey_pub_file:
            content = coldkey_pub_file.read()
        if config.ALICE_COLDKEY_SS58 not in content:
            print("  WARNING: Existing alice wallet is NOT the dev Alice - regenerating from dev seed...")
            shutil.rmtree(wallet_dir)
            need_regen = True
    else:
        need_regen = True

    if need_regen:
        print("  Setting up dev Alice wallet from seed...")
        chain.run(
            ["btcli", "wallet", "regen-coldkey", "--wallet", config.ALICE_WALLET,
             "--wallet-path", os.path.expanduser("~/.bittensor/wallets"),
             "--seed", config.ALICE_COLDKEY_SEED, "--no-password", "--overwrite"],
            check=False,
        )
        if not os.path.isfile(coldkey_file):
            raise RuntimeError("Failed to regenerate Alice coldkey")
        print("  Alice coldkey regenerated from dev seed (5Grwva...)")

    hotkey_file = substrate.hotkey_file_path(config.ALICE_WALLET, config.ALICE_HOTKEY_NAME)
    if not os.path.isfile(hotkey_file):
        print(f"  Creating hotkey '{config.ALICE_HOTKEY_NAME}' for wallet '{config.ALICE_WALLET}'...")
        chain.run(
            ["btcli", "wallet", "new-hotkey", "--wallet", config.ALICE_WALLET,
             "--wallet-hotkey", config.ALICE_HOTKEY_NAME, "--n-words", "12"],
            check=False,
        )
        print(f"  Created hotkey '{config.ALICE_HOTKEY_NAME}'")
    else:
        print(f"  Alice hotkey '{config.ALICE_HOTKEY_NAME}' exists")
    print("  Alice wallet ready")


# --- Phase 0/5: fund the EVM test accounts from Alice ------------------------------

def _ensure_evm_account_funded(
    label: str, address: str, ss58: str, minimum_tao: int, transfer_tao: int,
) -> None:
    balance = chain.cast_balance_ether(address)
    if int(balance) < minimum_tao:
        chain.btcli(
            ["wallet", "transfer", "--wallet", config.ALICE_WALLET,
             "--dest", ss58, "--amount-tao", str(transfer_tao), "--yes"],
            check=True,
        )
        print(f"  Transferred {transfer_tao} TAO -> {address} ({ss58})")
        print(f"  New balance: {chain.cast_balance_ether(address)} TAO")
    else:
        print(f"  {label} already funded: {balance} TAO (>{minimum_tao}, skipping transfer)")


# --- Phase 1: subnets, freeze window, emissions -----------------------------------

def _create_subnets() -> List[int]:
    _log("Phase 1: Create 3 subnets")
    netuids = []
    for subnet_number in (1, 2, 3):
        print(f"  Creating subnet {subnet_number} of 3 ...")
        netuid = create_subnet()
        netuids.append(netuid)
        print(f"  netuid {netuid}")

    # The fast-runtime's admin freeze window lets owner/root hyperparameter writes
    # (the registration cap below, the transfer toggle in the transfers-off test)
    # land only near each subnet's epoch boundary and otherwise silently miss.
    # Disable it so they apply first try.
    _log("Disable admin freeze window (deterministic sudo hyperparameter writes)")
    extrinsics.set_admin_freeze_window(0)
    print("  AdminFreezeWindow -> 0")

    _log("Start emissions + raise the per-block registration cap")
    for netuid in netuids:
        chain.btcli(
            ["sudo", "start", "--netuid", str(netuid),
             "--wallet", config.ALICE_WALLET, "--wallet-hotkey", config.ALICE_HOTKEY_NAME,
             "--yes"],
            check=True,
        )
        print(f"  netuid {netuid} emissions started")
        extrinsics.set_max_registrations_per_block(netuid, 8)
        print(f"  netuid {netuid} registrations per block -> 8")
    return netuids


# --- Phase 2: hotkeys + validator registration -------------------------------------

def _register_validators(netuids: List[int]) -> Tuple[List[str], List[str], List[str]]:
    _log("Phase 2: Hotkeys & validators (3 per subnet)")
    hotkey_names: List[str] = []
    hotkey_pubkeys: List[str] = []
    hotkey_ss58s: List[str] = []

    for subnet_index, netuid in enumerate(netuids):
        for suffix in config.HOTKEY_SUFFIXES:
            hotkey_name = f"hk_e2e_{subnet_index + 1}{suffix}"
            pubkey, ss58 = register_hotkey(netuid, hotkey_name)
            hotkey_names.append(hotkey_name)
            hotkey_pubkeys.append(pubkey)
            hotkey_ss58s.append(ss58)
            print(f"  {hotkey_name} registered on netuid {netuid}: {pubkey[:18]}...")

    return hotkey_names, hotkey_pubkeys, hotkey_ss58s


# --- Phase 3: stake TAO per validator, ratio 3:2:1 ----------------------------------

def _stake_validators(
    netuids: List[int], hotkey_names: List[str],
    hotkey_pubkeys: List[str], hotkey_ss58s: List[str],
) -> None:
    _log("Phase 3: Stake TAO per validator (ratio 3:2:1)")
    for subnet_index, netuid in enumerate(netuids):
        for validator_index, amount_tao in enumerate(config.VALIDATOR_STAKE_TAO):
            flat_index = subnet_index * config.VALIDATORS_PER_SUBNET + validator_index
            hotkey_name = hotkey_names[flat_index]

            extrinsics.add_stake(hotkey_ss58s[flat_index], netuid, amount_tao * 10**9)
            stake = read_stake(hotkey_pubkeys[flat_index], config.ALICE_COLDKEY_PUBKEY, netuid)
            if stake == 0:
                raise RuntimeError(
                    f"stake add landed but {hotkey_name} reads 0 RAO on netuid {netuid}"
                )
            print(f"  netuid {netuid} {hotkey_name}: {amount_tao} TAO -> {stake} RAO")


# --- Phase 4: deploy contracts -------------------------------------------------------

def _deploy_contracts(netuids: List[int], hotkey_pubkeys: List[str]):
    _log("Phase 4: Deploy")

    # Capture the deploy block so a downstream observability phase can scope its
    # event queries.
    observation_block_start = chain.cast_block_number()
    print(f"  Observability block range start: {observation_block_start}")

    chain.run(["forge", "build", "--quiet"])
    print("  Compiled")

    mailbox_implementation_address = chain.forge_create(
        "src/DepositMailbox.sol:DepositMailbox", private_key=config.DEPLOYER_PRIVATE_KEY,
    )
    print(f"  DepositMailbox: {mailbox_implementation_address}")

    subnet_clone_implementation_address = chain.forge_create(
        "src/SubnetClone.sol:SubnetClone", private_key=config.DEPLOYER_PRIVATE_KEY,
    )
    print(f"  SubnetClone: {subnet_clone_implementation_address}")

    # DEPLOYER (0x7bD3...) < WRAPPER_USER (0xd103...) hex-ascending -- required by
    # ValidatorRegistry's sorted-signers check.
    validator_registry_address = chain.forge_create(
        "src/ValidatorRegistry.sol:ValidatorRegistry",
        private_key=config.DEPLOYER_PRIVATE_KEY,
        constructor_args=[
            config.DEPLOYER_ADDRESS,
            f"[{config.DEPLOYER_ADDRESS},{config.WRAPPER_USER_ADDRESS}]", "2",
        ],
    )
    print(f"  ValidatorRegistry: {validator_registry_address} "
          f"(admin={config.DEPLOYER_ADDRESS}, signers=[DEPLOYER,WRAPPER_USER], threshold=2)")

    vault_address = chain.forge_create(
        "src/AlphaVault.sol:AlphaVault", private_key=config.DEPLOYER_PRIVATE_KEY,
        constructor_args=[
            "https://api.tao20.io/{id}.json", mailbox_implementation_address,
            subnet_clone_implementation_address, validator_registry_address,
            str(3 * 60 * 60),
        ],
    )
    print(f"  AlphaVault: {vault_address}")

    lens_address = chain.forge_create(
        "src/AlphaVaultLens.sol:AlphaVaultLens", private_key=config.DEPLOYER_PRIVATE_KEY,
        constructor_args=[vault_address],
    )
    print(f"  AlphaVaultLens: {lens_address}")

    token_ids: List[int] = []
    for netuid in netuids:
        token_id = chain.cast_call(vault_address, "currentTokenId(uint256)(uint256)", netuid)
        if not token_id or token_id == "0":
            raise RuntimeError(
                f"currentTokenId returned 0 for netuid {netuid} (subnet not registered?)"
            )
        token_ids.append(int(token_id))
        print(f"  netuid {netuid} -> tokenId {token_id}")

    registry_block_start = chain.cast_block_number()
    for subnet_index, netuid in enumerate(netuids):
        subnet_pubkeys = hotkey_pubkeys[
            subnet_index * config.VALIDATORS_PER_SUBNET:
            (subnet_index + 1) * config.VALIDATORS_PER_SUBNET
        ]
        validators.set_validators(
            validator_registry_address,
            [config.DEPLOYER_PRIVATE_KEY, config.WRAPPER_USER_PRIVATE_KEY],
            netuid, subnet_pubkeys, INITIAL_VALIDATOR_WEIGHTS,
        )
        print(f"  netuid {netuid} validators set (50/30/20): "
              + ", ".join(f"{pubkey[:18]}..." for pubkey in subnet_pubkeys))
    registry_block_end = chain.cast_block_number()

    for netuid in netuids:
        receipt = chain.cast_send(
            vault_address, "createSubnetProxy(uint256)", netuid,
            private_key=config.DEPLOYER_PRIVATE_KEY, gas_limit=500_000,
        )
        if not chain.receipt_ok(receipt):
            raise RuntimeError(f"createSubnetProxy failed for netuid {netuid}: {receipt}")
        print(f"  Subnet proxy created for netuid {netuid}")

    contracts = DeployedContracts(
        vault_address=vault_address,
        lens_address=lens_address,
        mailbox_implementation_address=mailbox_implementation_address,
        subnet_clone_implementation_address=subnet_clone_implementation_address,
        validator_registry_address=validator_registry_address,
    )
    return observation_block_start, registry_block_start, registry_block_end, contracts, token_ids


# --- Composition -------------------------------------------------------------------------

def build_environment() -> Environment:
    _check_repo_root()
    _check_chain_reachable()
    _ensure_alice_wallet()
    _log("Phase 0: Fund deployer")
    _ensure_evm_account_funded(
        "Deployer", config.DEPLOYER_ADDRESS, config.DEPLOYER_SS58,
        minimum_tao=50, transfer_tao=10_000,
    )
    netuids = _create_subnets()
    hotkey_names, hotkey_pubkeys, hotkey_ss58s = _register_validators(netuids)
    _stake_validators(netuids, hotkey_names, hotkey_pubkeys, hotkey_ss58s)
    (observation_block_start, registry_block_start, registry_block_end,
     contracts, token_ids) = _deploy_contracts(netuids, hotkey_pubkeys)
    _log("Phase 5: Fund user account")
    _ensure_evm_account_funded(
        "User account", config.WRAPPER_USER_ADDRESS, config.WRAPPER_USER_SS58,
        minimum_tao=5, transfer_tao=100,
    )

    wrapper_substrate_coldkey = substrate.h160_to_substrate_b32(config.WRAPPER_USER_ADDRESS)
    print(f"  Wrapper substrate coldkey: {wrapper_substrate_coldkey}")

    return Environment(
        netuids=netuids, token_ids=token_ids,
        hotkey_names=hotkey_names, hotkey_pubkeys=hotkey_pubkeys, hotkey_ss58s=hotkey_ss58s,
        vault_address=contracts.vault_address,
        lens_address=contracts.lens_address,
        mailbox_implementation_address=contracts.mailbox_implementation_address,
        subnet_clone_implementation_address=contracts.subnet_clone_implementation_address,
        validator_registry_address=contracts.validator_registry_address,
        wrapper_substrate_coldkey=wrapper_substrate_coldkey,
        observation_block_start=observation_block_start,
        registry_block_start=registry_block_start,
        registry_block_end=registry_block_end,
    )
