import { truncAddr } from '../utils/format';

export default function SubstrateWalletConnect({
  isConnected,
  accounts,
  selectedAccount,
  onConnect,
  onDisconnect,
  onSelectAccount,
}) {
  if (!isConnected) {
    return (
      <button className="btn btn-primary btn-sm" onClick={onConnect}>
        Connect Bittensor Wallet
      </button>
    );
  }

  return (
    <div className="substrate-wallet-badge">
      <span className="badge-dot badge-dot-sub" />
      {accounts.length > 1 ? (
        <select
          className="substrate-account-select"
          value={selectedAccount?.address || ''}
          onChange={(e) => {
            const acct = accounts.find((a) => a.address === e.target.value);
            if (acct) onSelectAccount(acct);
          }}
        >
          {accounts.map((a) => (
            <option key={a.address} value={a.address}>
              {a.meta.name ? `${a.meta.name} (${truncAddr(a.address)})` : truncAddr(a.address)}
            </option>
          ))}
        </select>
      ) : (
        <span className="substrate-addr">
          {selectedAccount?.meta?.name
            ? `${selectedAccount.meta.name} (${truncAddr(selectedAccount.address)})`
            : truncAddr(selectedAccount?.address || '')}
        </span>
      )}
      <button className="btn-disconnect" onClick={onDisconnect} title="Disconnect">
        ×
      </button>
    </div>
  );
}
