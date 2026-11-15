import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';

async function importTypeScriptModule(entryPoint) {
  const result = await build({
    entryPoints: [entryPoint],
    bundle: true,
    format: 'esm',
    platform: 'neutral',
    target: 'es2022',
    write: false,
  });
  const code = result.outputFiles[0].text;
  const b64 = Buffer.from(code, 'utf-8').toString('base64');
  return import(`data:text/javascript;base64,${b64}`);
}

class FakeEdgeSocket {
  constructor(label) {
    this.label = label;
    this.sent = [];
    this.closed = null;
  }
  send(data) {
    this.sent.push(typeof data === 'string' ? JSON.parse(data) : data);
  }
  close(code = 1000, reason = '') {
    this.closed = { code, reason };
  }
}

function createFakePairFactory() {
  const createdPairs = [];
  const factory = () => {
    const client = new FakeEdgeSocket('client');
    const server = new FakeEdgeSocket('server');
    createdPairs.push({ client, server });
    return { 0: client, 1: server };
  };
  return { factory, createdPairs };
}

class MockDurableObjectState {
  constructor() {
    this._map = new Map();
    this._sockets = []; // Array<{ ws, tags }>
    this.storage = {
      get: async (key) => this._map.get(key),
      put: async (key, val) => {
        this._map.set(key, structuredClone(val));
      },
      delete: async (key) => this._map.delete(key),
    };
  }

  acceptWebSocket(ws, tags = []) {
    this._sockets.push({ ws, tags });
  }

  getWebSockets(tag) {
    if (!tag) return this._sockets.map((s) => s.ws);
    return this._sockets.filter((s) => s.tags.includes(tag)).map((s) => s.ws);
  }

  getTags(ws) {
    return this._sockets.find((s) => s.ws === ws)?.tags || [];
  }

  removeSocket(ws) {
    this._sockets = this._sockets.filter((s) => s.ws !== ws);
  }
}

test('Cloudflare Edge WebCrypto auth signs and verifies Unicode claims in constant time', async () => {
  const auth = await importTypeScriptModule('apps/cloudflare-edge/src/auth.ts');

  const rawBytes = new TextEncoder().encode('Привет, Antigravity Edge! 🚀');
  const b64 = auth.encodeBase64Url(rawBytes);
  assert.equal(b64.includes('+'), false);
  assert.equal(b64.includes('/'), false);
  assert.equal(b64.includes('='), false);
  assert.deepEqual(auth.decodeBase64Url(b64), rawBytes);
  assert.equal(auth.decodeBase64Url('%%%invalid%%%'), null);

  assert.equal(auth.timingSafeStringEqual('secret-123', 'secret-123'), true);
  assert.equal(auth.timingSafeStringEqual('secret-123', 'secret-124'), false);
  assert.equal(auth.timingSafeStringEqual('short', 'longer'), false);
  assert.equal(auth.timingSafeStringEqual('', ''), false);

  const token = await auth.mintEdgeDeviceToken('top-secret-hmac', {
    deviceId: 'edev_01',
    sessionId: 'mach_77',
    deviceName: 'Смартфон Android',
    issuedAt: 1700000000000,
  });
  assert.ok(token.startsWith('edge.'));

  const verified = await auth.verifyEdgeDeviceToken('top-secret-hmac', token);
  assert.equal(verified.deviceId, 'edev_01');
  assert.equal(verified.sessionId, 'mach_77');
  assert.equal(verified.deviceName, 'Смартфон Android');

  // Reject wrong secret, tampered payload, tampered sig, and malformed tokens
  assert.equal(await auth.verifyEdgeDeviceToken('wrong-secret', token), null);
  const parts = token.split('.');
  assert.equal(await auth.verifyEdgeDeviceToken('top-secret-hmac', `${parts[0]}.${parts[1]}x.${parts[2]}`), null);
  assert.equal(await auth.verifyEdgeDeviceToken('top-secret-hmac', `bad.${parts[1]}.${parts[2]}`), null);
  assert.equal(await auth.verifyEdgeDeviceToken('top-secret-hmac', 'edge.only-two'), null);
});

test('Cloudflare Worker + SessionRoomDO multiplex host and mobile WebSockets end-to-end', async () => {
  const edgeMod = await importTypeScriptModule('apps/cloudflare-edge/src/index.ts');
  const worker = edgeMod.default;
  const { SessionRoomDO } = edgeMod;

  const rooms = new Map();
  const getRoom = (name) => {
    if (!rooms.has(name)) {
      const state = new MockDurableObjectState();
      const { factory, createdPairs } = createFakePairFactory();
      const instance = new SessionRoomDO(state, env, factory);
      rooms.set(name, { state, instance, createdPairs });
    }
    return rooms.get(name);
  };

  const env = {
    HOST_AUTH_SECRET: 'host_sec_99',
    EDGE_SIGNING_SECRET: 'edge_sig_99',
    SESSION_ROOMS: {
      idFromName: (name) => name,
      get: (id) => ({
        fetch: (input, init) => {
          const req = input instanceof Request ? input : new Request(input, init);
          return getRoom(id).instance.fetch(req);
        },
      }),
    },
  };

  // 1. OPTIONS preflight & /api/ping
  const optRes = await worker.fetch(new Request('https://edge.test/api/ping', { method: 'OPTIONS' }), env);
  assert.equal(optRes.status, 204);

  const pingRes = await worker.fetch(new Request('https://edge.test/api/ping'), env);
  assert.equal(pingRes.status, 200);
  assert.equal((await pingRes.json()).protocol, 'arp.v1');

  // 2. Host pair-create (403 without secret, 200 with secret)
  const unauthCreate = await worker.fetch(
    new Request('https://edge.test/api/edge/pair-create', {
      method: 'POST',
      body: JSON.stringify({ machineId: 'mach_edge', pin: '654321', token: 'qtok_1' }),
    }),
    env,
  );
  assert.equal(unauthCreate.status, 403);

  const okCreate = await worker.fetch(
    new Request('https://edge.test/api/edge/pair-create', {
      method: 'POST',
      headers: { 'X-Host-Secret': 'host_sec_99' },
      body: JSON.stringify({
        machineId: 'mach_edge',
        machineName: 'Studio-Mac',
        pin: '654321',
        token: 'qtok_1',
      }),
    }),
    env,
  );
  assert.equal(okCreate.status, 200);

  // 3. Mobile /api/pair validation, success, and anti-replay
  const missingSess = await worker.fetch(
    new Request('https://edge.test/api/pair', { method: 'POST', body: JSON.stringify({ pin: '654321' }) }),
    env,
  );
  assert.equal(missingSess.status, 400);

  const wrongPin = await worker.fetch(
    new Request('https://edge.test/api/pair', {
      method: 'POST',
      body: JSON.stringify({ sessionId: 'mach_edge', pin: '000000' }),
    }),
    env,
  );
  assert.equal(wrongPin.status, 401);

  const pairOk = await worker.fetch(
    new Request('https://edge.test/api/pair', {
      method: 'POST',
      body: JSON.stringify({ sessionId: 'mach_edge', pin: '654-321', deviceName: 'Phone-A' }),
    }),
    env,
  );
  assert.equal(pairOk.status, 200);
  const pairBody = await pairOk.json();
  assert.ok(pairBody.deviceToken.startsWith('edge.'));

  // Replay fails because pairing was consumed
  const replayRes = await worker.fetch(
    new Request('https://edge.test/api/pair', {
      method: 'POST',
      body: JSON.stringify({ sessionId: 'mach_edge', pin: '654321' }),
    }),
    env,
  );
  assert.equal(replayRes.status, 401);

  // Mint a second mobile token for multi-client unicast vs broadcast verification
  await worker.fetch(
    new Request('https://edge.test/api/edge/pair-create', {
      method: 'POST',
      headers: { 'X-Host-Secret': 'host_sec_99' },
      body: JSON.stringify({ machineId: 'mach_edge', pin: '111222', token: 'qtok_2' }),
    }),
    env,
  );
  const pairB = await (
    await worker.fetch(
      new Request('https://edge.test/api/pair', {
        method: 'POST',
        body: JSON.stringify({ sessionId: 'mach_edge', token: 'qtok_2', deviceName: 'Phone-B' }),
      }),
      env,
    )
  ).json();

  // 4. WebSocket upgrades & guard checks (426 / 403 / 401 / 101)
  assert.equal((await worker.fetch(new Request('https://edge.test/ws/host'), env)).status, 426);
  assert.equal(
    (
      await worker.fetch(
        new Request('https://edge.test/ws/host?machineId=mach_edge&secret=bad', {
          headers: { Upgrade: 'websocket' },
        }),
        env,
      )
    ).status,
    403,
  );
  assert.equal((await worker.fetch(new Request('https://edge.test/ws'), env)).status, 426);
  assert.equal(
    (
      await worker.fetch(
        new Request('https://edge.test/ws?token=invalid', { headers: { Upgrade: 'websocket' } }),
        env,
      )
    ).status,
    401,
  );

  // Connect Host WS
  const hostUpgrade = await worker.fetch(
    new Request('https://edge.test/ws/host?machineId=mach_edge&machineName=Studio-Mac&secret=host_sec_99', {
      headers: { Upgrade: 'websocket' },
    }),
    env,
  );
  assert.equal(hostUpgrade.status, 101);
  const room = getRoom('mach_edge');
  const hostServerWs = room.createdPairs[0].server;

  // Host pushes snapshot & ping
  await room.instance.webSocketMessage(hostServerWs, JSON.stringify({ type: 'host.ping' }));
  assert.equal(hostServerWs.sent.at(-1).type, 'edge.pong');

  await room.instance.webSocketMessage(
    hostServerWs,
    JSON.stringify({
      v: 'arp.v1',
      type: 'host.snapshot',
      payload: { approvalMode: 'auto-safe', sessions: [{ id: 's1' }] },
    }),
  );

  // Connect Mobile A & Mobile B -> both immediately get cached snapshot in server.hello!
  const mobAUpgrade = await worker.fetch(
    new Request(`https://edge.test/ws?token=${encodeURIComponent(pairBody.deviceToken)}`, {
      headers: { Upgrade: 'websocket' },
    }),
    env,
  );
  assert.equal(mobAUpgrade.status, 101);
  const mobAServerWs = room.createdPairs[1].server;
  assert.equal(mobAServerWs.sent[0].type, 'server.hello');
  assert.equal(mobAServerWs.sent[0].payload.approvalMode, 'auto-safe');
  assert.equal(mobAServerWs.sent[0].payload.hostOnline, true);

  await worker.fetch(
    new Request(`https://edge.test/ws?token=${encodeURIComponent(pairB.deviceToken)}`, {
      headers: { Upgrade: 'websocket' },
    }),
    env,
  );
  const mobBServerWs = room.createdPairs[2].server;

  // Mobile A sends client.ping -> edge replies directly
  await room.instance.webSocketMessage(
    mobAServerWs,
    JSON.stringify({ v: 'arp.v1', type: 'client.ping', reqId: 'p1' }),
  );
  assert.equal(mobAServerWs.sent.at(-1).type, 'server.pong');

  // Mobile A sends sessions.list -> forwarded to Host with __edgeClientId; Host replies unicast ONLY to Mobile A!
  await room.instance.webSocketMessage(
    mobAServerWs,
    JSON.stringify({ v: 'arp.v1', type: 'sessions.list', reqId: 'r_list', payload: {} }),
  );
  const forwardedToHost = hostServerWs.sent.at(-1);
  assert.equal(forwardedToHost.type, 'sessions.list');
  assert.equal(forwardedToHost.payload.__edgeClientId, pairBody.deviceId);
  assert.equal(forwardedToHost.payload.__deviceName, 'Phone-A');

  const mobBCountBefore = mobBServerWs.sent.length;
  await room.instance.webSocketMessage(
    hostServerWs,
    JSON.stringify({
      v: 'arp.v1',
      type: 'sessions.list.result',
      reqId: 'r_list',
      payload: { sessions: [], __targetClientId: pairBody.deviceId },
    }),
  );
  assert.equal(mobAServerWs.sent.at(-1).type, 'sessions.list.result');
  assert.equal('__targetClientId' in mobAServerWs.sent.at(-1).payload, false);
  assert.equal(mobBServerWs.sent.length, mobBCountBefore);

  // Room status route & 404 route
  const statusRes = await worker.fetch(new Request('https://edge.test/api/session/mach_edge'), env);
  const statusJson = await statusRes.json();
  assert.equal(statusJson.hostOnline, true);
  assert.equal(statusJson.mobileCount, 2);

  assert.equal((await worker.fetch(new Request('https://edge.test/unknown'), env)).status, 404);

  // Host disconnects -> mobiles receive edge.host_status { online: false }, subsequent mobile RPC gets offline error
  await room.instance.webSocketClose(hostServerWs);
  room.state.removeSocket(hostServerWs);
  assert.equal(mobAServerWs.sent.at(-1).type, 'edge.host_status');
  assert.equal(mobAServerWs.sent.at(-1).payload.online, false);

  await room.instance.webSocketMessage(
    mobAServerWs,
    JSON.stringify({ v: 'arp.v1', type: 'chat.send', reqId: 'r_off', payload: { prompt: 'hi' } }),
  );
  assert.equal(mobAServerWs.sent.at(-1).type, 'error');
});

test('VS Code status-format escapes XSS characters and computes status bar states', async () => {
  const fmt = await importTypeScriptModule('apps/vscode-extension/src/status-format.ts');

  assert.equal(
    fmt.escapeHtml(`<img src=x onerror="alert('xss')">&`),
    '&lt;img src=x onerror=&quot;alert(&#39;xss&#39;)&quot;&gt;&amp;',
  );
  assert.equal(fmt.escapeHtml(null), '');

  assert.deepEqual(
    fmt.computeStatusBarViewModel({ port: 7443, connectedClients: { total: 0 }, pendingApprovals: [] }),
    { text: '$(broadcast) AGY Remote :7443', isWarning: false },
  );
  assert.deepEqual(
    fmt.computeStatusBarViewModel({ port: 7443, connectedClients: { total: 2 }, pendingApprovals: [] }),
    { text: '$(radio-tower) AGY Remote (2)', isWarning: false },
  );
  assert.deepEqual(
    fmt.computeStatusBarViewModel({
      port: 7443,
      connectedClients: { total: 1 },
      pendingApprovals: [{ id: 'apr_1' }],
    }),
    { text: '$(bell-dot) AGY Remote (1 approval)', isWarning: true },
  );
});

test('VSIX packager produces valid PKZIP archive with manifest and bundled web-client', async () => {
  const { existsSync, readFileSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { buildVsixPackage, crc32 } = await import('../scripts/install-vscode-extension.mjs');

  assert.equal(crc32(Buffer.from('123456789', 'utf-8')), 0xcbf43926);

  const extDir = join(process.cwd(), 'apps', 'vscode-extension');
  const built = buildVsixPackage(extDir);
  assert.equal(built.id, 'antigravity-remote.antigravity-remote-vscode');
  assert.ok(existsSync(built.vsixPath));
  assert.ok(built.entryCount >= 6);

  const zipBytes = readFileSync(built.vsixPath);
  assert.equal(zipBytes.readUInt32LE(0), 0x04034b50); // PK\x03\x04
  assert.ok(zipBytes.includes(Buffer.from('extension/package.json')));
  assert.ok(zipBytes.includes(Buffer.from('extension/dist/extension.js')));
  assert.ok(zipBytes.includes(Buffer.from('extension.vsixmanifest')));
});
