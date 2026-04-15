import { useState, useEffect, useCallback } from 'react';
import { Contract, isAddress } from 'ethers';
import { VAULT_ABI } from './config';
import { useWallet } from './hooks/useWallet';
import { useVaults } from './hooks/useVaults';
import { useSubstrateWallet } from './hooks/useSubstrateWallet';
import Header from './components/Header';
import ConfigPanel from './components/ConfigPanel';
import VaultList from './components/VaultList';
import MyShares from './components/MyShares';
import WrapAlpha from './components/WrapAlpha';
import UnwrapAlpha from './components/UnwrapAlpha';
import StakeDistribution from './components/StakeDistribution';
import TxModal from './components/TxModal';

export default function App() {
  const { address, signer, readProvider, isConnected, connect } = useWallet();
  const { vaults, loading: vaultsLoading, refresh: refreshVaults } = useVaults();
  const substrateWallet = useSubstrateWallet();

  const [vaultContract, setVaultContract] = useState(null);
  const [vaultSigner, setVaultSigner] = useState(null);
  const [vaultAddr, setVaultAddr] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const [balances, setBalances] = useState({});
  const [txModal, setTxModal] = useState(null);
  const [status, setStatus] = useState(null);

  const addToMetaMask = async (vault) => {
    if (!window.ethereum || !vaultAddr) return;
    try {
      await window.ethereum.request({
        method: 'wallet_watchAsset',
        params: {
          type: 'ERC1155',
          options: {
            address: vaultAddr,
            tokenId: vault.id.toString(),
            symbol: vault.symbol,
            decimals: 18,
            image: '',
          },
        },
      });
    } catch (error) {
      console.error('Error adding asset to MetaMask:', error);
    }
  };

  const loadContract = useCallback(async (addr) => {
    if (!isAddress(addr)) {
      setStatus({ message: 'Invalid address', isError: true });
      return;
    }
    if (!readProvider) {
      setStatus({ message: 'Provider not ready', isError: true });
      return;
    }

    try {
      const code = await readProvider.getCode(addr);
      if (code === '0x') {
        setStatus({ message: 'No contract at this address', isError: true });
        return;
      }

      const vc = new Contract(addr, VAULT_ABI, readProvider);
      setVaultContract(vc);
      setVaultAddr(addr);

      if (signer) {
        setVaultSigner(new Contract(addr, VAULT_ABI, signer));
      }

      await refreshVaults(vc, readProvider);
      setStatus({ message: 'Contract loaded successfully' });
    } catch (e) {
      console.error('Load error:', e);
      setStatus({ message: 'Failed to load contract: ' + e.message, isError: true });
    }
  }, [readProvider, signer, refreshVaults]);

  // Update signer contract when wallet connects
  useEffect(() => {
    if (signer && vaultAddr) {
      setVaultSigner(new Contract(vaultAddr, VAULT_ABI, signer));
    }
  }, [signer, vaultAddr]);

  // Fetch user balances
  const refreshBalances = useCallback(async () => {
    if (!vaultContract || !address || vaults.length === 0) return;
    try {
      const bals = {};
      await Promise.all(
        vaults.map(async (v) => {
          bals[v.id] = await vaultContract.balanceOf(address, v.id);
        })
      );
      setBalances(bals);
    } catch (e) {
      console.error('Balance error:', e);
    }
  }, [vaultContract, address, vaults]);

  useEffect(() => {
    refreshBalances();
  }, [refreshBalances]);

  // Full refresh
  const refreshAll = useCallback(async () => {
    if (vaultContract) {
      await refreshVaults(vaultContract, readProvider);
    }
    await refreshBalances();
  }, [vaultContract, readProvider, refreshVaults, refreshBalances]);

  const handleConnect = async () => {
    try {
      await connect();
      setStatus({ message: 'MetaMask connected' });
    } catch (e) {
      setStatus({ message: 'Connection failed: ' + e.message, isError: true });
    }
  };

  const handleConnectSubstrate = async () => {
    try {
      await substrateWallet.connect();
      setStatus({ message: 'Bittensor wallet connected' });
    } catch (e) {
      setStatus({ message: 'Bittensor wallet: ' + e.message, isError: true });
    }
  };

  const contractLoaded = !!vaultContract;

  return (
    <>
      <Header
        address={address}
        onConnect={handleConnect}
        substrateWallet={substrateWallet}
        onConnectSubstrate={handleConnectSubstrate}
      />

      <main>
        {/* Status bar */}
        {status && (
          <div id="status-bar">
            <div className={`status-inner ${status.isError ? 'error' : ''}`}>
              {status.isError ? '!' : '+'} {status.message}
            </div>
          </div>
        )}

        {/* Config panel */}
        {!contractLoaded && (
          <ConfigPanel onLoad={loadContract} disabled={!readProvider} />
        )}

        {/* Dashboard */}
        {contractLoaded && (
          <>
            <MyShares vaults={vaults} balances={balances} onAddAsset={addToMetaMask} />

            <VaultList
              vaults={vaults}
              loading={vaultsLoading}
              selectedId={selectedId}
              onSelect={setSelectedId}
              onAddAsset={addToMetaMask}
            />

            {selectedId && (
              <StakeDistribution
                vault={vaults.find((v) => v.id === selectedId)}
                readProvider={readProvider}
                vaultContract={vaultContract}
              />
            )}

            <div className="action-grid">
              <WrapAlpha
                vaults={vaults}
                selectedId={selectedId}
                address={address}
                signer={signer}
                readProvider={readProvider}
                vaultContract={vaultContract}
                vaultSigner={vaultSigner}
                substrateWallet={substrateWallet}
                onTx={setTxModal}
                onDone={refreshAll}
              />
              <UnwrapAlpha
                vaults={vaults}
                selectedId={selectedId}
                balances={balances}
                address={address}
                vaultContract={vaultContract}
                vaultSigner={vaultSigner}
                onTx={setTxModal}
                onDone={refreshAll}
              />
            </div>

            <div style={{ textAlign: 'center', marginTop: '1rem' }}>
              <button className="btn btn-ghost btn-sm" onClick={refreshAll}>
                Refresh All
              </button>
            </div>
          </>
        )}
      </main>

      <TxModal
        isOpen={!!txModal}
        title={txModal?.title}
        message={txModal?.message}
        onClose={null}
      />
    </>
  );
}
