/**
 * Authentication, Pairing (QR Token + 6-digit PIN), Device Registry,
 * Persistent Host State, and Smart LAN IPv4 Interface Discovery.
 */
import { createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, hostname, networkInterfaces } from 'node:os';
import { dirname, join } from 'node:path';

const PAIRING_TTL_MS = 10 * 60 * 1000; // 10 minutes per rotating PIN/QR

function safeEqual(a, b) {
  const bufA = Buffer.from(String(a ?? ''), 'utf-8');
  const bufB = Buffer.from(String(b ?? ''), 'utf-8');
  if (bufA.length === 0 || bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

export function defaultStateDir() {
  return join(homedir(), '.gemini', 'antigravity-remote');
}

export function runtimeDiscoveryPath(stateDir = defaultStateDir()) {
  return join(stateDir, 'bridge-runtime.json');
}

/**
 * Discovers candidate LAN IPv4 addresses sorted by likelihood of being
 * the real Wi-Fi / Ethernet LAN interface reachable by the user's phone.
 */
export function discoverLanAddresses() {
  const nets = networkInterfaces();
  const candidates = [];

  for (const [ifName, addrs] of Object.entries(nets || {})) {
    for (const addr of addrs || []) {
      if (addr.internal || (addr.family !== 'IPv4' && addr.family !== 4)) continue;
      const ip = addr.address;
      if (!ip || ip.startsWith('169.254.')) continue;

      const virtualRe = /vEthernet|WSL|Docker|VMware|VirtualBox|Hyper-V|Loopback|vboxnet|br-|docker0/i;
      const tailscaleRe = /Tailscale|utun/i;
      const wifiEthRe = /Wi-Fi|Wireless|WLAN|Ethernet|en0|eth0|wlan0|Беспроводная/i;

      let score = 50;
      if (virtualRe.test(ifName)) score -= 40;
      if (wifiEthRe.test(ifName)) score += 30;
      if (ip.startsWith('192.168.')) score += 20;
      else if (ip.startsWith('10.')) score += 15;
      else if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(ip)) score += 10;
      else if (tailscaleRe.test(ifName) || ip.startsWith('100.')) score += 5;

      candidates.push({ interface: ifName, address: ip, score });
    }
  }

  candidates.sort((a, b) => b.score - a.score);
  return candidates;
}

export class AuthManager {
  /**
   * @param {{ stateDir?: string }} [opts]
   */
  constructor(opts = {}) {
    this.stateDir = opts.stateDir || defaultStateDir();
    this.stateFile = join(this.stateDir, 'state.json');
    this.state = this._loadOrCreateState();
    this.pairing = this.rotatePairing();
  }

  _loadOrCreateState() {
    mkdirSync(this.stateDir, { recursive: true });
    if (existsSync(this.stateFile)) {
      try {
        const parsed = JSON.parse(readFileSync(this.stateFile, 'utf-8'));
        if (parsed && parsed.machineId && parsed.signingSecret) {
          parsed.devices = parsed.devices && typeof parsed.devices === 'object' ? parsed.devices : {};
          parsed.settings = parsed.settings && typeof parsed.settings === 'object' ? parsed.settings : {};
          return parsed;
        }
      } catch {}
    }

    const fresh = {
      machineId: `mach_${randomBytes(8).toString('hex')}`,
      machineName: hostname() || 'Antigravity-PC',
      signingSecret: randomBytes(32).toString('hex'),
      ipcSecret: randomBytes(24).toString('hex'),
      devices: {},
      settings: {
        approvalMode: 'ask-mobile',
        preferredLanIp: '',
        cloudflareMode: 'disabled', // 'disabled' | 'edge-worker' | 'cloudflared'
        cloudflareEdgeUrl: '',
        cloudflareEdgeSecret: '',
      },
    };
    this._saveState(fresh);
    return fresh;
  }

  _saveState(st = this.state) {
    mkdirSync(dirname(this.stateFile), { recursive: true });
    writeFileSync(this.stateFile, JSON.stringify(st, null, 2), { mode: 0o600 });
  }

  updateSettings(patch = {}) {
    Object.assign(this.state.settings, patch);
    this._saveState();
    return { ...this.state.settings };
  }

  getSettings() {
    return { ...this.state.settings };
  }

  rotatePairing() {
    const pinNum = randomInt(100000, 999999);
    this.pairing = {
      pin: String(pinNum),
      token: randomBytes(24).toString('base64url'),
      createdAt: Date.now(),
      expiresAt: Date.now() + PAIRING_TTL_MS,
    };
    return this.getPairingInfo();
  }

  getPairingInfo() {
    if (Date.now() > this.pairing.expiresAt) {
      this.rotatePairing();
    }
    return {
      pin: this.pairing.pin,
      token: this.pairing.token,
      expiresAt: this.pairing.expiresAt,
      machineId: this.state.machineId,
      machineName: this.state.machineName,
    };
  }

  /**
   * Validates either a QR one-time token OR a 6-digit PIN and issues a long-lived device token.
   */
  pairDevice({ token, pin, deviceName = 'Mobile Device', platform = 'mobile' }) {
    const active = this.getPairingInfo();
    const cleanPin = String(pin || '').replace(/[\s-]/g, '');
    const cleanToken = String(token || '').trim();

    const tokenMatch = Boolean(cleanToken) && safeEqual(cleanToken, active.token);
    const pinMatch = cleanPin.length === 6 && safeEqual(cleanPin, active.pin);

    if (!tokenMatch && !pinMatch) {
      return { ok: false, error: 'Invalid or expired pairing code / QR token.' };
    }

    const deviceId = `dev_${randomBytes(8).toString('hex')}`;
    const issuedAt = Date.now();
    const sig = this._signDevice(deviceId, issuedAt);
    const deviceToken = `${deviceId}.${issuedAt}.${sig}`;

    this.state.devices[deviceId] = {
      id: deviceId,
      name: String(deviceName).slice(0, 64),
      platform: String(platform).slice(0, 32),
      pairedAt: issuedAt,
      lastSeenAt: issuedAt,
    };
    this._saveState();

    // Rotate one-time pairing secret after successful pairing so QR cannot be replayed
    this.rotatePairing();

    return {
      ok: true,
      deviceId,
      deviceToken,
      machineId: this.state.machineId,
      machineName: this.state.machineName,
    };
  }

  verifyDeviceToken(rawToken = '') {
    const parts = String(rawToken || '').trim().split('.');
    if (parts.length !== 3) return null;
    const [deviceId, issuedAtStr, sig] = parts;
    const record = this.state.devices[deviceId];
    if (!record) return null;

    const expected = this._signDevice(deviceId, Number(issuedAtStr));
    if (!safeEqual(sig, expected)) return null;

    record.lastSeenAt = Date.now();
    return record;
  }

  verifyIpcSecret(secret = '') {
    return safeEqual(secret, this.state.ipcSecret);
  }

  listDevices() {
    return Object.values(this.state.devices).sort((a, b) => b.lastSeenAt - a.lastSeenAt);
  }

  revokeDevice(deviceId) {
    if (!this.state.devices[deviceId]) return false;
    delete this.state.devices[deviceId];
    this._saveState();
    return true;
  }

  writeRuntimeDiscovery(port, extra = {}) {
    const file = runtimeDiscoveryPath(this.stateDir);
    writeFileSync(
      file,
      JSON.stringify(
        {
          pid: process.pid,
          port,
          machineId: this.state.machineId,
          machineName: this.state.machineName,
          ipcSecret: this.state.ipcSecret,
          startedAt: Date.now(),
          ...extra,
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
  }

  clearRuntimeDiscovery() {
    try {
      rmSync(runtimeDiscoveryPath(this.stateDir), { force: true });
    } catch {}
  }

  _signDevice(deviceId, issuedAt) {
    return createHmac('sha256', this.state.signingSecret)
      .update(`${this.state.machineId}:${deviceId}:${issuedAt}`)
      .digest('base64url');
  }
}

