/**
 * Cloudflare Worker Entrypoint for Antigravity Remote Edge (`@agy-remote/cloudflare-edge`).
 * Routes Desktop Bridges & Mobile Flutter / Web Clients into isolated `SessionRoomDO` instances.
 */
import { timingSafeStringEqual, verifyEdgeDeviceToken } from './auth';
import { Env, SessionRoomDO } from './session-room-do';

export { SessionRoomDO };

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Host-Secret',
};

function withCors(res: Response): Response {
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(CORS_HEADERS)) headers.set(k, v);
  const init: ResponseInit & { webSocket?: WebSocket | null } = {
    status: res.status,
    headers,
  };
  if (res.webSocket) init.webSocket = res.webSocket;
  return new Response(res.body, init);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    // 1. Edge Health Check
    if (request.method === 'GET' && url.pathname === '/api/ping') {
      return withCors(
        Response.json({
          ok: true,
          service: 'antigravity-remote-cloudflare-edge',
          protocol: 'arp.v1',
          ts: Date.now(),
        }),
      );
    }

    // 2. Desktop Host registers an Edge Pairing Code (`POST /api/edge/pair-create`)
    if (request.method === 'POST' && url.pathname === '/api/edge/pair-create') {
      if (!env.HOST_AUTH_SECRET) {
        return withCors(
          Response.json({ ok: false, error: 'Server misconfigured: HOST_AUTH_SECRET is not set' }, { status: 503 }),
        );
      }
      const providedSecret = request.headers.get('x-host-secret') || '';
      if (!timingSafeStringEqual(providedSecret, env.HOST_AUTH_SECRET)) {
        return withCors(
          Response.json({ ok: false, error: 'Unauthorized host secret' }, { status: 403 }),
        );
      }
      const body = (await request.json()) as {
        machineId?: string;
        machineName?: string;
        pin?: string;
        token?: string;
      };
      const sessionId = body.machineId || 'default';
      const stub = env.SESSION_ROOMS.get(env.SESSION_ROOMS.idFromName(sessionId));
      const doRes = await stub.fetch('https://do.internal/do/pair-create', {
        method: 'POST',
        body: JSON.stringify(body),
      });
      return withCors(doRes);
    }

    // 3. Mobile Client Exchanges QR Token / PIN for Edge Device Token (`POST /api/pair`)
    if (request.method === 'POST' && url.pathname === '/api/pair') {
      const body = (await request.json()) as {
        sessionId?: string;
        machineId?: string;
        token?: string;
        pin?: string;
        deviceName?: string;
      };
      const sessionId = body.sessionId || body.machineId || url.searchParams.get('s') || '';
      if (!sessionId) {
        return withCors(
          Response.json({ ok: false, error: 'sessionId is required on Edge' }, { status: 400 }),
        );
      }
      const stub = env.SESSION_ROOMS.get(env.SESSION_ROOMS.idFromName(sessionId));
      const doRes = await stub.fetch('https://do.internal/do/pair-verify', {
        method: 'POST',
        body: JSON.stringify({ ...body, sessionId }),
      });
      return withCors(doRes);
    }

    // 4. Desktop Host Outbound WebSocket (`/ws/host?machineId=...`)
    if (url.pathname === '/ws/host') {
      if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
        return withCors(
          Response.json({ ok: false, error: 'Expected WebSocket upgrade' }, { status: 426 }),
        );
      }
      if (!env.HOST_AUTH_SECRET) {
        return withCors(
          Response.json({ ok: false, error: 'Server misconfigured: HOST_AUTH_SECRET is not set' }, { status: 503 }),
        );
      }
      const secret = url.searchParams.get('secret') || request.headers.get('x-host-secret') || '';
      if (!timingSafeStringEqual(secret, env.HOST_AUTH_SECRET)) {
        return withCors(Response.json({ ok: false, error: 'Invalid host secret' }, { status: 403 }));
      }
      const machineId = url.searchParams.get('machineId') || 'default';
      const stub = env.SESSION_ROOMS.get(env.SESSION_ROOMS.idFromName(machineId));
      return stub.fetch(request);
    }

    // 5. Mobile Client WebSocket (`/ws?token=...&sessionId=...`)
    if (url.pathname === '/ws' || url.pathname.startsWith('/ws/session/')) {
      if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
        return withCors(
          Response.json({ ok: false, error: 'Expected WebSocket upgrade' }, { status: 426 }),
        );
      }
      if (!env.EDGE_SIGNING_SECRET) {
        return withCors(
          Response.json({ ok: false, error: 'Server misconfigured: EDGE_SIGNING_SECRET is not set' }, { status: 503 }),
        );
      }
      const rawToken =
        url.searchParams.get('token') ||
        (request.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');

      const claims = await verifyEdgeDeviceToken(env.EDGE_SIGNING_SECRET, rawToken);
      if (!claims) {
        return withCors(
          Response.json({ ok: false, error: 'Unauthorized edge device token' }, { status: 401 }),
        );
      }

      const stub = env.SESSION_ROOMS.get(env.SESSION_ROOMS.idFromName(claims.sessionId));
      const doUrl = new URL('https://do.internal/ws');
      doUrl.searchParams.set('clientId', claims.deviceId);
      doUrl.searchParams.set('deviceName', claims.deviceName);
      return stub.fetch(new Request(doUrl.toString(), request));
    }

    // 6. Session Status Inspection (`GET /api/session/:id`)
    if (request.method === 'GET' && url.pathname.startsWith('/api/session/')) {
      const sessionId = url.pathname.split('/').pop() || '';
      const stub = env.SESSION_ROOMS.get(env.SESSION_ROOMS.idFromName(sessionId));
      const doRes = await stub.fetch('https://do.internal/do/status');
      return withCors(doRes);
    }

    return withCors(Response.json({ ok: false, error: 'Not found' }, { status: 404 }));
  },
};
