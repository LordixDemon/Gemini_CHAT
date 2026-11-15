/**
 * Main Unified Bridge Server (`BridgeServer`):
 * - Serves LAN HTTP REST + RFC 6455 WebSocket (`/ws`)
 * - Serves embedded Mobile Web PWA (`/`, `/pair`, `/app`, `/client/*`)
 * - Serves local IPC endpoints (`/internal/*`, guarded by `X-Bridge-Secret`) for:
 *   - `PreToolUse` hook (`hooks/gatekeeper.mjs`)
 *   - Antigravity Sidecar UI Panel & VS Code Extension Control Panel
 * - Bridges bi-directionally with `CloudflareConnector` (`SessionRoomDO` or `cloudflared`)
 */
import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  APPROVAL_MODES,
  DEFAULT_BRIDGE_PORT,
  buildPairingUrl,
  createEnvelope,
  parseEnvelope,
} from '@agy-remote/protocol';
import { renderQrSvg, renderQrTerminal } from '@agy-remote/protocol/qr';
import { AgentDriver } from './agent-driver.mjs';
import { ApprovalGate } from './approval-gate.mjs';
import { AuthManager, discoverLanAddresses } from './auth-manager.mjs';
import { BrainWatcher } from './brain-watcher.mjs';
import { ChangeTracker } from './change-tracker.mjs';
import { CloudflareConnector } from './cloudflare-connector.mjs';
import {
  applyCorsHeaders,
  extractBearerToken,
  readJsonBody,
  sendJson,
  serveStaticAsset,
} from './http-helpers.mjs';
import { upgradeToWebSocket } from './rfc6455-ws.mjs';
import { dispatchClientRpc } from './rpc-router.mjs';
import { LanDiscoveryBeacon } from './lan-discovery-beacon.mjs';

const _currentDir =
  typeof import.meta?.url === 'string' && import.meta.url.startsWith('file:')
    ? dirname(fileURLToPath(import.meta.url))
    : process.cwd();

const STATIC_PWA_ROUTES = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app', ['index.html', 'text/html; charset=utf-8']],
  ['/pair', ['index.html', 'text/html; charset=utf-8']],
  ['/manifest.json', ['manifest.json', 'application/manifest+json; charset=utf-8']],
  ['/client/styles.css', ['styles.css', 'text/css; charset=utf-8']],
  ['/client/app.js', ['app.js', 'application/javascript; charset=utf-8']],
]);

function resolveWebClientDir(customDir) {
  const candidates = [
    customDir,
    join(_currentDir, 'web-client'),
    join(_currentDir, '..', 'src', 'web-client'),
  ].filter(Boolean);
  for (const dir of candidates) {
    if (existsSync(join(dir, 'index.html'))) return dir;
  }
  return join(_currentDir, 'web-client');
}

export class BridgeServer extends EventEmitter {
  /**
   * @param {{
   *   port?: number,
   *   host?: string,
   *   stateDir?: string,
   *   brainRoots?: string[],
   *   defaultWorkspace?: string,
   *   webClientDir?: string,
   *   approvalTimeoutMs?: number
   * }} [opts]
   */
  constructor(opts = {}) {
    super();
    this.requestedPort = opts.port ?? DEFAULT_BRIDGE_PORT;
    this.host = opts.host || '0.0.0.0';
    this.port = this.requestedPort;
    this.webClientDir = resolveWebClientDir(opts.webClientDir);

    this.auth = new AuthManager({ stateDir: opts.stateDir });
    this.brain = new BrainWatcher({ brainRoots: opts.brainRoots });
    this._acpScanTimer = null;
    this.driver = new AgentDriver({
      defaultWorkspace: opts.defaultWorkspace,
      agentApiPath: opts.agentApiPath,
      agyPath: opts.agyPath,
      geminiDir: opts.geminiDir,
      acpIdleTimeoutMs: opts.acpIdleTimeoutMs,
      stateDir: this.auth.stateDir,
      isSessionStopped: (sid) => Boolean(this.approvals?._isConversationStopped(sid)),
      onTurnActivity: () => {
        if (this._acpScanTimer) return;
        this._acpScanTimer = setTimeout(() => {
          this._acpScanTimer = null;
          this.brain.scanNow(true);
        }, 200);
        this._acpScanTimer.unref?.();
      },
    });
    this.changes = new ChangeTracker();
    this.cloudflare = new CloudflareConnector();

    this.driver.onQueueFlushed = ({ conversationId, result }) => {
      this.broadcast(
        createEnvelope('chat.send.result', {
          conversationId,
          ...result,
          flushedFromQueue: true,
        }),
      );
      const scanTimer = setTimeout(() => this.brain.scanNow(true), 400);
      scanTimer.unref?.();
    };

    this.lanPeers = new Set(); // Set<WsPeer>
    this.lastTaskCompletedAt = 0;
    this.lastStopRequestedAt = 0;
    this._prevSessionStatus = new Map();

    const enableDiscovery =
      opts.discoveryPort !== undefined ? opts.discoveryPort !== false : this.requestedPort !== 0;
    this.beacon = enableDiscovery
      ? new LanDiscoveryBeacon({
          udpPort: typeof opts.discoveryPort === 'number' ? opts.discoveryPort : undefined,
          enableMdns: opts.enableMdns ?? (this.requestedPort !== 0 && process.platform === 'darwin'),
          getInfo: () => ({
            machineId: this.auth.state.machineId,
            machineName: this.auth.state.machineName,
            port: this.port,
            lanIp: this.getPrimaryLanIp(),
          }),
        })
      : null;

    this.approvals = new ApprovalGate({
      getMode: () => this.auth.getSettings().approvalMode || 'ask-mobile',
      hasActiveMobileClients: () =>
        this.lanPeers.size > 0 || this.cloudflare.hasConnectedEdgeMobiles(),
      defaultTimeoutMs: opts.approvalTimeoutMs || 50_000,
      changeTracker: this.changes,
      getDefaultWorkspace: () => this.driver.defaultWorkspace,
    });

    this.httpServer = null;
    this._wireEvents();
  }

  _rpcServices() {
    return {
      brain: this.brain,
      driver: this.driver,
      approvals: this.approvals,
      changes: this.changes,
      auth: this.auth,
      broadcast: (envelope) => this.broadcast(envelope),
      onStatusChanged: () => this.emit('status_changed', this.getControlStatus()),
      onStopRequested: () => {
        this.lastStopRequestedAt = Date.now();
        this.emit('status_changed', this.getControlStatus());
      },
    };
  }

  _completeTaskAndSaveAll() {
    this.lastTaskCompletedAt = Date.now();
    this.changes.saveChanges();
    this.emit('status_changed', this.getControlStatus());
  }

  _wireEvents() {
    this.brain.on('sessions_updated', (sessions) => {
      let anyFinished = false;
      for (const s of sessions) {
        const prev = this._prevSessionStatus.get(s.id);
        this._prevSessionStatus.set(s.id, s.status);
        if (prev === 'working' && s.status === 'idle') {
          anyFinished = true;
        }
      }
      if (anyFinished) {
        this._completeTaskAndSaveAll();
      }
      this.broadcast(createEnvelope('sessions.updated', { sessions }));
    });

    this.brain.on('steps_delta', (delta) => {
      this.broadcast(createEnvelope('session.steps_delta', delta));
    });

    this.approvals.on('approval_requested', (item) => {
      this.broadcast(createEnvelope('approval.requested', item));
      this.emit('status_changed', this.getControlStatus());
    });

    this.approvals.on('approval_resolved', (res) => {
      this.broadcast(createEnvelope('approval.resolved', res));
      this.emit('status_changed', this.getControlStatus());
    });

    this.changes.on('changes_updated', (files) => {
      this.broadcast(createEnvelope('changes.updated', { files }));
      this.emit('status_changed', this.getControlStatus());
    });

    this.cloudflare.on('state_changed', () => {
      this.emit('status_changed', this.getControlStatus());
    });

    this.cloudflare.on('edge_message', (env) => {
      void dispatchClientRpc(
        env,
        {
          deviceName: env.payload?.__deviceName || 'Cloudflare Mobile',
          reply: (respEnv) => {
            if (env.payload?.__edgeClientId) {
              respEnv.payload.__targetClientId = env.payload.__edgeClientId;
            }
            this.cloudflare.sendToEdge(respEnv);
          },
        },
        this._rpcServices(),
      );
    });
  }

  async start() {
    if (this.httpServer) return this.getControlStatus();

    this.brain.start();

    this.httpServer = createServer((req, res) => {
      this._handleHttp(req, res).catch((err) => {
        const status = err?.message === 'Payload too large' ? 413 : 400;
        sendJson(res, status, { ok: false, error: err.message });
      });
    });

    this.httpServer.on('upgrade', (req, socket, head) => {
      this._handleUpgrade(req, socket, head);
    });

    await new Promise((resolve, reject) => {
      this.httpServer.once('error', reject);
      this.httpServer.listen(this.requestedPort, this.host, () => {
        const addr = this.httpServer.address();
        this.port = typeof addr === 'object' && addr ? addr.port : this.requestedPort;
        resolve();
      });
    });

    this.auth.writeRuntimeDiscovery(this.port);
    if (this.beacon) {
      await this.beacon.start();
    }

    const settings = this.auth.getSettings();
    if (settings.cloudflareMode && settings.cloudflareMode !== 'disabled') {
      this._applyCloudflareConfig(settings);
    }

    return this.getControlStatus();
  }

  async stop() {
    if (this._acpScanTimer) {
      clearTimeout(this._acpScanTimer);
      this._acpScanTimer = null;
    }
    if (this.beacon) {
      this.beacon.stop();
    }
    await this.driver.shutdown();
    this.brain.stop();
    this.changes.clearTimers();
    this.cloudflare.stop();
    for (const peer of this.lanPeers) {
      peer.close(1001, 'Server shutting down');
    }
    this.lanPeers.clear();
    this.auth.clearRuntimeDiscovery();

    if (this.httpServer) {
      const srv = this.httpServer;
      this.httpServer = null;
      srv.closeAllConnections?.();
      await new Promise((resolve) => srv.close(() => resolve()));
    }
  }

  broadcast(envelope) {
    const raw = JSON.stringify(envelope);
    for (const peer of this.lanPeers) {
      peer.sendText(raw);
    }
    this.cloudflare.sendToEdge(envelope);
  }

  getPrimaryLanIp() {
    const settings = this.auth.getSettings();
    const candidates = discoverLanAddresses();
    if (settings.preferredLanIp && candidates.some((c) => c.address === settings.preferredLanIp)) {
      return settings.preferredLanIp;
    }
    return candidates[0]?.address || '127.0.0.1';
  }

  getControlStatus() {
    const pairing = this.auth.getPairingInfo();
    const settings = this.auth.getSettings();
    const lanInterfaces = discoverLanAddresses();
    const lanIp = this.getPrimaryLanIp();
    const lanBaseUrl = `http://${lanIp}:${this.port}`;
    const cfState = this.cloudflare.getState();

    const activeBaseUrl =
      cfState.status === 'connected' && cfState.publicPairBaseUrl
        ? cfState.publicPairBaseUrl
        : lanBaseUrl;

    const pairingUrl = buildPairingUrl({
      baseUrl: activeBaseUrl,
      token: pairing.token,
      pin: pairing.pin,
      machineId: pairing.machineId,
      machineName: pairing.machineName,
      cloudflareUrl: cfState.edgeUrl || settings.cloudflareEdgeUrl || '',
      sessionId: pairing.machineId,
    });

    const connectedLanDevices = [...this.lanPeers].map((p) => ({
      id: p.meta.device.id,
      name: p.meta.device.name,
      platform: p.meta.device.platform,
      transport: 'lan',
      remoteAddress: p.meta.remoteAddress,
    }));

    return {
      ok: true,
      port: this.port,
      machineId: pairing.machineId,
      machineName: pairing.machineName,
      lanIp,
      lanBaseUrl,
      lanInterfaces,
      pairing: {
        pin: pairing.pin,
        formattedPin: `${pairing.pin.slice(0, 3)} ${pairing.pin.slice(3)}`,
        expiresAt: pairing.expiresAt,
        pairingUrl,
        qrSvg: renderQrSvg(pairingUrl, { sizePx: 220, margin: 4 }),
        qrTerminal: renderQrTerminal(pairingUrl),
      },
      settings,
      cloudflare: cfState,
      connectedClients: {
        lanCount: connectedLanDevices.length,
        edgeCount: cfState.edgeMobileCount,
        total: connectedLanDevices.length + cfState.edgeMobileCount,
        lanDevices: connectedLanDevices,
      },
      pairedDevices: this.auth.listDevices(),
      pendingApprovals: this.approvals.listPending(),
      pendingChanges: this.changes.listPending(),
      registeredHosts: this.driver.getRegisteredHostsSummary(),
      lastTaskCompletedAt: this.lastTaskCompletedAt,
      lastStopRequestedAt: this.lastStopRequestedAt,
      recentApprovals: this.approvals.listHistory(10),
      sessions: this.brain.listSessions(20),
    };
  }

  getSnapshotPayload() {
    const sessions = this.brain.listSessions(40);
    return {
      machineId: this.auth.state.machineId,
      machineName: this.auth.state.machineName,
      approvalMode: this.auth.getSettings().approvalMode || 'ask-mobile',
      sessions,
      workspaces: this.driver.listWorkspaces(sessions),
      activeWorkspace: this.driver.defaultWorkspace,
      pendingApprovals: this.approvals.listPending(),
      pendingChanges: this.changes.listPending(),
    };
  }

  _applyCloudflareConfig(settings) {
    this.cloudflare.configure({
      mode: settings.cloudflareMode || 'disabled',
      edgeUrl: settings.cloudflareEdgeUrl || '',
      edgeSecret: settings.cloudflareEdgeSecret || '',
      machineId: this.auth.state.machineId,
      machineName: this.auth.state.machineName,
      localPort: this.port,
      getInitialSnapshot: () => this.getSnapshotPayload(),
      getPairing: () => this.auth.getPairingInfo(),
    });
  }

  async _handleHttp(req, res) {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    applyCorsHeaders(res);
    if (req.method === 'OPTIONS') {
      res.writeHead(204).end();
      return;
    }

    if (req.method === 'GET' && pathname === '/api/ping') {
      return sendJson(res, 200, {
        ok: true,
        protocol: 'arp.v1',
        machineId: this.auth.state.machineId,
        machineName: this.auth.state.machineName,
        ts: Date.now(),
      });
    }

    if (req.method === 'POST' && pathname === '/api/pair') {
      const body = await readJsonBody(req);
      const result = this.auth.pairDevice({
        token: body.token,
        pin: body.pin,
        deviceName: body.deviceName,
        platform: body.platform,
      });
      if (!result.ok) {
        return sendJson(res, 401, result);
      }
      this.emit('status_changed', this.getControlStatus());
      return sendJson(res, 200, {
        ...result,
        port: this.port,
        lanIp: this.getPrimaryLanIp(),
        cloudflareUrl: this.auth.getSettings().cloudflareEdgeUrl || '',
      });
    }

    if (pathname.startsWith('/api/mobile/')) {
      return this._routeMobileRest(req, res, url, pathname);
    }

    if (pathname.startsWith('/internal/')) {
      return this._routeInternalIpc(req, res, url, pathname);
    }

    if (req.method === 'GET' && STATIC_PWA_ROUTES.has(pathname)) {
      const [fileName, contentType] = STATIC_PWA_ROUTES.get(pathname);
      return serveStaticAsset(res, this.webClientDir, fileName, contentType);
    }

    return sendJson(res, 404, { ok: false, error: 'Not found' });
  }

  async _routeMobileRest(req, res, url, pathname) {
    const token = extractBearerToken(req, url);
    const device = this.auth.verifyDeviceToken(token);
    if (!device) return sendJson(res, 401, { ok: false, error: 'Unauthorized device token' });

    if (req.method === 'GET' && pathname === '/api/mobile/snapshot') {
      return sendJson(res, 200, { ok: true, ...this.getSnapshotPayload() });
    }
    if (req.method === 'POST' && pathname === '/api/mobile/upload') {
      const body = await readJsonBody(req, 28 * 1024 * 1024);
      const uploaded = this.driver.saveUploadedFile({
        fileName: body.fileName,
        base64Data: body.base64Data,
        workspacePath: body.workspace,
      });
      return sendJson(res, 200, uploaded);
    }
    return sendJson(res, 404, { ok: false, error: 'Not found' });
  }

  async _routeInternalIpc(req, res, url, pathname) {
    const secret = req.headers['x-bridge-secret'] || url.searchParams.get('secret') || '';
    if (!this.auth.verifyIpcSecret(String(secret))) {
      return sendJson(res, 403, { ok: false, error: 'Invalid X-Bridge-Secret' });
    }

    if (req.method === 'GET' && pathname === '/internal/status') {
      return sendJson(res, 200, this.getControlStatus());
    }

    if (req.method === 'POST' && pathname === '/internal/rotate-pin') {
      const pInfo = this.auth.rotatePairing();
      void this.cloudflare.syncEdgePairing(pInfo, this.auth.getSettings().cloudflareEdgeSecret);
      const st = this.getControlStatus();
      this.emit('status_changed', st);
      return sendJson(res, 200, st);
    }

    if (req.method === 'POST' && pathname === '/internal/revoke-device') {
      const body = await readJsonBody(req);
      this.auth.revokeDevice(body.deviceId);
      for (const peer of this.lanPeers) {
        if (peer.meta.device.id === body.deviceId) {
          peer.close(4001, 'Device revoked');
        }
      }
      const st = this.getControlStatus();
      this.emit('status_changed', st);
      return sendJson(res, 200, st);
    }

    if (req.method === 'POST' && pathname === '/internal/settings') {
      const body = await readJsonBody(req);
      const patch = {};
      if (body.approvalMode && APPROVAL_MODES.includes(body.approvalMode)) {
        patch.approvalMode = body.approvalMode;
      }
      if (typeof body.preferredLanIp === 'string') patch.preferredLanIp = body.preferredLanIp;
      if (typeof body.cloudflareMode === 'string') patch.cloudflareMode = body.cloudflareMode;
      if (typeof body.cloudflareEdgeUrl === 'string') {
        patch.cloudflareEdgeUrl = body.cloudflareEdgeUrl.trim();
      }
      if (typeof body.cloudflareEdgeSecret === 'string') {
        patch.cloudflareEdgeSecret = body.cloudflareEdgeSecret;
      }

      const nextSettings = this.auth.updateSettings(patch);
      if ('cloudflareMode' in patch || 'cloudflareEdgeUrl' in patch || 'cloudflareEdgeSecret' in patch) {
        this._applyCloudflareConfig(nextSettings);
      }
      this.broadcast(createEnvelope('settings.updated', nextSettings));
      const st = this.getControlStatus();
      this.emit('status_changed', st);
      return sendJson(res, 200, st);
    }

    if (req.method === 'POST' && pathname === '/internal/approval-decide') {
      const body = await readJsonBody(req);
      if (body.all === true || Array.isArray(body.ids)) {
        const result = this.approvals.decideBatch({
          ids: body.ids,
          decision: body.decision,
          reason: body.reason,
          byDevice: 'Desktop IDE',
        });
        return sendJson(res, 200, result);
      }
      const result = this.approvals.decide({
        id: body.id,
        decision: body.decision,
        reason: body.reason,
        byDevice: 'Desktop IDE',
      });
      return sendJson(res, 200, result);
    }

    if (req.method === 'POST' && pathname === '/internal/changes-action') {
      const body = await readJsonBody(req);
      if (body.action === 'revert') {
        this.changes.revertChanges({ paths: body.paths, all: Boolean(body.all) });
      } else {
        this.changes.saveChanges({ paths: body.paths });
      }
      return sendJson(res, 200, this.getControlStatus());
    }

    if (req.method === 'POST' && pathname === '/internal/hook/pre-tool') {
      const hookPayload = await readJsonBody(req);
      this.driver.registerHookContext(hookPayload);
      const decisionObj = await this.approvals.evaluateHook(hookPayload);
      return sendJson(res, 200, decisionObj);
    }

    if (req.method === 'POST' && pathname === '/internal/hook/post-tool') {
      const hookPayload = await readJsonBody(req);
      this.driver.registerHookContext(hookPayload);
      const recorded = this.changes.recordAfterWrite(
        hookPayload,
        this.driver.defaultWorkspace,
      );
      return sendJson(res, 200, { ok: true, recorded });
    }

    if (req.method === 'POST' && pathname === '/internal/hook/lifecycle') {
      const hookPayload = await readJsonBody(req);
      const isStop = hookPayload?.hookEventName === 'Stop';
      const isWorkspaceHeartbeat = hookPayload?.hookEventName === 'WorkspaceHeartbeat';
      if (isStop) {
        this._completeTaskAndSaveAll();
      }
      if (
        hookPayload?.hookEventName === 'PreInvocation' &&
        typeof hookPayload.conversationId === 'string' &&
        hookPayload.conversationId
      ) {
        this.approvals.clearStop(hookPayload.conversationId);
        this.brain.clearSessionStopped(hookPayload.conversationId);
        const queued = this.driver.consumeQueuedMessages(hookPayload.conversationId);
        this.driver.registerHookContext(hookPayload);
        if (queued.length > 0) {
          return sendJson(res, 200, {
            injectSteps: queued.map((item) => ({ userMessage: item.prompt })),
          });
        }
      } else {
        this.driver.registerHookContext(hookPayload);
      }
      if (!isWorkspaceHeartbeat) {
        const scanTimer = setTimeout(() => this.brain.scanNow(true), 250);
        scanTimer.unref?.();
      }
      return sendJson(res, 200, isStop ? { decision: 'allow' } : {});
    }

    return sendJson(res, 404, { ok: false, error: 'Unknown internal route' });
  }

  _handleUpgrade(req, socket, head) {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (url.pathname !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }

    const token = extractBearerToken(req, url);
    const device = this.auth.verifyDeviceToken(token);
    if (!device) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      socket.destroy();
      return;
    }

    const peer = upgradeToWebSocket(req, socket, head, {
      device,
      remoteAddress: req.socket.remoteAddress || '',
    });
    if (!peer) return;

    this.lanPeers.add(peer);
    this.emit('status_changed', this.getControlStatus());

    peer.sendJson(createEnvelope('server.hello', this.getSnapshotPayload()));

    peer.on('message', (rawText) => {
      const env = parseEnvelope(rawText);
      if (!env) return;
      void dispatchClientRpc(
        env,
        {
          deviceName: device.name,
          reply: (respEnv) => peer.sendJson(respEnv),
        },
        this._rpcServices(),
      );
    });

    peer.on('close', () => {
      this.lanPeers.delete(peer);
      this.emit('status_changed', this.getControlStatus());
    });
  }
}
