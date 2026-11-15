/**
 * Public exports of `@agy-remote/bridge-core` + smart singleton Attach-or-Host helper
 * so Antigravity Sidecar, VS Code Extension, and CLI share one active Bridge cleanly!
 */
import { existsSync, readFileSync } from 'node:fs';
import { DEFAULT_BRIDGE_PORT } from '@agy-remote/protocol';
import { AuthManager, defaultStateDir, discoverLanAddresses, runtimeDiscoveryPath } from './auth-manager.mjs';
import { BrainWatcher } from './brain-watcher.mjs';
import { AcpSessionRunner } from './acp-runner.mjs';
import { AgentDriver } from './agent-driver.mjs';
import { ApprovalGate } from './approval-gate.mjs';
import { ChangeTracker, computeUnifiedTextDiff } from './change-tracker.mjs';
import { CloudflareConnector } from './cloudflare-connector.mjs';
import { BridgeServer } from './lan-server.mjs';
import {
  DEFAULT_DISCOVERY_UDP_PORT,
  DISCOVERY_PROBE_MAGIC,
  LanDiscoveryBeacon,
} from './lan-discovery-beacon.mjs';
import { WsPeer, upgradeToWebSocket } from './rfc6455-ws.mjs';
import { dispatchClientRpc } from './rpc-router.mjs';
import {
  applyCorsHeaders,
  extractBearerToken,
  readJsonBody,
  sendJson,
  serveStaticAsset,
} from './http-helpers.mjs';

export {
  AuthManager,
  BrainWatcher,
  AcpSessionRunner,
  AgentDriver,
  ApprovalGate,
  ChangeTracker,
  computeUnifiedTextDiff,
  CloudflareConnector,
  BridgeServer,
  LanDiscoveryBeacon,
  DEFAULT_DISCOVERY_UDP_PORT,
  DISCOVERY_PROBE_MAGIC,
  WsPeer,
  upgradeToWebSocket,
  dispatchClientRpc,
  applyCorsHeaders,
  extractBearerToken,
  readJsonBody,
  sendJson,
  serveStaticAsset,
  discoverLanAddresses,
  defaultStateDir,
  runtimeDiscoveryPath,
};

/**
 * IPC client used when another local surface (e.g. Antigravity Sidecar or CLI)
 * has already bound the Bridge port on this machine.
 */
export class BridgeIpcClient {
  constructor({ port, ipcSecret, defaultWorkspace = '', stateDir = '' }) {
    this.baseUrl = `http://127.0.0.1:${port}`;
    this.ipcSecret = ipcSecret;
    this.defaultWorkspace = defaultWorkspace || '';
    this.stateDir = stateDir || defaultStateDir();
    this._lastWsHeartbeatAt = 0;
  }

  _refreshFromDiscovery() {
    const discFile = runtimeDiscoveryPath(this.stateDir);
    if (!existsSync(discFile)) return false;
    try {
      const disc = JSON.parse(readFileSync(discFile, 'utf-8'));
      if (disc?.port && disc?.ipcSecret) {
        this.baseUrl = `http://127.0.0.1:${disc.port}`;
        this.ipcSecret = disc.ipcSecret;
        return true;
      }
    } catch {}
    return false;
  }

  async registerSelfHost(workspace = this.defaultWorkspace) {
    const lsAddress = process.env.ANTIGRAVITY_LS_ADDRESS || '';
    if (!lsAddress) {
      const now = Date.now();
      if (workspace && now - this._lastWsHeartbeatAt >= 15_000) {
        this._lastWsHeartbeatAt = now;
        await this._request('POST', '/internal/hook/lifecycle', {
          hookEventName: 'WorkspaceHeartbeat',
          cwd: workspace,
          workspacePaths: [workspace],
        });
        return true;
      }
      return false;
    }
    await this._request('POST', '/internal/hook/lifecycle', {
      hookEventName: 'HostHeartbeat',
      cwd: workspace || process.cwd(),
      workspacePaths: workspace ? [workspace] : [],
      __hostContext: {
        lsAddress,
        csrfToken: process.env.ANTIGRAVITY_CSRF_TOKEN || '',
        agentApiExe: process.env.ANTIGRAVITY_AGENTAPI_EXE || '',
        projectId: process.env.ANTIGRAVITY_PROJECT_ID || '',
        appName: process.env.ANTIGRAVITY_AUTH_SUCCESS_APP || 'antigravity',
      },
    });
    return true;
  }

  async getControlStatus() {
    void this.registerSelfHost().catch(() => {});
    return this._request('GET', '/internal/status');
  }

  async rotatePin() {
    return this._request('POST', '/internal/rotate-pin', {});
  }

  async revokeDevice(deviceId) {
    return this._request('POST', '/internal/revoke-device', { deviceId });
  }

  async updateSettings(patch) {
    return this._request('POST', '/internal/settings', patch);
  }

  async decideApproval(payload) {
    return this._request('POST', '/internal/approval-decide', payload);
  }

  async saveChanges(paths) {
    return this._request('POST', '/internal/changes-action', { action: 'saveAll', paths });
  }

  async revertChanges({ paths, all = false } = {}) {
    return this._request('POST', '/internal/changes-action', { action: 'revert', paths, all });
  }

  async _request(method, path, body = undefined, _retried = false) {
    try {
      const res = await fetch(`${this.baseUrl}${path}`, {
        method,
        headers: {
          'Content-Type': 'application/json',
          'X-Bridge-Secret': this.ipcSecret,
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
      if (!res.ok) {
        if (!_retried && res.status === 403 && this._refreshFromDiscovery()) {
          return this._request(method, path, body, true);
        }
        throw new Error(`IPC ${path} failed (${res.status})`);
      }
      return res.json();
    } catch (err) {
      if (!_retried && this._refreshFromDiscovery()) {
        return this._request(method, path, body, true);
      }
      throw err;
    }
  }
}

/**
 * Starts a local `BridgeServer` on `opts.port` (default 7443), OR seamlessly attaches
 * via `BridgeIpcClient` if another surface is already running the Bridge on this PC.
 */
export async function startOrAttachBridge(opts = {}) {
  const stateDir = opts.stateDir || defaultStateDir();
  const discFile = runtimeDiscoveryPath(stateDir);

  if (existsSync(discFile)) {
    try {
      const disc = JSON.parse(readFileSync(discFile, 'utf-8'));
      if (disc?.port && disc?.ipcSecret) {
        const ipc = new BridgeIpcClient({
          port: disc.port,
          ipcSecret: disc.ipcSecret,
          defaultWorkspace: opts.defaultWorkspace,
          stateDir,
        });
        const status = await ipc.getControlStatus();
        if (status?.ok) {
          return { mode: 'attached', server: null, client: ipc, initialStatus: status };
        }
      }
    } catch {
      // Stale runtime file — proceed to start fresh server
    }
  }

  const server = new BridgeServer({
    port: opts.port ?? DEFAULT_BRIDGE_PORT,
    stateDir,
    defaultWorkspace: opts.defaultWorkspace,
    webClientDir: opts.webClientDir,
  });

  try {
    const status = await server.start();
    const ipc = new BridgeIpcClient({
      port: server.port,
      ipcSecret: server.auth.state.ipcSecret,
      defaultWorkspace: opts.defaultWorkspace,
      stateDir,
    });
    await ipc.registerSelfHost().catch(() => {});
    return { mode: 'hosted', server, client: ipc, initialStatus: status };
  } catch (err) {
    if (err && err.code === 'EADDRINUSE' && existsSync(discFile)) {
      const disc = JSON.parse(readFileSync(discFile, 'utf-8'));
      const ipc = new BridgeIpcClient({
        port: disc.port,
        ipcSecret: disc.ipcSecret,
        defaultWorkspace: opts.defaultWorkspace,
        stateDir,
      });
      const status = await ipc.getControlStatus();
      return { mode: 'attached', server: null, client: ipc, initialStatus: status };
    }
    throw err;
  }
}

