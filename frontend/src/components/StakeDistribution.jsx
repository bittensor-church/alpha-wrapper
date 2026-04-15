import { useState, useEffect } from 'react';
import { Contract } from 'ethers';
import { STAKING_ABI, STAKING_ADDRESS, METAGRAPH_ABI, METAGRAPH_ADDRESS, TEMPOS_PER_YEAR } from '../config';
import { fmtUnits, truncAddr } from '../utils/format';

export default function StakeDistribution({ vault, readProvider, vaultContract }) {
  const [validators, setValidators] = useState([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!vault || !readProvider || !vaultContract) {
      setValidators([]);
      return;
    }

    let cancelled = false;
    setLoading(true);

    (async () => {
      try {
        const staking = new Contract(STAKING_ADDRESS, STAKING_ABI, readProvider);
        const metagraph = new Contract(METAGRAPH_ADDRESS, METAGRAPH_ABI, readProvider);
        const vaultSub = await vaultContract.vaultSubstrateColdkey();

        const uidCount = await metagraph.getUidCount(vault.netuid);
        const checks = [];
        for (let uid = 0; uid < uidCount; uid++) {
          checks.push(
            (async () => {
              const [hk, isValidator] = await Promise.all([
                metagraph.getHotkey(vault.netuid, uid),
                metagraph.getValidatorStatus(vault.netuid, uid),
              ]);
              if (!isValidator) return null;
              const [vaultStake, totalValidatorStake, emission] = await Promise.all([
                staking.getStake(hk, vaultSub, vault.netuid),
                metagraph.getStake(vault.netuid, uid),
                metagraph.getEmission(vault.netuid, uid),
              ]);

              // APR = (emission_per_tempo * tempos_per_year) / total_validator_stake * 100
              const totalStakeNum = Number(totalValidatorStake);
              const emissionNum = Number(emission);
              const apr = totalStakeNum > 0
                ? (emissionNum * TEMPOS_PER_YEAR) / totalStakeNum * 100
                : 0;

              return { hotkey: hk, stake: vaultStake, totalValidatorStake, emission, apr, uid };
            })()
          );
        }

        const results = (await Promise.all(checks)).filter(Boolean);
        results.sort((a, b) => (a.stake > b.stake ? -1 : a.stake < b.stake ? 1 : 0));

        // Fetch registry validators to mark preferred ones
        let registrySet = new Set();
        try {
          const topValidators = await vaultContract.getBestValidators(vault.netuid);
          const ZERO = '0x' + '0'.repeat(64);
          for (const hk of topValidators) {
            if (hk !== ZERO) registrySet.add(hk.toLowerCase());
          }
        } catch { /* registry not set — show all without badges */ }

        const totalVaultStake = results.reduce((sum, r) => sum + r.stake, 0n);

        if (!cancelled) {
          setValidators(
            results.map((r) => ({
              hotkey: r.hotkey,
              stake: r.stake,
              hasStake: r.stake > 0n,
              inRegistry: registrySet.has((typeof r.hotkey === 'string' ? r.hotkey : '0x' + Array.from(r.hotkey).map(b => b.toString(16).padStart(2, '0')).join('')).toLowerCase()),
              pct: totalVaultStake > 0n ? Number((r.stake * 10000n) / totalVaultStake) / 100 : 0,
              apr: r.apr,
            }))
          );
        }
      } catch (e) {
        console.error('StakeDistribution error:', e);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [vault, readProvider, vaultContract]);

  if (!vault) return null;

  return (
    <section className="card">
      <h2>Vault Stake Distribution</h2>
      <p className="subtitle">
        How {vault.name} ({vault.symbol}) stake is distributed across validators.
      </p>

      {loading && <p className="empty-msg">Loading validators...</p>}

      {!loading && validators.length === 0 && (
        <p className="empty-msg">No validators found</p>
      )}

      {!loading && validators.length > 0 && (() => {
        const totalStake = validators.reduce((sum, v) => sum + v.stake, 0n);
        const supply = vault.supply || 1n;
        const sharePrice = supply > 0n ? Number(totalStake * 1000000000n) / Number(supply) : 0;

        // Weighted average APR: weight by vault's stake on each validator
        const weightedApr = totalStake > 0n
          ? validators.reduce((sum, v) => sum + v.apr * Number(v.stake), 0) / Number(totalStake)
          : 0;

        return (
        <div>
          {/* Summary */}
          <div className="preview-box" style={{ marginBottom: '0.75rem', borderColor: 'var(--accent)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: '1rem' }}>
              <div>
                <div style={{ fontSize: '0.75rem', opacity: 0.6 }}>Total Staked</div>
                <div style={{ fontWeight: 600 }}>{fmtUnits(totalStake, 9)} {vault.letter}</div>
              </div>
              <div>
                <div style={{ fontSize: '0.75rem', opacity: 0.6 }}>Total Shares</div>
                <div style={{ fontWeight: 600 }}>{fmtUnits(supply)} {vault.symbol}</div>
              </div>
              <div>
                <div style={{ fontSize: '0.75rem', opacity: 0.6 }}>Share Price</div>
                <div style={{ fontWeight: 600 }}>{sharePrice.toFixed(4)} {vault.letter}/{vault.symbol}</div>
              </div>
              <div>
                <div style={{ fontSize: '0.75rem', opacity: 0.6 }}>Avg APR</div>
                <div style={{ fontWeight: 600, color: 'var(--accent, #00c864)' }}>{weightedApr.toFixed(1)}%</div>
              </div>
            </div>
          </div>

          {validators.map((v, i) => {
            const validatorShares = totalStake > 0n ? (v.stake * supply) / totalStake : 0n;
            return (
            <div
              key={i}
              className="preview-box"
              style={{
                marginBottom: '0.25rem',
                borderColor: v.hasStake ? 'var(--accent)' : 'var(--danger)',
                background: v.hasStake ? 'var(--green-bg, rgba(0,200,100,0.08))' : 'var(--red-bg, rgba(200,50,50,0.08))',
              }}
            >
              <div className="preview-row">
                <span>
                  <span
                    className="badge-dot"
                    style={{
                      display: 'inline-block',
                      width: '8px',
                      height: '8px',
                      borderRadius: '50%',
                      backgroundColor: v.hasStake ? 'var(--accent, #00c864)' : 'var(--danger, #ff4444)',
                      marginRight: '0.5rem',
                    }}
                  />
                  <span style={{ fontFamily: 'monospace' }}>{truncAddr(v.hotkey)}</span>
                  {v.inRegistry && (
                    <span style={{
                      marginLeft: '0.4rem',
                      fontSize: '0.7rem',
                      padding: '1px 5px',
                      borderRadius: '3px',
                      background: 'var(--accent, #00c864)',
                      color: '#000',
                      fontWeight: 600,
                    }}>PREFERRED</span>
                  )}
                </span>
                <span style={{ textAlign: 'right' }}>
                  <div>
                    {fmtUnits(v.stake, 9)} {vault.letter} ({v.pct.toFixed(1)}%)
                    <span style={{ marginLeft: '0.5rem', color: 'var(--accent, #00c864)', fontSize: '0.85rem' }}>
                      {v.apr.toFixed(1)}% APR
                    </span>
                  </div>
                  <div style={{ fontSize: '0.8rem', opacity: 0.7 }}>{fmtUnits(validatorShares)} {vault.symbol}</div>
                </span>
              </div>
            </div>
            );
          })}
        </div>
        );
      })()}
    </section>
  );
}
