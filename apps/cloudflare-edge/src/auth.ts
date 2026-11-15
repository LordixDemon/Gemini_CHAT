/**
 * WebCrypto HMAC-SHA256 Token Signer & Constant-Time Verifier for Cloudflare Workers Edge.
 */

export const DEFAULT_DEV_EDGE_SECRET = 'dev-edge-signing-secret-change-in-prod';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function encodeBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function decodeBase64Url(b64url: string): Uint8Array | null {
  try {
    const base64 = b64url.replace(/-/g, '+').replace(/_/g, '/');
    const padLen = (4 - (base64.length % 4)) % 4;
    const binary = atob(base64 + '='.repeat(padLen));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  } catch {
    return null;
  }
}

export function timingSafeStringEqual(a: string, b: string): boolean {
  const bytesA = encoder.encode(String(a ?? ''));
  const bytesB = encoder.encode(String(b ?? ''));
  if (bytesA.byteLength !== bytesB.byteLength || bytesA.byteLength === 0) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < bytesA.byteLength; i++) {
    diff |= bytesA[i] ^ bytesB[i];
  }
  return diff === 0;
}

async function importHmacKey(
  secret: string,
  usages: Array<'sign' | 'verify'>,
): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    usages,
  );
}

export interface EdgeDeviceClaims {
  deviceId: string;
  sessionId: string;
  deviceName: string;
  issuedAt: number;
}

export async function mintEdgeDeviceToken(
  signingSecret: string,
  claims: EdgeDeviceClaims,
): Promise<string> {
  const payloadBytes = encoder.encode(JSON.stringify(claims));
  const payloadB64 = encodeBase64Url(payloadBytes);
  const key = await importHmacKey(signingSecret, ['sign']);
  const sigBuf = await crypto.subtle.sign('HMAC', key, encoder.encode(payloadB64));
  const sigB64 = encodeBase64Url(new Uint8Array(sigBuf));
  return `edge.${payloadB64}.${sigB64}`;
}

export async function verifyEdgeDeviceToken(
  signingSecret: string,
  token: string,
): Promise<EdgeDeviceClaims | null> {
  const parts = String(token || '').trim().split('.');
  if (parts.length !== 3 || parts[0] !== 'edge') return null;
  const [, payloadB64, sigB64] = parts;
  if (!payloadB64 || !sigB64) return null;

  const sigBytes = decodeBase64Url(sigB64);
  const payloadBytes = decodeBase64Url(payloadB64);
  if (!sigBytes || !payloadBytes) return null;

  const key = await importHmacKey(signingSecret, ['verify']);
  const valid = await crypto.subtle.verify('HMAC', key, sigBytes, encoder.encode(payloadB64));
  if (!valid) return null;

  try {
    const json = decoder.decode(payloadBytes);
    const parsed = JSON.parse(json) as EdgeDeviceClaims;
    if (!parsed || typeof parsed !== 'object') return null;
    if (!parsed.deviceId || !parsed.sessionId) return null;
    return parsed;
  } catch {
    return null;
  }
}
