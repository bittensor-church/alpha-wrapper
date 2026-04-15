import { useState, useEffect } from 'react';
import { Contract, parseUnits, formatUnits } from 'ethers';
import { h160ToSubstrate, substrateToSS58 } from '../utils/substrate';
import { fmtUnits, truncAddr } from '../utils/format';
import { STAKING_ABI, STAKING_ADDRESS } from '../config';

export default function WrapAlpha({
  vaults,
  selectedId,
  address,
  signer,
  readProvider,
  vaultContract,
  vaultSigner,
  substrateWallet,
  onTx,
  onDone,
}) {
  const [amount, setAmount] = useState('');
  const [alphaBalance, setAlphaBalance] = useState(null);
  const [stakePositions, setStakePositions] = useState([]); // [{hotkey, balance}] — all hotkeys with user's stake
  const [previewShares, setPreviewShares] = useState(null);
  const [cloneAddr, setCloneAddr] = useState(null);
  const [step, setStep] = useState('idle'); // idle | step1 | step2 | done
  const [mode, setMode] = useState('evm'); // 'evm' | 'bittensor'

  const vault = vaults.find((v) => v.id === selectedId);

  const isBittensorMode = mode === 'bittensor';
  const subConnected = substrateWallet?.isConnected;
  const ss58Address = substrateWallet?.ss58Address;

  // Load alpha balance + clone address when vault selected
  useEffect(() => {
    if (!vault || !readProvider || !vaultContract) {
      setAlphaBalance(null);
      setStakePositions([]);
      setCloneAddr(null);
      return;
    }

    // In EVM mode, need MetaMask address; in Bittensor mode, need SS58 address
    if (!isBittensorMode && !address) {
      setAlphaBalance(null);
      setStakePositions([]);
      setCloneAddr(null);
      return;
    }
    if (isBittensorMode && !ss58Address) {
      setAlphaBalance(null);
      setStakePositions([]);
      setCloneAddr(null);
      return;
    }

    let cancelled = false;
    (async () => {
      try {
        const staking = new Contract(STAKING_ADDRESS, STAKING_ABI, readProvider);
        const ZERO = '0x' + '0'.repeat(64);

        // Resolve user's coldkey
        let coldkeySub;
        if (isBittensorMode) {
          const { decodeAddress } = await import('@polkadot/util-crypto');
          const pubBytes = decodeAddress(ss58Address);
          coldkeySub = '0x' + Array.from(pubBytes).map(b => b.toString(16).padStart(2, '0')).join('');
        } else {
          coldkeySub = h160ToSubstrate(address);
        }

        // Read registry validators (only these are accepted by processDeposit)
        const topValidators = await vaultContract.getBestValidators(vault.netuid);
        const registryHotkeys = topValidators.filter(hk => hk !== ZERO);

        // Check user's stake on each registry validator
        const hotkeyChecks = registryHotkeys.map(async (hk) => {
          const bal = await staking.getStake(hk, coldkeySub, vault.netuid);
          return { hotkey: hk, balance: bal };
        });
        const results = await Promise.all(hotkeyChecks);

        // Keep only positions with balance > 0
        const positions = results.filter(r => r.balance > 0n);
        const totalBal = positions.reduce((sum, r) => sum + r.balance, 0n);

        // Clone address is always based on MetaMask address (shares go to EVM address)
        const clone = address ? await vaultContract.getDepositAddress(address, vault.id) : null;

        if (!cancelled) {
          setAlphaBalance(totalBal);
          setStakePositions(positions);
          setCloneAddr(clone);
        }
      } catch (e) {
        console.error('WrapAlpha load error:', e);
      }
    })();
    return () => { cancelled = true; };
  }, [vault, address, ss58Address, isBittensorMode, readProvider, vaultContract]);

  // Preview shares on amount change
  useEffect(() => {
    if (!vault || !amount || !vaultContract) {
      setPreviewShares(null);
      return;
    }
    let cancelled = false;
    const timer = setTimeout(async () => {
      try {
        const rao = parseUnits(amount, 9);
        const shares = await vaultContract.previewDeposit(vault.id, rao);
        if (!cancelled) setPreviewShares(shares);
      } catch {
        if (!cancelled) setPreviewShares(null);
      }
    }, 400);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [vault, amount, vaultContract]);

  // Reset amount when mode changes
  useEffect(() => {
    setAmount('');
    setPreviewShares(null);
  }, [mode]);

  const handleWrap = async () => {
    if (!vault || !amount || !cloneAddr || stakePositions.length === 0) return;

    try {
      let remaining = parseUnits(amount, 9);
      const cloneSub = h160ToSubstrate(cloneAddr);

      // Step 1: Transfer stake to clone from each hotkey until amount is covered
      setStep('step1');

      const transferCount = stakePositions.filter(p => p.balance > 0n).length;
      let txIdx = 0;

      for (const pos of stakePositions) {
        if (remaining <= 0n) break;

        const transferAmt = remaining > pos.balance ? pos.balance : remaining;
        remaining -= transferAmt;
        txIdx++;

        if (isBittensorMode) {
          if (!substrateWallet?.api || !substrateWallet?.injector) {
            throw new Error('Bittensor wallet not fully connected');
          }

          onTx({
            title: `Step 1/${1 + transferCount}: Transfer Alpha (${txIdx}/${transferCount})`,
            message: 'Sign the transfer in your Bittensor wallet extension...',
          });

          const { api, injector } = substrateWallet;
          const cloneSS58 = substrateToSS58(cloneSub);
          const hotkeySS58 = substrateToSS58(pos.hotkey);

          const tx = api.tx.subtensorModule.transferStake(
            cloneSS58,
            hotkeySS58,
            vault.netuid,
            vault.netuid,
            transferAmt.toString(),
          );

          await new Promise((resolve, reject) => {
            tx.signAndSend(ss58Address, { signer: injector.signer }, ({ status, dispatchError }) => {
              if (dispatchError) {
                if (dispatchError.isModule) {
                  const decoded = api.registry.findMetaError(dispatchError.asModule);
                  reject(new Error(`${decoded.section}.${decoded.name}: ${decoded.docs.join(' ')}`));
                } else {
                  reject(new Error(dispatchError.toString()));
                }
              } else if (status.isInBlock || status.isFinalized) {
                resolve();
              }
            }).catch(reject);
          });
        } else {
          if (!signer) return;

          onTx({
            title: `Step 1: Transfer Alpha (${txIdx}/${transferCount})`,
            message: `Transferring alpha from validator ${txIdx}/${transferCount}...`,
          });

          const stakingSigner = new Contract(STAKING_ADDRESS, STAKING_ABI, signer);

          const tx1 = await stakingSigner.transferStake(
            cloneSub,
            pos.hotkey,
            vault.netuid,
            vault.netuid,
            transferAmt,
            { gasLimit: 300000 }
          );
          await tx1.wait();
        }
      }

      // Step 2: processDeposit (always MetaMask)
      if (!vaultSigner) {
        throw new Error('MetaMask not connected — needed for step 2');
      }

      setStep('step2');
      onTx({ title: 'Step 2: Mint Shares', message: 'Processing deposit and minting vault shares...' });

      const tx2 = await vaultSigner.processDeposit(address, vault.id, cloneSub, { gasLimit: 1000000 });
      await tx2.wait();

      setStep('done');
      setAmount('');
      setPreviewShares(null);
      onTx(null);
      onDone();

      // Reset to idle after 4 seconds
      setTimeout(() => setStep('idle'), 4000);
    } catch (e) {
      console.error('Wrap error:', e);
      onTx(null);
      setStep('idle');
      alert('Transaction failed: ' + (e.reason || e.message));
    }
  };

  if (!vault) {
    return (
      <div className="card action-card wrap-card">
        <h3>Wrap Alpha</h3>
        <p className="subtitle">Select a vault from the table above.</p>
      </div>
    );
  }

  const canWrap = isBittensorMode
    ? !!amount && step === 'idle' && subConnected && !!address && !!cloneAddr && stakePositions.length > 0
    : !!amount && step === 'idle' && !!signer && !!cloneAddr && stakePositions.length > 0;

  return (
    <div className="card action-card wrap-card">
      <h3>Wrap Alpha</h3>
      <p className="subtitle">
        Transfer alpha stake into <strong>{vault.name}</strong> ({vault.symbol})
      </p>

      {/* Mode toggle */}
      <div className="mode-toggle">
        <button
          className={`mode-btn ${mode === 'evm' ? 'mode-active' : ''}`}
          onClick={() => setMode('evm')}
        >
          EVM Wallet
        </button>
        <button
          className={`mode-btn ${mode === 'bittensor' ? 'mode-active' : ''}`}
          onClick={() => setMode('bittensor')}
        >
          Bittensor Wallet
        </button>
      </div>

      {/* Bittensor mode notice */}
      {isBittensorMode && !subConnected && (
        <div className="preview-box" style={{ borderColor: 'var(--warn)', background: 'var(--warn-bg)' }}>
          <div className="preview-row">
            <span style={{ color: 'var(--warn)' }}>Connect a Bittensor wallet in the header to use this mode.</span>
          </div>
        </div>
      )}
      {isBittensorMode && subConnected && !address && (
        <div className="preview-box" style={{ borderColor: 'var(--warn)', background: 'var(--warn-bg)' }}>
          <div className="preview-row">
            <span style={{ color: 'var(--warn)' }}>MetaMask also needed — shares are minted to your EVM address.</span>
          </div>
        </div>
      )}

      {/* Alpha balance info */}
      <div className="preview-box">
        <div className="preview-row">
          <span>Your {vault.letter} Stake {isBittensorMode ? '(SS58)' : '(EVM)'}</span>
          <span>{alphaBalance !== null ? `${fmtUnits(alphaBalance, 9)} ${vault.letter}` : '...'}</span>
        </div>
        {isBittensorMode && ss58Address && (
          <div className="preview-row">
            <span>Source Account</span>
            <span>{truncAddr(ss58Address)}</span>
          </div>
        )}
        <div className="preview-row">
          <span>Deposit Address</span>
          <span>{cloneAddr ? truncAddr(cloneAddr) : '...'}</span>
        </div>
      </div>

      {/* Stake positions per validator */}
      {stakePositions.length > 0 && (
        <div className="preview-box" style={{ marginTop: '0.5rem' }}>
          <div className="preview-row" style={{ fontWeight: 600, marginBottom: '0.25rem' }}>
            <span>Validator Hotkey</span>
            <span>Your Stake</span>
          </div>
          {stakePositions.map((pos, i) => (
            <div key={i} className="preview-row" style={{ fontSize: '0.85rem' }}>
              <span style={{ fontFamily: 'monospace' }}>{truncAddr(pos.hotkey)}</span>
              <span>{fmtUnits(pos.balance, 9)} {vault.letter}</span>
            </div>
          ))}
          {stakePositions.length > 1 && (
            <div className="preview-row" style={{ fontSize: '0.8rem', opacity: 0.7, marginTop: '0.25rem' }}>
              <span>{stakePositions.length} transfers will be sent</span>
            </div>
          )}
        </div>
      )}

      {/* Amount input */}
      <div className="input-group">
        <input
          type="text"
          placeholder="0.0"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        <span className="input-suffix">{vault.letter}</span>
      </div>

      {/* Max button */}
      {alphaBalance !== null && alphaBalance > 0n && (
        <button
          className="btn btn-ghost btn-sm"
          style={{ marginBottom: '0.5rem' }}
          onClick={() => setAmount(formatUnits(alphaBalance, 9))}
        >
          MAX
        </button>
      )}

      {/* Preview */}
      {previewShares !== null && (
        <div className="preview-box">
          <div className="preview-row">
            <span>You will receive</span>
            <span>{fmtUnits(previewShares)} {vault.symbol}</span>
          </div>
        </div>
      )}

      {/* Wrap button */}
      <button
        className="btn btn-accent btn-full"
        disabled={!canWrap}
        onClick={handleWrap}
      >
        {step === 'idle'
          ? (isBittensorMode ? 'Wrap Alpha (Bittensor)' : 'Wrap Alpha')
          : step === 'step1'
            ? 'Transferring...'
            : step === 'step2'
              ? 'Minting Shares...'
              : 'Success! ✅'}
      </button>
    </div>
  );
}
