import { useState } from 'react';
import { DEFAULT_VAULT_ADDR } from '../config';

export default function ConfigPanel({ onLoad, disabled }) {
  const [addr, setAddr] = useState(DEFAULT_VAULT_ADDR);

  return (
    <section className="card">
      <h2>Contract Configuration</h2>
      <p className="subtitle">Enter the deployed AlphaVault address to connect.</p>
      <div className="form-group" style={{ marginBottom: '1rem' }}>
        <label>AlphaVault (ERC1155)</label>
        <input
          type="text"
          value={addr}
          onChange={(e) => setAddr(e.target.value)}
          placeholder="0x..."
          spellCheck={false}
        />
      </div>
      <button
        className="btn btn-accent"
        disabled={disabled || !addr}
        onClick={() => onLoad(addr)}
      >
        Load Contract
      </button>
    </section>
  );
}
