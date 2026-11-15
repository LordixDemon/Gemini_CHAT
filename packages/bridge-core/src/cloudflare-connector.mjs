/**
 * Pluggable Cloudflare Transport Connector for `@agy-remote/bridge-core`.
 *
 * Supports two zero-friction remote topologies when moving beyond local LAN:
 * 1. `edge-worker` (Recommended): Outbound WebSocket connection to Cloudflare Workers +
 *    Durable Objects (`SessionRoomDO`). Zero port forwarding, works behind any NAT,
 *    multiplexes N mobile devices, and supports Edge Session Management & Hibernation.
 * 2. `cloudflared`: Spawns `cloudflared tunnel --url http://127.0.0.1:<port>` (or Named Tunnel)
 *    and exposes a `https://*.trycloudflare.com` endpoint for instant external pairing.
 */
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { createEnvelope, parseEnvelope } from '@agy-remote/protocol';

export class CloudflareConnector extends EventEmitter {
  constructor() {
    super();
    this.mode = 'disabled'; // 'disabled' | 'edge-worker' | 'cloudflared'
    this.status = 'disconnected'; // 'disconnected' | 'connecting' | 'connected' | 'error'
    this.lastError = '';
    this.edgeUrl = '';
    this.publicPairBaseUrl = '';
    this.edgeMobileCount = 0;

    this._ws = null;
    this._reconnectTimer = null;
    this._heartbeatTimer = null;
    this._stopped = true;
    this._tunnelProc = null;
  }

  getState() {
    return {
      mode: this.mode,
      status: this.status,
      lastError: this.lastError,
      edgeUrl: this.edgeUrl,
      publicPairBaseUrl: this.publicPairBaseUrl,
      edgeMobileCount: this.edgeMobileCount,
    };
  }

  hasConnectedEdgeMobiles() {
    return this.status === 'connected' && this.edgeMobileCount > 0;
  }

  /**
   * Starts or reconfigures the Cloudflare link.
   * @param {{
   *   mode: 'disabled' | 'edge-worker' | 'cloudflared',
   *   edgeUrl?: string,
   *   edgeSecret?: string,
   *   machineId: string,
   *   machineName: string,
   *   localPort: number,
   *   getInitialSnapshot: () => any
   * }} cfg
   */
  configure(cfg) {
    this.stop();
    this.mode = cfg.mode || 'disabled';
    this.lastError = '';
    this.publicPairBaseUrl = '';
    this.edgeMobileCount = 0;

    if (this.mode === 'disabled') {
      this._setStatus('disconnected');
      return;
    }

    this._stopped = false;
    if (this.mode === 'edge-worker') {
      if (!cfg.edgeUrl) {
        this.lastError = 'Cloudflare Edge Worker URL is empty.';
        this._setStatus('error');
        return;
      }
      this.edgeUrl = cfg.edgeUrl.replace(/\/+$/, '');
      this.publicPairBaseUrl = this.edgeUrl;
      this._connectEdgeWorker(cfg);
    } else if (this.mode === 'cloudflared') {
      this._startCloudflaredTunnel(cfg.localPort);
    }
  }

  stop() {
    this._stopped = true;
    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    if (this._heartbeatTimer) {
      clearInterval(this._heartbeatTimer);
      this._heartbeatTimer = null;
    }
    if (this._ws) {
      try {
        this._ws.close();
      } catch {}
      this._ws = null;
    }
    if (this._tunnelProc) {
      try {
        this._tunnelProc.kill('SIGTERM');
      } catch {}
      this._tunnelProc = null;
    }
    this.edgeMobileCount = 0;
    this._setStatus('disconnected');
  }

  /**
   * Synchronizes the desktop's active 6-digit PIN & QR token to Cloudflare `SessionRoomDO`
   * so the same QR code / PIN works over 5G/LTE as well as local Wi-Fi.
   */
  async syncEdgePairing(pairing, edgeSecret = '') {
    if (this.mode !== 'edge-worker' || !this.edgeUrl || !pairing) return;
    try {
      await fetch(`${this.edgeUrl}/api/edge/pair-create`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(edgeSecret ? { 'X-Host-Secret': edgeSecret } : {}),
        },
        body: JSON.stringify(pairing),
      });
    } catch {
      // Ignore transient sync error
    }
  }

  /**
   * Forwards an ARP v1 envelope to all mobile clients connected via Cloudflare Durable Object.
   */
  sendToEdge(envelope) {
    if (!this._ws || this.status !== 'connected') return false;
    try {
      this._ws.send(JSON.stringify(envelope));
      return true;
    } catch {
      return false;
    }
  }

  _connectEdgeWorker(cfg) {
    if (this._stopped) return;
    if (typeof globalThis.WebSocket !== 'function') {
      this.lastError = 'Global WebSocket client unavailable in this Node version (requires Node 21+).';
      this._setStatus('error');
      return;
    }

    this._setStatus('connecting');
    const wsBase = this.edgeUrl.replace(/^http:/i, 'ws:').replace(/^https:/i, 'wss:');
    const u = new URL(`${wsBase}/ws/host`);
    u.searchParams.set('machineId', cfg.machineId);
    u.searchParams.set('machineName', cfg.machineName);
    if (cfg.edgeSecret) u.searchParams.set('secret', cfg.edgeSecret);

    const ws = new globalThis.WebSocket(u.toString());
    this._ws = ws;

    ws.addEventListener('open', () => {
      if (this._stopped) return;
      this.lastError = '';
      this._setStatus('connected');

      // Push initial snapshot so SessionRoomDO caches sessions immediately
      if (typeof cfg.getInitialSnapshot === 'function') {
        this.sendToEdge(createEnvelope('host.snapshot', cfg.getInitialSnapshot()));
      }
      if (typeof cfg.getPairing === 'function') {
        void this.syncEdgePairing(cfg.getPairing(), cfg.edgeSecret);
      }

      this._heartbeatTimer = setInterval(() => {
        this.sendToEdge(createEnvelope('host.ping', { machineId: cfg.machineId }));
      }, 20_000);
      this._heartbeatTimer.unref?.();
    });

    ws.addEventListener('message', (ev) => {
      const env = parseEnvelope(typeof ev.data === 'string' ? ev.data : String(ev.data));
      if (!env) return;

      if (env.type === 'edge.presence') {
        this.edgeMobileCount = Number(env.payload?.mobileCount || 0);
        this.emit('state_changed', this.getState());
        return;
      }

      // Forward mobile RPC command coming from Cloudflare DO -> BridgeServer
      this.emit('edge_message', env);
    });

    ws.addEventListener('error', () => {
      this.lastError = 'Failed to reach Cloudflare Edge Worker WebSocket.';
    });

    ws.addEventListener('close', () => {
      if (this._heartbeatTimer) {
        clearInterval(this._heartbeatTimer);
        this._heartbeatTimer = null;
      }
      this.edgeMobileCount = 0;
      if (this._stopped) return;
      this._setStatus('connecting');
      this._reconnectTimer = setTimeout(() => this._connectEdgeWorker(cfg), 4000);
      this._reconnectTimer.unref?.();
    });
  }

  _startCloudflaredTunnel(localPort) {
    this._setStatus('connecting');
    let cmd = process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared';
    if (process.platform === 'darwin') {
      if (existsSync('/opt/homebrew/bin/cloudflared')) cmd = '/opt/homebrew/bin/cloudflared';
      else if (existsSync('/usr/local/bin/cloudflared')) cmd = '/usr/local/bin/cloudflared';
    }
    const proc = spawn(cmd, ['tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${localPort}`], {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    this._tunnelProc = proc;

    const inspectLog = (chunk) => {
      const text = chunk.toString('utf-8');
      const match = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/i.exec(text);
      if (match && this.publicPairBaseUrl !== match[0]) {
        this.publicPairBaseUrl = match[0];
        this.edgeUrl = match[0];
        this.lastError = '';
        this._setStatus('connected');
      }
    };

    proc.stdout.on('data', inspectLog);
    proc.stderr.on('data', inspectLog);
    proc.on('error', (err) => {
      this.lastError =
        err.code === 'ENOENT'
          ? 'cloudflared CLI not installed on PATH. Use Cloudflare Edge Worker mode or install cloudflared.'
          : err.message;
      this._setStatus('error');
    });
    proc.on('close', (code) => {
      this._tunnelProc = null;
      if (!this._stopped && this.status !== 'error') {
        this.lastError = `cloudflared exited (${code ?? -1})`;
        this._setStatus('disconnected');
      }
    });
  }

  _setStatus(st) {
    this.status = st;
    this.emit('state_changed', this.getState());
  }
}
