/**
 * Local Wi-Fi Discovery Beacon (`LanDiscoveryBeacon`):
 * 1. Responds to UDP LAN discovery probes (`AGY_REMOTE_DISCOVER_V1`) on port 7445 so phones
 *    automatically find the Mac (and heal DHCP IP changes) without re-scanning QR codes.
 * 2. Advertises `_agy-remote._tcp` via macOS native Bonjour (`/usr/bin/dns-sd -R`) when available.
 */
import { spawn } from 'node:child_process';
import { createSocket } from 'node:dgram';
import { existsSync } from 'node:fs';

export const DEFAULT_DISCOVERY_UDP_PORT = 7445;
export const DISCOVERY_PROBE_MAGIC = 'AGY_REMOTE_DISCOVER_V1';

export class LanDiscoveryBeacon {
  /**
   * @param {{
   *   udpPort?: number,
   *   enableMdns?: boolean,
   *   getInfo: () => { machineId: string, machineName: string, port: number, lanIp: string }
   * }} opts
   */
  constructor(opts) {
    this.udpPort = opts.udpPort ?? DEFAULT_DISCOVERY_UDP_PORT;
    this.enableMdns = opts.enableMdns ?? process.platform === 'darwin';
    this.getInfo = opts.getInfo;
    this.udpSocket = null;
    this.boundUdpPort = 0;
    this.mdnsProc = null;
  }

  async start() {
    if (this.udpPort !== false && this.udpPort >= 0) {
      await this._startUdpResponder();
    }
    if (this.enableMdns) {
      this._startMdnsBonjour();
    }
  }

  stop() {
    if (this.udpSocket) {
      try {
        this.udpSocket.close();
      } catch {}
      this.udpSocket = null;
      this.boundUdpPort = 0;
    }
    if (this.mdnsProc) {
      try {
        this.mdnsProc.kill('SIGTERM');
      } catch {}
      this.mdnsProc = null;
    }
  }

  _startUdpResponder() {
    return new Promise((resolve) => {
      let settled = false;
      const finish = () => {
        if (!settled) {
          settled = true;
          resolve();
        }
      };

      try {
        const sock = createSocket({ type: 'udp4', reuseAddr: true });
        sock.on('error', () => {
          try {
            sock.close();
          } catch {}
          if (this.udpSocket === sock) this.udpSocket = null;
          finish();
        });

        sock.on('message', (msg, rinfo) => {
          const text = msg.toString('utf-8').trim();
          if (!text.startsWith(DISCOVERY_PROBE_MAGIC)) return;
          const info = this.getInfo();
          if (!info?.port) return;
          const payload = JSON.stringify({
            v: 'arp.v1',
            type: 'bridge.beacon',
            machineId: info.machineId,
            machineName: info.machineName,
            port: info.port,
            lanIp: info.lanIp,
            lanUrl: `http://${info.lanIp}:${info.port}`,
            ts: Date.now(),
          });
          try {
            sock.send(Buffer.from(payload, 'utf-8'), rinfo.port, rinfo.address);
          } catch {}
        });

        sock.bind(this.udpPort, '0.0.0.0', () => {
          this.udpSocket = sock;
          const addr = sock.address();
          this.boundUdpPort = typeof addr === 'object' && addr ? addr.port : this.udpPort;
          sock.unref?.();
          finish();
        });
      } catch {
        finish();
      }
    });
  }

  _startMdnsBonjour() {
    const info = this.getInfo();
    if (!info?.port || info.port <= 0) return;
    const dnsSdBin = '/usr/bin/dns-sd';
    if (!existsSync(dnsSdBin)) return;

    try {
      const cleanName = String(info.machineName || 'Antigravity-Mac')
        .replace(/\.local$/i, '')
        .slice(0, 48);
      const proc = spawn(
        dnsSdBin,
        [
          '-R',
          cleanName,
          '_agy-remote._tcp',
          'local',
          String(info.port),
          `machineId=${info.machineId}`,
          `lanIp=${info.lanIp}`,
          'v=1.2',
        ],
        { stdio: 'ignore', windowsHide: true },
      );
      proc.on('error', () => {});
      proc.unref?.();
      this.mdnsProc = proc;
    } catch {}
  }
}
