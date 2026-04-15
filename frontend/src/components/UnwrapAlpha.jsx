import { useState, useEffect } from 'react';
import { parseUnits, formatUnits } from 'ethers';
import { h160ToSubstrate } from '../utils/substrate';
import { fmtUnits } from '../utils/format';

export default function UnwrapAlpha({
  vaults,
  selectedId,
  balances,
  address,
  vaultContract,
  vaultSigner,
  onTx,
  onDone,
}) {
  const [amount, setAmount] = useState('');
  const [previewAlpha, setPreviewAlpha] = useState(null);
  const [unwrapping, setUnwrapping] = useState(false);

  const vault = vaults.find((v) => v.id === selectedId);
  const userBalance = vault ? (balances[vault.id] || 0n) : 0n;

  // Preview assets on amount change — use actual on-chain stake for accurate estimate
  useEffect(() => {
    if (!vault || !amount || !vaultContract) {
      setPreviewAlpha(null);
      return;
    }
    let cancelled = false;
    const timer = setTimeout(() => {
      try {
        const wei = parseUnits(amount, 18);
        const supply = vault.supply || 1n;
        const actualAlpha = supply > 0n ? (wei * vault.actualStake) / supply : 0n;
        if (!cancelled) setPreviewAlpha(actualAlpha);
      } catch {
        if (!cancelled) setPreviewAlpha(null);
      }
    }, 200);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [vault, amount]);

  const handleUnwrap = async () => {
    if (!vault || !amount || !address || !vaultSigner || unwrapping) return;

    setUnwrapping(true);
    try {
      const wei = parseUnits(amount, 18);
      const userSub = h160ToSubstrate(address);

      onTx({ title: 'Unwrapping Alpha', message: 'Burning shares and returning alpha stake...' });

      const tx = await vaultSigner.withdraw(vault.id, wei, userSub, { gasLimit: 600000 });
      onTx({ title: 'Unwrapping...', message: `TX: ${tx.hash.slice(0, 10)}... (waiting for block)` });
      await tx.wait();

      setAmount('');
      setPreviewAlpha(null);
      onTx(null);
      onDone();
    } catch (e) {
      console.error('Unwrap error:', e);
      onTx(null);
      const msg = e.message || '';
      if (msg.includes('already known') || msg.includes('nonce has already been used')) {
        alert('Transaction already submitted - wait for it to confirm, then refresh.');
      } else {
        alert('Transaction failed: ' + (e.reason || msg));
      }
    } finally {
      setUnwrapping(false);
    }
  };

  if (!vault) {
    return (
      <div className="card action-card unwrap-card">
        <h3>Unwrap Alpha</h3>
        <p className="subtitle">Select a vault from the table above.</p>
      </div>
    );
  }

  return (
    <div className="card action-card unwrap-card">
      <h3>Unwrap Alpha</h3>
      <p className="subtitle">
        Burn <strong>{vault.symbol}</strong> shares and receive alpha stake back.
      </p>

      {/* Balance info */}
      <div className="preview-box">
        <div className="preview-row">
          <span>Your Shares</span>
          <span>{fmtUnits(userBalance)} {vault.symbol}</span>
        </div>
      </div>

      {/* Amount input */}
      <div className="input-group">
        <input
          type="text"
          placeholder="0.0"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        <span className="input-suffix">{vault.symbol}</span>
      </div>

      {/* Max button */}
      {userBalance > 0n && (
        <button
          className="btn btn-ghost btn-sm"
          style={{ marginBottom: '0.5rem' }}
          onClick={() => setAmount(formatUnits(userBalance, 18))}
        >
          MAX
        </button>
      )}

      {/* Preview */}
      {previewAlpha !== null && (
        <div className="preview-box">
          <div className="preview-row">
            <span>You will receive</span>
            <span>{fmtUnits(previewAlpha, 9)} {vault.letter}</span>
          </div>
        </div>
      )}

      {/* Unwrap button */}
      <button
        className="btn btn-danger btn-full"
        disabled={!amount || userBalance === 0n || unwrapping}
        onClick={handleUnwrap}
      >
        {unwrapping ? 'Unwrapping...' : 'Unwrap Alpha'}
      </button>
    </div>
  );
}
