import { fmtUnits } from '../utils/format';

export default function MyShares({ vaults, balances, onAddAsset }) {
  const owned = vaults.filter((v) => balances[v.id] && balances[v.id] > 0n);

  return (
    <section className="card">
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1rem' }}>
        <div>
          <h2>My Vault Shares</h2>
          <p className="subtitle">Your ERC1155 vault share balances.</p>
        </div>
      </div>
      {owned.length === 0 ? (
        <p className="empty-msg">No shares yet. Wrap alpha to receive vault shares.</p>
      ) : (
        <div className="shares-grid">
          {owned.map((v) => {
            const balance = balances[v.id];
            const supply = v.supply || 1n;
            // Use actual on-chain stake for real alpha value
            const actualAlpha = supply > 0n ? (balance * v.actualStake) / supply : 0n;
            const pctOfTotal = supply > 0n ? Number((balance * 10000n) / supply) / 100 : 0;

            return (
              <div key={v.id} className="share-card">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                  <div className="vault-name">
                    {v.name} ({v.symbol})
                  </div>
                  <button
                    className="btn btn-ghost btn-sm"
                    onClick={() => onAddAsset(v)}
                    title="Add to MetaMask"
                    style={{ padding: '4px 8px', fontSize: '0.7rem' }}
                  >
                    + Wallet
                  </button>
                </div>
                <div className="vault-amount">{fmtUnits(balance)} {v.symbol}</div>
                <div className="vault-value" style={{ fontSize: '0.85rem', opacity: 0.8, marginTop: '0.25rem' }}>
                  ≈ {fmtUnits(actualAlpha, 9)} {v.letter} ({pctOfTotal.toFixed(1)}% of supply)
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
