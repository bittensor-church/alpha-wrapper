import { fmtUnits, fmtPrice } from '../utils/format';

export default function VaultList({ vaults, loading, selectedId, onSelect, onAddAsset }) {
  return (
    <section className="card">
      <h2>Subnet Vaults</h2>
      <p className="subtitle">Click a vault to wrap or unwrap alpha. Vaults auto-create per subnet.</p>
      <div style={{ overflowX: 'auto' }}>
        <table className="vault-table">
          <thead>
            <tr>
              <th>Subnet</th>
              <th>Name</th>
              <th>Symbol</th>
              <th>Share Price</th>
              <th>Total Stake</th>
              <th>Total Supply</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td colSpan={7} className="empty-msg">Scanning subnets...</td>
              </tr>
            )}
            {!loading && vaults.length === 0 && (
              <tr>
                <td colSpan={7} className="empty-msg">No subnets with validators found</td>
              </tr>
            )}
            {vaults.map((v) => (
              <tr
                key={v.id}
                className={selectedId === v.id ? 'row-selected' : ''}
                onClick={() => onSelect(v.id)}
                style={{ cursor: 'pointer' }}
              >
                <td>{v.netuid}</td>
                <td>{v.name}</td>
                <td>{v.symbol}</td>
                <td>{v.supply > 0n ? (Number(v.actualStake * 1000000000n) / Number(v.supply)).toFixed(4) : '1.0000'}x</td>
                <td>{fmtUnits(v.actualStake, 9)} {v.letter}</td>
                <td>{fmtUnits(v.supply, 18)} {v.symbol}</td>
                <td>
                  <button
                    className="btn btn-ghost btn-sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      onAddAsset(v);
                    }}
                    style={{ padding: '2px 6px', fontSize: '0.7rem' }}
                  >
                    + Wallet
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
