import { useState, useEffect, useCallback } from 'react';
import { BrowserProvider, JsonRpcProvider } from 'ethers';
import { TARGET_CHAIN_HEX, CHAIN_CONFIG, DEFAULT_RPC } from '../config';

export function useWallet() {
  const [address, setAddress] = useState(null);
  const [signer, setSigner] = useState(null);
  const [readProvider, setReadProvider] = useState(null);

  useEffect(() => {
    setReadProvider(new JsonRpcProvider(DEFAULT_RPC));
  }, []);

  const connect = useCallback(async () => {
    if (!window.ethereum) throw new Error('MetaMask not found');

    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: TARGET_CHAIN_HEX }],
      });
    } catch (e) {
      if (e.code === 4902) {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [CHAIN_CONFIG],
        });
      } else {
        throw e;
      }
    }

    const provider = new BrowserProvider(window.ethereum, {
      chainId: parseInt(TARGET_CHAIN_HEX, 16),
      name: 'bittensor-local',
    });

    const s = await provider.getSigner();
    const addr = await s.getAddress();

    // Bittensor doesn't support EIP-1559 — force legacy (type 0) transactions.
    const origSend = s.sendTransaction.bind(s);
    s.sendTransaction = async (tx) => {
      const fee = await provider.getFeeData();
      const gasPrice = fee.gasPrice ?? 10_000_000_000n;
      return origSend({
        ...tx,
        type: 0,
        gasPrice,
        maxFeePerGas: null,
        maxPriorityFeePerGas: null,
      });
    };

    setSigner(s);
    setAddress(addr);
  }, []);

  useEffect(() => {
    if (!window.ethereum) return;

    const onAccounts = (accounts) => {
      if (accounts.length === 0) {
        setAddress(null);
        setSigner(null);
      } else {
        connect().catch(() => {});
      }
    };
    const onChain = () => window.location.reload();

    window.ethereum.on('accountsChanged', onAccounts);
    window.ethereum.on('chainChanged', onChain);
    return () => {
      window.ethereum.removeListener('accountsChanged', onAccounts);
      window.ethereum.removeListener('chainChanged', onChain);
    };
  }, [connect]);

  return { address, signer, readProvider, isConnected: !!address, connect };
}
