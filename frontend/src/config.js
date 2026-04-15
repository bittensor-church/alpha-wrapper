export const DEFAULT_RPC = import.meta.env.VITE_RPC_URL || "http://127.0.0.1:9944";
export const DEFAULT_WS_URL = import.meta.env.VITE_WS_URL || "ws://127.0.0.1:9944";
export const TARGET_CHAIN_ID = 42;
export const TARGET_CHAIN_HEX = "0x2a";
export const BITTENSOR_SS58_PREFIX = 42;

export const STAKING_ADDRESS = "0x0000000000000000000000000000000000000805";

export const DEFAULT_VAULT_ADDR = import.meta.env.VITE_VAULT_ADDR || "";

/// Max netuid to scan when discovering subnets (vaultId == netuid).
export const MAX_SCAN_NETUID = Number(import.meta.env.VITE_MAX_SCAN_NETUID || 64);

export const VAULT_ABI = [
  "function getDepositAddress(address user, uint256 netuid) view returns (address)",
  "function processDeposit(address user, uint256 netuid, bytes32 cloneSubstrateColdkey)",
  "function withdraw(uint256 netuid, uint256 shares, bytes32 userSubstrateColdkey)",
  "function balanceOf(address account, uint256 id) view returns (uint256)",
  "function sharePrice(uint256 netuid) view returns (uint256)",
  "function previewDeposit(uint256 netuid, uint256 assets) view returns (uint256)",
  "function previewWithdraw(uint256 netuid, uint256 shares) view returns (uint256)",
  "function totalStake(uint256 netuid) view returns (uint256)",
  "function totalSupply(uint256 netuid) view returns (uint256)",
  "function vaultSubstrateColdkey() view returns (bytes32)",
  "function getBestValidator(uint256 netuid) view returns (bytes32)",
  "function getBestValidators(uint256 netuid) view returns (bytes32[3])",
  "function rebalance(uint256 netuid)",
];

export const STAKING_ABI = [
  "function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) view returns (uint256)",
  "function transferStake(bytes32 destination_coldkey, bytes32 hotkey, uint256 origin_netuid, uint256 destination_netuid, uint256 amount) payable",
];

export const METAGRAPH_ADDRESS = "0x0000000000000000000000000000000000000802";

export const METAGRAPH_ABI = [
  "function getUidCount(uint16 netuid) view returns (uint16)",
  "function getHotkey(uint16 netuid, uint16 uid) view returns (bytes32)",
  "function getStake(uint16 netuid, uint16 uid) view returns (uint64)",
  "function getEmission(uint16 netuid, uint16 uid) view returns (uint64)",
  "function getDividends(uint16 netuid, uint16 uid) view returns (uint16)",
  "function getValidatorStatus(uint16 netuid, uint16 uid) view returns (bool)",
];

// Bittensor tempo: ~360 blocks, ~12s per block = 4320s per tempo
// Tempos per year ≈ 365.25 * 86400 / 4320 ≈ 7305
export const TEMPOS_PER_YEAR = 7305;

export const CHAIN_CONFIG = {
  chainId: TARGET_CHAIN_HEX,
  chainName: "Bittensor Local",
  nativeCurrency: { name: "TAO", symbol: "TAO", decimals: 18 },
  rpcUrls: [DEFAULT_RPC],
};


export function getGreekName(netuid) {
  return { name: `SN${netuid}`, symbol: `wα${netuid}`, letter: `α${netuid}` };
}
