import { formatUnits as ethersFormat } from 'ethers';

export function truncAddr(addr) {
  if (!addr) return '';
  return addr.slice(0, 6) + '...' + addr.slice(-4);
}

export function fmtUnits(val, decimals = 18, precision = 4) {
  try {
    const s = ethersFormat(val, decimals);
    const n = parseFloat(s);
    if (n === 0) return '0';
    // Only return '<0.001' if we are not asking for high precision
    if (n < 0.001 && precision <= 4) return '<0.001';
    return n.toLocaleString('en-US', {
      maximumFractionDigits: precision,
      useGrouping: false
    });
  } catch {
    return '0';
  }
}

export function fmtPrice(price) {
  try {
    // price is RAO-per-share (normalized). At parity, it is 1e9.
    const multiplier = Number(price) / 1e9;
    return multiplier.toFixed(4) + 'x';
  } catch {
    return '1.0000x';
  }
}
