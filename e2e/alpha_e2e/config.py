"""Localnet dev constants shared by every e2e module.

These are well-known localnet/dev keys (substrate dev Alice, public test
keys), not secrets. The chain, wallets, and contract layout the suite targets
are all deterministic from these values.
"""

# --- Chain -------------------------------------------------------------------
CHAIN_ENDPOINT = "ws://127.0.0.1:9944"
RPC_URL = "http://127.0.0.1:9944"
CHAIN_ID = 42

# --- Wallets -----------------------------------------------------------------
ALICE_WALLET = "alice"
ALICE_HOTKEY_NAME = "default"
ALICE_COLDKEY_SEED = "0xe5be9a5092b81bca64be81d212e7f2f9eba183bb7a90954f7b76361f6edb5c0a"
ALICE_COLDKEY_PUBKEY = "0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d"
ALICE_COLDKEY_SS58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"

DEPLOYER_ADDRESS = "0x7bD3E0F025FC388e08dd2A63595dbcaB486F335b"
DEPLOYER_PRIVATE_KEY = "0x58a595a0863f6894cf22d465014abf7c7ca5b46fc8dd7e7e932d158002c33039"
DEPLOYER_SS58 = "5CroES7MYzgDoY6VFJct81eEPT2yQH3T6czzfmD5DD78wffA"

# "Wrapper user": the EVM account that deposits and withdraws in every scenario.
WRAPPER_USER_ADDRESS = "0xd10375caed456c5902D7B155117Dd155398145C7"
WRAPPER_USER_PRIVATE_KEY = "0xf784bf897e423437b1d2a1584a7fc5c99b0ec3f34d70ff74a0643094ccfd4bbe"
WRAPPER_USER_SS58 = "5H9xN1Y6KqdhcK9wPqFSPHC7yeaRC5y4CL3nNF2GX6hJrmpT"

# Second holder for multi-holder scenarios: a well-known public test key,
# localnet-only.
SECOND_HOLDER_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SECOND_HOLDER_PRIVATE_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

# --- Precompiles -------------------------------------------------------------
STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805"
# Exposes the chain's own alpha price and alpha->TAO swap simulation.
ALPHA_PRECOMPILE = "0x0000000000000000000000000000000000000808"
# Answers whether a netuid is still mid-dissolution after a dissolve call.
SUBNET_PRECOMPILE = "0x0000000000000000000000000000000000000803"

# --- Seeding amounts ---------------------------------------------------------
VALIDATOR_STAKE_TAO = (600, 400, 200)
HOTKEY_SUFFIXES = ("a", "b", "c")
VALIDATORS_PER_SUBNET = len(HOTKEY_SUFFIXES)
TRANSFER_AMOUNT_TAO = 100
# Per-validator transfer amount in RAO (TRANSFER_AMOUNT_TAO split across the 3 validators).
PER_HOTKEY_TRANSFER_RAO = TRANSFER_AMOUNT_TAO * 10**9 // VALIDATORS_PER_SUBNET

# --- Foundry / subprocess flags ------------------------------------------------
# Bittensor EVM: gas estimation fails; always use legacy txs with explicit gas.
EVM_TX_FLAGS = ["--legacy", "--gas-price", "10000000000"]
FORGE_CREATE_FLAGS = EVM_TX_FLAGS + ["--gas-limit", "5000000", "--broadcast"]
# The localnet charges a fixed gas price, which payout reconstruction relies on.
LOCALNET_GAS_PRICE_WEI = 10**10

# --- Gas budgets ---------------------------------------------------------------
# A rejected precompile dispatch consumes all forwarded gas, so a call staying far
# under its limit separates a designed pre-check revert (or a healthy call) from an
# attempted-and-burned dispatch.
WRAP_GAS_BOUND = 1_000_000
UNWRAP_GAS_BOUND = 1_700_000
REVERT_GAS_BOUND = 500_000
# Storing each attested hotkey dominates updateValidators' cost, so its gas
# limit scales from a fixed base with the set size.
UPDATE_VALIDATORS_BASE_GAS = 500_000
UPDATE_VALIDATORS_GAS_PER_HOTKEY = 60_000

# --- Rounding dust ---------------------------------------------------------------
# The chain's share arithmetic can leave about one RAO behind on every entry a move
# or drain passes through, so a slot the vault emptied legitimately reads a few RAO,
# not always zero.
ROUNDING_DUST_SLOT_RAO = 2
# A position drains across up to six slots, so totals accumulate the per-slot rounding.
ROUNDING_DUST_TOTAL_RAO = ROUNDING_DUST_SLOT_RAO * 6
# A consolidation adds extra move/drain operations, each losing about one RAO to
# integer rounding; conservation checks across a consolidation allow this much slack.
CONSOLIDATION_ROUNDING_TOLERANCE_RAO = 100
