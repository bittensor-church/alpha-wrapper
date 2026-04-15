import { useState, useCallback, useRef } from 'react';
import { ApiPromise, WsProvider } from '@polkadot/api';
import { web3Enable, web3Accounts, web3FromSource } from '@polkadot/extension-dapp';
import { DEFAULT_WS_URL } from '../config';

export function useSubstrateWallet() {
  const [accounts, setAccounts] = useState([]);
  const [selectedAccount, setSelectedAccount] = useState(null);
  const [injector, setInjector] = useState(null);
  const [api, setApi] = useState(null);
  const [isConnected, setIsConnected] = useState(false);
  const apiRef = useRef(null);

  const connect = useCallback(async () => {
    const extensions = await web3Enable('TAO20 Alpha Wrapper');
    if (extensions.length === 0) {
      throw new Error('No Polkadot.js compatible extension found. Install Polkadot.js, Talisman, or SubWallet.');
    }

    const allAccounts = await web3Accounts();
    if (allAccounts.length === 0) {
      throw new Error('No accounts found. Please create or import an account in your wallet extension.');
    }

    // Connect to Bittensor WS endpoint if not already connected
    if (!apiRef.current) {
      const provider = new WsProvider(DEFAULT_WS_URL);
      const apiInstance = await ApiPromise.create({ provider });
      apiRef.current = apiInstance;
      setApi(apiInstance);
    }

    setAccounts(allAccounts);
    setIsConnected(true);

    // Auto-select first account
    const first = allAccounts[0];
    const inj = await web3FromSource(first.meta.source);
    setSelectedAccount(first);
    setInjector(inj);

    return allAccounts;
  }, []);

  const selectAccount = useCallback(async (account) => {
    const inj = await web3FromSource(account.meta.source);
    setSelectedAccount(account);
    setInjector(inj);
  }, []);

  const disconnect = useCallback(() => {
    setAccounts([]);
    setSelectedAccount(null);
    setInjector(null);
    setIsConnected(false);
    // Keep API connection alive for reuse
  }, []);

  return {
    accounts,
    selectedAccount,
    ss58Address: selectedAccount?.address || null,
    injector,
    api,
    isConnected,
    connect,
    disconnect,
    selectAccount,
  };
}
