import { blake2b } from 'blakejs';
import { encodeAddress } from '@polkadot/util-crypto';
import { BITTENSOR_SS58_PREFIX } from '../config';

/**
 * Convert an EVM H160 address to its Bittensor substrate account ID (bytes32).
 * Mapping: blake2b("evm:" + h160_bytes, digest_size=32)
 */
export function h160ToSubstrate(h160Hex) {
  const clean = h160Hex.replace('0x', '');
  const h160 = new Uint8Array(clean.match(/.{1,2}/g).map(b => parseInt(b, 16)));
  const prefix = new TextEncoder().encode('evm:');
  const input = new Uint8Array(prefix.length + h160.length);
  input.set(prefix);
  input.set(h160, prefix.length);
  const hash = blake2b(input, null, 32);
  return '0x' + Array.from(hash).map(b => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Convert a bytes32 substrate account ID (hex) to SS58 address.
 */
export function substrateToSS58(bytes32Hex) {
  const clean = bytes32Hex.replace('0x', '');
  const bytes = new Uint8Array(clean.match(/.{1,2}/g).map(b => parseInt(b, 16)));
  return encodeAddress(bytes, BITTENSOR_SS58_PREFIX);
}
