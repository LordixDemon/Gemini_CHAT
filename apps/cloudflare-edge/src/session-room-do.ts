/**
 * `SessionRoomDO` — Cloudflare Durable Object with WebSocket Hibernation API.
 *
 * Each Antigravity Desktop Machine maps to its own isolated `SessionRoomDO` instance:
 * - Holds 1 outbound WebSocket from the Desktop `BridgeServer` (`role:host`)
 * - Multiplexes N Mobile Flutter / PWA WebSockets (`role:mobile`)
 * - Caches the latest session snapshot & pending tool approvals in DO storage for <50ms mobile wakeups
 * - Manages Edge Pairing Codes (`POST /do/pair-create`, `POST /do/pair-verify`)
 */
import { mintEdgeDeviceToken, timingSafeStringEqual } from './auth';

export interface Env {
  SESSION_ROOMS: DurableObjectNamespace;
  HOST_AUTH_SECRET?: string;
  EDGE_SIGNING_SECRET?: string;
}

interface StoredPairing {
  pin: string;
  token: string;
  machineId: string;
  machineName: string;
  expiresAt: number;
}

export type WebSocketPairFactory = () => { 0: WebSocket; 1: WebSocket };

function makeUpgradeResponse(client: WebSocket): Response {
  try {
    return new Response(null, { status: 101, webSocket: client });
  } catch {
    // Fallback for Node.js standard Response constructor in unit tests outside workerd
    const res = new Response(null, { status: 200 });
    Object.defineProperty(res, 'status', { value: 101 });
    Object.defineProperty(res, 'webSocket', { value: client });
    return res;
  }
}

export class SessionRoomDO implements DurableObject {
  private readonly ctx: DurableObjectState;
  private readonly env: Env;
  private readonly createPair: WebSocketPairFactory;

  constructor(
    ctx: DurableObjectState,
    env: Env,
    createPair: WebSocketPairFactory = () => new WebSocketPair(),
  ) {
    this.ctx = ctx;
    this.env = env;
    this.createPair = createPair;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // 1. Desktop Host WebSocket connection (`/ws/host`)
    if (url.pathname === '/ws/host') {
      const machineId = url.searchParams.get('machineId') || 'default';
      const machineName = url.searchParams.get('machineName') || 'Antigravity-PC';

      for (const oldHost of this.ctx.getWebSockets('role:host')) {
        try {
          oldHost.close(1012, 'Replaced by newer host connection');
        } catch {}
      }

      const pair = this.createPair();
      const client = pair[0];
      const server = pair[1];

      this.ctx.acceptWebSocket(server, ['role:host', `machine:${machineId}`]);
      await this.ctx.storage.put('meta', {
        machineId,
        machineName,
        online: true,
        connectedAt: Date.now(),
      });

      const mobileCount = this.ctx.getWebSockets('role:mobile').length;
      server.send(
        JSON.stringify({
          v: 'arp.v1',
          type: 'edge.presence',
          ts: Date.now(),
          payload: { mobileCount },
        }),
      );

      this.broadcastToMobiles({
        v: 'arp.v1',
        type: 'edge.host_status',
        ts: Date.now(),
        payload: { online: true, machineId, machineName },
      });

      return makeUpgradeResponse(client);
    }

    // 2. Authenticated Mobile WebSocket connection (`/ws`)
    if (url.pathname === '/ws') {
      const clientId = url.searchParams.get('clientId') || crypto.randomUUID();
      const deviceName = url.searchParams.get('deviceName') || 'Mobile';

      const pair = this.createPair();
      const client = pair[0];
      const server = pair[1];

      this.ctx.acceptWebSocket(server, [
        'role:mobile',
        `client:${clientId}`,
        `name:${encodeURIComponent(deviceName)}`,
      ]);

      const cachedSnapshot = await this.ctx.storage.get<Record<string, unknown>>('snapshot');
      const meta = await this.ctx.storage.get<Record<string, unknown>>('meta');
      server.send(
        JSON.stringify({
          v: 'arp.v1',
          type: 'server.hello',
          ts: Date.now(),
          payload: {
            ...(cachedSnapshot || {}),
            hostOnline: this.ctx.getWebSockets('role:host').length > 0,
            machineName: meta?.machineName || cachedSnapshot?.machineName || 'Antigravity-PC',
          },
        }),
      );

      this.notifyHostPresence();

      return makeUpgradeResponse(client);
    }

    // 3. Register / Rotate Edge Pairing Token (`POST /do/pair-create`)
    if (request.method === 'POST' && url.pathname === '/do/pair-create') {
      const body = (await request.json()) as Partial<StoredPairing>;
      const pin = body.pin || String(Math.floor(100000 + Math.random() * 900000));
      const token = body.token || crypto.randomUUID().replace(/-/g, '');
      const pairing: StoredPairing = {
        pin,
        token,
        machineId: body.machineId || 'default',
        machineName: body.machineName || 'Antigravity-PC',
        expiresAt: Date.now() + 10 * 60 * 1000,
      };
      await this.ctx.storage.put('pairing', pairing);
      return Response.json({ ok: true, pairing });
    }

    // 4. Verify Mobile Pairing on Edge (`POST /do/pair-verify`)
    if (request.method === 'POST' && url.pathname === '/do/pair-verify') {
      const body = (await request.json()) as {
        token?: string;
        pin?: string;
        sessionId: string;
        deviceName?: string;
      };
      const stored = await this.ctx.storage.get<StoredPairing>('pairing');
      if (!stored || Date.now() > stored.expiresAt) {
        return Response.json(
          { ok: false, error: 'Pairing code expired or not initialized.' },
          { status: 401 },
        );
      }

      const cleanPin = String(body.pin || '').replace(/[\s-]/g, '');
      const validToken = Boolean(body.token && timingSafeStringEqual(body.token, stored.token));
      const validPin = Boolean(cleanPin && timingSafeStringEqual(cleanPin, stored.pin));

      if (!validToken && !validPin) {
        return Response.json({ ok: false, error: 'Invalid pairing token or PIN.' }, { status: 401 });
      }

      if (!this.env.EDGE_SIGNING_SECRET) {
        return Response.json(
          { ok: false, error: 'Server misconfigured: EDGE_SIGNING_SECRET is not set' },
          { status: 503 },
        );
      }

      const deviceId = `edev_${crypto.randomUUID().slice(0, 12)}`;
      const deviceToken = await mintEdgeDeviceToken(this.env.EDGE_SIGNING_SECRET, {
        deviceId,
        sessionId: body.sessionId,
        deviceName: body.deviceName || 'Mobile Device',
        issuedAt: Date.now(),
      });

      await this.ctx.storage.delete('pairing');

      return Response.json({
        ok: true,
        deviceId,
        deviceToken,
        sessionId: body.sessionId,
        machineId: stored.machineId,
        machineName: stored.machineName,
      });
    }

    // 5. Room Status (`GET /do/status`)
    if (request.method === 'GET' && url.pathname === '/do/status') {
      const meta = await this.ctx.storage.get<Record<string, unknown>>('meta');
      return Response.json({
        ok: true,
        hostOnline: this.ctx.getWebSockets('role:host').length > 0,
        mobileCount: this.ctx.getWebSockets('role:mobile').length,
        meta: meta || null,
      });
    }

    return Response.json({ ok: false, error: 'Unknown DO route' }, { status: 404 });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const raw = typeof message === 'string' ? message : new TextDecoder().decode(message);
    let env: { v?: string; type?: string; reqId?: string; ts?: number; payload?: Record<string, unknown> };
    try {
      env = JSON.parse(raw);
    } catch {
      return;
    }
    if (!env || typeof env.type !== 'string') return;

    const tags = this.ctx.getTags(ws);
    const isHost = tags.includes('role:host');

    if (isHost) {
      if (env.type === 'host.ping') {
        ws.send(JSON.stringify({ v: 'arp.v1', type: 'edge.pong', ts: Date.now(), payload: {} }));
        return;
      }

      if (env.type === 'host.snapshot' && env.payload) {
        await this.ctx.storage.put('snapshot', env.payload);
      }

      const targetClient = env.payload?.__targetClientId as string | undefined;
      if (targetClient) {
        delete env.payload!.__targetClientId;
        const targets = this.ctx.getWebSockets(`client:${targetClient}`);
        const serialized = JSON.stringify(env);
        for (const t of targets) {
          try {
            t.send(serialized);
          } catch {}
        }
      } else {
        this.broadcastToMobiles(env);
      }
      return;
    }

    if (env.type === 'client.ping') {
      ws.send(
        JSON.stringify({
          v: 'arp.v1',
          type: 'server.pong',
          reqId: env.reqId,
          ts: Date.now(),
          payload: { edgeRelay: true, hostOnline: this.ctx.getWebSockets('role:host').length > 0 },
        }),
      );
      return;
    }

    const hosts = this.ctx.getWebSockets('role:host');
    if (hosts.length === 0) {
      ws.send(
        JSON.stringify({
          v: 'arp.v1',
          type: 'error',
          reqId: env.reqId,
          ts: Date.now(),
          payload: { message: 'Desktop Antigravity Bridge is currently offline.' },
        }),
      );
      return;
    }

    const clientTag = tags.find((t) => t.startsWith('client:')) || 'client:unknown';
    const nameTag = tags.find((t) => t.startsWith('name:')) || 'name:Mobile';
    env.payload = {
      ...(env.payload || {}),
      __edgeClientId: clientTag.slice('client:'.length),
      __deviceName: decodeURIComponent(nameTag.slice('name:'.length)),
    };

    const serialized = JSON.stringify(env);
    for (const h of hosts) {
      try {
        h.send(serialized);
      } catch {}
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const tags = this.ctx.getTags(ws);
    if (tags.includes('role:host')) {
      this.broadcastToMobiles({
        v: 'arp.v1',
        type: 'edge.host_status',
        ts: Date.now(),
        payload: { online: false },
      });
    } else {
      this.notifyHostPresence();
    }
  }

  private notifyHostPresence(): void {
    const mobileCount = this.ctx.getWebSockets('role:mobile').length;
    const msg = JSON.stringify({
      v: 'arp.v1',
      type: 'edge.presence',
      ts: Date.now(),
      payload: { mobileCount },
    });
    for (const h of this.ctx.getWebSockets('role:host')) {
      try {
        h.send(msg);
      } catch {}
    }
  }

  private broadcastToMobiles(obj: unknown): void {
    const raw = JSON.stringify(obj);
    for (const m of this.ctx.getWebSockets('role:mobile')) {
      try {
        m.send(raw);
      } catch {}
    }
  }
}
