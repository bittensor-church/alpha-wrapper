import { truncAddr } from '../utils/format';
import SubstrateWalletConnect from './SubstrateWalletConnect';

export default function Header({
  address,
  onConnect,
  substrateWallet,
  onConnectSubstrate,
}) {
  return (
    <header id="app-header">
      <div className="header-left">
        <div className="logo">
          <span className="logo-icon">A</span>
          Alpha Wrapper
        </div>
      </div>
      <div className="header-right">
        <div className="badge">
          <span className="badge-dot" />
          Bittensor Local
        </div>

        {/* Bittensor (Substrate) wallet */}
        <SubstrateWalletConnect
          isConnected={substrateWallet.isConnected}
          accounts={substrateWallet.accounts}
          selectedAccount={substrateWallet.selectedAccount}
          onConnect={onConnectSubstrate}
          onDisconnect={substrateWallet.disconnect}
          onSelectAccount={substrateWallet.selectAccount}
        />

        {/* MetaMask wallet */}
        {address ? (
          <div className="badge">
            <span className="badge-dot badge-dot-mm" />
            {truncAddr(address)}
          </div>
        ) : (
          <button className="btn btn-primary" onClick={onConnect}>
            Connect MetaMask
          </button>
        )}
      </div>
    </header>
  );
}
