import { useState, useCallback } from 'react';
import { Contract } from 'ethers';
import { MAX_SCAN_NETUID, getGreekName, STAKING_ABI, STAKING_ADDRESS } from '../config';

export function useVaults() {
  const [vaults, setVaults] = useState([]);
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async (vaultContract, readProvider) => {
    if (!vaultContract) return;
    setLoading(true);
    try {
      const fetched = [];

      // Read vault substrate coldkey once (needed for actual stake lookups)
      let vaultSub = null;
      let staking = null;
      try {
        vaultSub = await vaultContract.vaultSubstrateColdkey();
        if (readProvider) {
          staking = new Contract(STAKING_ADDRESS, STAKING_ABI, readProvider);
        }
      } catch { /* ignore */ }

      // Scan netuids 1..MAX: try getBestValidator — if it doesn't revert, subnet has validators.
      const promises = [];
      for (let netuid = 1; netuid <= MAX_SCAN_NETUID; netuid++) {
        promises.push(
          (async () => {
            try {
              const hotkey = await vaultContract.getBestValidator(netuid);
              const [price, stake, supply, topValidators] = await Promise.all([
                vaultContract.sharePrice(netuid),
                vaultContract.totalStake(netuid),
                vaultContract.totalSupply(netuid),
                vaultContract.getBestValidators(netuid),
              ]);

              // Read actual on-chain stake across top 3 validators
              let actualStake = stake; // fallback to contract's totalStake
              if (staking && vaultSub) {
                try {
                  const stakeReads = [];
                  for (const hk of topValidators) {
                    if (hk !== '0x' + '0'.repeat(64)) {
                      stakeReads.push(staking.getStake(hk, vaultSub, netuid));
                    }
                  }
                  const stakes = await Promise.all(stakeReads);
                  const total = stakes.reduce((sum, s) => sum + s, 0n);
                  if (total > 0n) actualStake = total;
                } catch { /* fallback to contract value */ }
              }

              const greek = getGreekName(netuid);
              return {
                id: netuid,
                netuid,
                name: greek.name,
                symbol: greek.symbol,
                letter: greek.letter,
                hotkey,
                price,
                stake,        // contract's totalStake (accounting)
                actualStake,  // real on-chain stake across top validators
                supply,
              };
            } catch {
              // No validators on this netuid — skip
              return null;
            }
          })()
        );
      }

      const results = await Promise.all(promises);
      for (const v of results) {
        if (v) fetched.push(v);
      }

      setVaults(fetched);
    } catch (e) {
      console.error('useVaults error:', e);
    } finally {
      setLoading(false);
    }
  }, []);

  return { vaults, loading, refresh };
}
