/**
 * Comprehensive End-to-End Integration Test Suite for Antigravity Remote (`agy-remote`).
 * Verifies:
 *  1. Protocol codecs, `<USER_REQUEST>` extraction, & offline ISO QR SVG generation
 *  2. LAN HTTP Pairing (6-digit PIN & QR token), replay protection, & device revocation
 *  3. Real-time WebSocket session discovery, artifact reading, & live `transcript.jsonl` step streaming
 *  4. Real `hooks/gatekeeper.mjs` subprocess `PreToolUse` interception & mobile Approve / Deny / Auto-Safe
 *  5. Embedded Mobile Web PWA static serving & quick remote terminal execution
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { appendFileSync, chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  buildPairingUrl,
  cleanArgsObject,
  extractUserPrompt,
  isSafeCommand,
  parsePairingInput,
} from '../packages/protocol/src/index.mjs';
import { renderQrSvg } from '../packages/protocol/src/qr-svg.mjs';
import {
  BridgeServer,
  DISCOVERY_PROBE_MAGIC,
  runtimeDiscoveryPath,
} from '../packages/bridge-core/src/index.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..');

function runGatekeeperSubprocess(hookPayload, runtimeFilePath) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [join(repoRoot, 'apps/agy-plugin/hooks/gatekeeper.mjs')], {
      env: { ...process.env, AGY_REMOTE_RUNTIME_FILE: runtimeFilePath },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let out = '';
    let err = '';
    proc.stdout.on('data', (c) => (out += c.toString('utf-8')));
    proc.stderr.on('data', (c) => (err += c.toString('utf-8')));
    proc.on('error', reject);
    proc.on('close', (code) => {
      if (code !== 0) return reject(new Error(`gatekeeper exited ${code}: ${err}`));
      resolve(JSON.parse(out.trim()));
    });
    proc.stdin.write(JSON.stringify(hookPayload));
    proc.stdin.end();
  });
}

test('Protocol codecs, QR SVG generator, and safe command classifier', () => {
  const url = buildPairingUrl({
    baseUrl: 'http://192.168.1.50:7443',
    token: 'tok_abc123',
    pin: '482915',
    machineId: 'mach_01',
    machineName: 'DEV-PC',
    cloudflareUrl: 'https://agy.example.workers.dev',
    sessionId: 'mach_01',
  });

  const parsed = parsePairingInput(url);
  assert.equal(parsed.baseUrl, 'http://192.168.1.50:7443');
  assert.equal(parsed.token, 'tok_abc123');
  assert.equal(parsed.machineId, 'mach_01');
  assert.equal(parsed.cloudflareUrl, 'https://agy.example.workers.dev');

  const svg = renderQrSvg(url);
  assert.ok(svg.startsWith('<svg') && svg.includes('<path d="M'));

  const clean = extractUserPrompt('<USER_REQUEST>\nСделай мобильное приложение\n</USER_REQUEST>\n<ADDITIONAL_METADATA>time</ADDITIONAL_METADATA>');
  assert.equal(clean, 'Сделай мобильное приложение');

  const unquoted = cleanArgsObject({ Path: '"g:\\\\GEMINI_APP\\\\README.md"' });
  assert.equal(unquoted.Path, 'g:\\GEMINI_APP\\README.md');

  assert.equal(isSafeCommand('git status'), true);
  assert.equal(isSafeCommand('flutter analyze'), true);
  assert.equal(isSafeCommand('rm -rf /'), false);
  assert.equal(isSafeCommand('git status && curl evil.com'), false);
});

test('Full End-to-End LAN Pairing, WS Streaming, and PreToolUse Mobile Gatekeeper', async (t) => {
  const tempRoot = mkdtempSync(join(tmpdir(), 'agy-remote-test-'));
  const stateDir = join(tempRoot, 'state');
  const brainRoot = join(tempRoot, 'brain');
  const convId = '11111111-2222-3333-4444-555555555555';
  const convDir = join(brainRoot, convId);
  const logsDir = join(convDir, '.system_generated', 'logs');
  mkdirSync(logsDir, { recursive: true });

  const transcriptFile = join(logsDir, 'transcript.jsonl');
  writeFileSync(
    transcriptFile,
    [
      JSON.stringify({
        step_index: 0,
        type: 'USER_INPUT',
        status: 'DONE',
        created_at: '2026-11-12T01:00:00Z',
        content: '<USER_REQUEST>\nBuild Cloudflare session relay\n</USER_REQUEST>',
      }),
      JSON.stringify({
        step_index: 1,
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        created_at: '2026-11-12T01:00:02Z',
        thinking: 'Designing SessionRoomDO Durable Object...',
        tool_calls: [{ name: 'write_file', args: { Path: '"src/index.ts"', toolSummary: '"Create edge worker"' } }],
      }),
    ].join('\n') + '\n',
  );
  writeFileSync(join(convDir, 'plan.md'), '# Implementation Plan\nAll green.');

  const server = new BridgeServer({
    port: 0,
    host: '127.0.0.1',
    stateDir,
    brainRoots: [brainRoot],
    defaultWorkspace: repoRoot,
    approvalTimeoutMs: 8000,
  });

  const status = await server.start();
  t.after(async () => {
    await server.stop();
    rmSync(tempRoot, { recursive: true, force: true });
  });

  const baseHttp = `http://127.0.0.1:${server.port}`;

  // 1. Embedded PWA served cleanly
  const pwaRes = await fetch(`${baseHttp}/app`);
  assert.equal(pwaRes.status, 200);
  const pwaHtml = await pwaRes.text();
  assert.ok(pwaHtml.includes('Antigravity Remote'));

  // 2. Reject wrong PIN, accept valid 6-digit PIN, reject replay of consumed PIN
  const badPair = await fetch(`${baseHttp}/api/pair`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pin: '000000', deviceName: 'Test Phone' }),
  });
  assert.equal(badPair.status, 401);

  const goodPairRes = await fetch(`${baseHttp}/api/pair`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pin: status.pairing.pin, deviceName: 'Pixel 9 Pro', platform: 'flutter-android' }),
  });
  assert.equal(goodPairRes.status, 200);
  const pairData = await goodPairRes.json();
  assert.equal(pairData.ok, true);
  assert.ok(pairData.deviceToken);

  const replayRes = await fetch(`${baseHttp}/api/pair`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pin: status.pairing.pin, deviceName: 'Attacker' }),
  });
  assert.equal(replayRes.status, 401);

  // 3. Connect Mobile WebSocket & inspect real-time session stream
  const inbox = [];
  const waiters = [];
  const waitForType = (type, timeoutMs = 4000) => {
    const existingIdx = inbox.findIndex((m) => m.type === type);
    if (existingIdx !== -1) return Promise.resolve(inbox.splice(existingIdx, 1)[0]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timeout waiting for WS ${type}`)), timeoutMs);
      waiters.push({ type, resolve: (msg) => { clearTimeout(timer); resolve(msg); } });
    });
  };

  const ws = new WebSocket(`ws://127.0.0.1:${server.port}/ws?token=${encodeURIComponent(pairData.deviceToken)}`);
  t.after(() => ws.close());

  ws.addEventListener('message', (ev) => {
    const env = JSON.parse(String(ev.data));
    const wIdx = waiters.findIndex((w) => w.type === env.type);
    if (wIdx !== -1) {
      const [w] = waiters.splice(wIdx, 1);
      w.resolve(env);
    } else {
      inbox.push(env);
    }
  });

  const hello = await waitForType('server.hello');
  assert.equal(hello.payload.sessions.length, 1);
  assert.equal(hello.payload.sessions[0].title, 'Build Cloudflare session relay');

  // Fetch session detail & artifact
  ws.send(JSON.stringify({ v: 'arp.v1', type: 'session.detail', reqId: 'r1', payload: { conversationId: convId } }));
  const detailMsg = await waitForType('session.detail.result');
  assert.equal(detailMsg.payload.detail.steps.length, 2);
  assert.equal(detailMsg.payload.detail.artifacts[0].fileName, 'plan.md');

  ws.send(JSON.stringify({ v: 'arp.v1', type: 'session.artifact', reqId: 'r2', payload: { conversationId: convId, fileName: 'plan.md' } }));
  const artMsg = await waitForType('session.artifact.result');
  assert.ok(artMsg.payload.artifact.content.includes('# Implementation Plan'));

  // 4. Append new step to transcript.jsonl and verify live delta push
  appendFileSync(
    transcriptFile,
    JSON.stringify({
      step_index: 2,
      type: 'PLANNER_RESPONSE',
      status: 'DONE',
      created_at: '2026-11-12T01:00:05Z',
      content: 'SessionRoomDO implemented and verified!',
    }) + '\n',
  );
  server.brain.scanNow(true);

  const deltaMsg = await waitForType('session.steps_delta');
  assert.equal(deltaMsg.payload.conversationId, convId);
  assert.ok(deltaMsg.payload.steps.some((s) => s.content.includes('SessionRoomDO implemented')));

  // 5. Real `hooks/gatekeeper.mjs` PreToolUse interception -> Mobile Approve & Deny!
  const runtimeFile = runtimeDiscoveryPath(stateDir);

  const approvePromise = runGatekeeperSubprocess(
    {
      conversationId: convId,
      cwd: repoRoot,
      toolCall: {
        id: 'tc_01',
        name: 'run_command',
        args: { CommandLine: '"npm run deploy"' },
      },
    },
    runtimeFile,
  );

  const reqEvent = await waitForType('approval.requested');
  assert.equal(reqEvent.payload.toolName, 'run_command');
  assert.equal(reqEvent.payload.args.CommandLine, 'npm run deploy');

  // Tap "Approve" on mobile!
  ws.send(
    JSON.stringify({
      v: 'arp.v1',
      type: 'approval.decide',
      reqId: 'r3',
      payload: { id: reqEvent.payload.id, decision: 'allow' },
    }),
  );

  const hookResultAllow = await approvePromise;
  assert.equal(hookResultAllow.decision, 'allow');

  // Test Mobile "Deny"!
  const denyPromise = runGatekeeperSubprocess(
    {
      conversationId: convId,
      cwd: repoRoot,
      toolCall: {
        id: 'tc_02',
        name: 'run_command',
        args: { CommandLine: '"del /f /q important.db"' },
      },
    },
    runtimeFile,
  );

  const reqEvent2 = await waitForType('approval.requested');
  ws.send(
    JSON.stringify({
      v: 'arp.v1',
      type: 'approval.decide',
      reqId: 'r4',
      payload: { id: reqEvent2.payload.id, decision: 'deny' },
    }),
  );

  const hookResultDeny = await denyPromise;
  assert.equal(hookResultDeny.decision, 'deny');

  // Test Auto-Safe mode!
  ws.send(JSON.stringify({ v: 'arp.v1', type: 'settings.set', payload: { approvalMode: 'auto-safe' } }));
  await waitForType('settings.updated');

  const safeResult = await runGatekeeperSubprocess(
    {
      conversationId: convId,
      cwd: repoRoot,
      toolCall: {
        id: 'tc_03',
        name: 'run_command',
        args: { CommandLine: '"git status"' },
      },
    },
    runtimeFile,
  );
  assert.equal(safeResult.decision, 'allow');

  // 6. Non-blocking Workspace File Staging (PreToolUse -> Write -> PostToolUse -> changes.updated -> Save All)
  const sampleWorkspace = join(tempRoot, 'sample-ws');
  mkdirSync(sampleWorkspace, { recursive: true });
  const sampleFile = join(sampleWorkspace, 'hello.js');
  writeFileSync(sampleFile, 'console.log("v1");\n', 'utf-8');

  const preFileRes = await runGatekeeperSubprocess(
    {
      hookEventName: 'PreToolUse',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
      toolCall: {
        id: 'tc_file_1',
        name: 'edit_file',
        args: { Path: sampleFile },
      },
    },
    runtimeFile,
  );
  assert.equal(preFileRes.decision, 'allow');

  writeFileSync(sampleFile, 'console.log("v2");\nconsole.log("saved all!");\n', 'utf-8');

  const postFileRes = await runGatekeeperSubprocess(
    {
      hookEventName: 'PostToolUse',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
      toolCall: {
        id: 'tc_file_1',
        name: 'edit_file',
        args: { Path: sampleFile },
      },
    },
    runtimeFile,
  );
  assert.deepEqual(postFileRes, {});

  const changesPush = await waitForType('changes.updated');
  assert.equal(changesPush.payload.files.length, 1);
  assert.equal(changesPush.payload.files[0].path, 'hello.js');
  assert.equal(changesPush.payload.files[0].status, 'MOD');

  ws.send(JSON.stringify({ v: 'arp.v1', type: 'changes.diff', reqId: 'r_cdiff', payload: { path: 'hello.js' } }));
  const cdiffMsg = await waitForType('changes.diff.result');
  assert.match(cdiffMsg.payload.diff, /\+console\.log\("saved all!"\);/);

  ws.send(JSON.stringify({ v: 'arp.v1', type: 'changes.save_all', reqId: 'r_csave', payload: {} }));
  const csaveMsg = await waitForType('changes.save_all.result');
  assert.equal(csaveMsg.payload.savedCount, 1);
  assert.equal(csaveMsg.payload.files.length, 0);

  // 7. PreInvocation lifecycle hook drains queued mobile prompts via injectSteps!
  server.driver.queuedMessages.set(convId, [
    { id: 'q_mob_1', prompt: 'Продолжай по плану', createdAt: Date.now() },
  ]);
  const preInvRes = await runGatekeeperSubprocess(
    {
      hookEventName: 'PreInvocation',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
    },
    runtimeFile,
  );
  assert.ok(Array.isArray(preInvRes.injectSteps));
  assert.equal(preInvRes.injectSteps.length, 1);
  assert.match(preInvRes.injectSteps[0].userMessage, /Продолжай по плану/);

  // 7b. Successful `agentapi` `chat.send` arms a one-shot PreInvocation mirror (`injectSteps`) and clears after one consume!
  const mockApi = join(tempRoot, 'mock-mirror-agentapi.mjs');
  writeFileSync(
    mockApi,
    `#!/usr/bin/env node
const cmd = process.argv[2];
if (cmd === 'get-conversation-metadata') {
  console.log(JSON.stringify({ response: { conversationMetadata: { metadata: { projectId: 'p_e2e' } } } }));
  process.exit(0);
}
if (cmd === 'send-message') {
  console.log(JSON.stringify({ response: { ok: true } }));
  process.exit(0);
}
`,
  );
  chmodSync(mockApi, 0o755);
  const prevAgentApiPath = server.driver.agentApiPath;
  server.driver.agentApiPath = mockApi;
  await runGatekeeperSubprocess(
    {
      hookEventName: 'SessionStart',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
      __hostContext: { lsAddress: '127.0.0.1:61555', csrfToken: 'csrf_e2e' },
    },
    runtimeFile,
  );
  // Seed host registry via direct registerHookContext (simulates ANTIGRAVITY_LS_ADDRESS in IDE hook env)
  server.driver.registerHookContext({
    conversationId: convId,
    cwd: sampleWorkspace,
    workspacePaths: [sampleWorkspace],
    __hostContext: { lsAddress: '127.0.0.1:61555', csrfToken: 'csrf_e2e' },
  });
  ws.send(
    JSON.stringify({
      v: 'arp.v1',
      type: 'chat.send',
      reqId: 'r_mir_send',
      payload: { conversationId: convId, prompt: 'Отрази сообщение в IDE' },
    }),
  );
  const mirSendAck = await waitForType('chat.send.result');
  assert.equal(mirSendAck.payload.ok, true);
  assert.equal(mirSendAck.payload.delivery, 'agentapi');

  const mirrorPreInv = await runGatekeeperSubprocess(
    {
      hookEventName: 'PreInvocation',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
    },
    runtimeFile,
  );
  assert.deepEqual(mirrorPreInv, {
    injectSteps: [{ userMessage: 'Отрази сообщение в IDE' }],
  });
  const secondPreInv = await runGatekeeperSubprocess(
    {
      hookEventName: 'PreInvocation',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
    },
    runtimeFile,
  );
  assert.deepEqual(secondPreInv, {});
  server.driver.agentApiPath = prevAgentApiPath;

  // 8. Stop lifecycle hook at end of task auto-saves pending changes on laptop & bumps lastTaskCompletedAt!
  await runGatekeeperSubprocess(
    {
      hookEventName: 'PreToolUse',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
      toolCall: { id: 'tc_file_2', name: 'edit_file', args: { Path: sampleFile } },
    },
    runtimeFile,
  );
  writeFileSync(sampleFile, 'console.log("v3 auto-saved at end of task");\n', 'utf-8');
  await runGatekeeperSubprocess(
    {
      hookEventName: 'PostToolUse',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
      toolCall: { id: 'tc_file_2', name: 'edit_file', args: { Path: sampleFile } },
    },
    runtimeFile,
  );
  assert.equal(server.changes.listPending().length, 1);

  const stopRes = await runGatekeeperSubprocess(
    {
      hookEventName: 'Stop',
      conversationId: convId,
      cwd: sampleWorkspace,
      workspacePaths: [sampleWorkspace],
    },
    runtimeFile,
  );
  assert.equal(stopRes.decision, 'allow');
  assert.equal(server.changes.listPending().length, 0);
  assert.ok(server.getControlStatus().lastTaskCompletedAt > 0);
  assert.ok(server.getControlStatus().registeredHosts);
});

test('Cloudflare Edge Relay Connector multiplexes RPCs between Desktop Bridge and Remote Mobile', async (t) => {
  const { createServer } = await import('node:http');
  const { upgradeToWebSocket } = await import('../packages/bridge-core/src/rfc6455-ws.mjs');

  const tempRoot = mkdtempSync(join(tmpdir(), 'agy-cf-test-'));
  const stateDir = join(tempRoot, 'state');
  const brainRoot = join(tempRoot, 'brain');
  mkdirSync(brainRoot, { recursive: true });

  // Simulated Cloudflare Worker + SessionRoomDO Relay Server
  let hostSocket = null;
  const mobileSockets = new Map();
  let syncedPairing = null;

  const mockEdgeServer = createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/api/edge/pair-create') {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        syncedPairing = JSON.parse(body);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      });
      return;
    }
    res.writeHead(404).end();
  });

  mockEdgeServer.on('upgrade', (req, socket, head) => {
    const u = new URL(req.url || '/', 'http://localhost');
    const peer = upgradeToWebSocket(req, socket, head, {});
    if (u.pathname === '/ws/host') {
      hostSocket = peer;
      peer.sendJson({ v: 'arp.v1', type: 'edge.presence', ts: Date.now(), payload: { mobileCount: mobileSockets.size } });
      peer.on('message', (raw) => {
        const env = JSON.parse(raw);
        const target = env.payload?.__targetClientId;
        if (target && mobileSockets.has(target)) {
          delete env.payload.__targetClientId;
          mobileSockets.get(target).sendJson(env);
        } else {
          for (const m of mobileSockets.values()) m.sendJson(env);
        }
      });
    } else if (u.pathname === '/ws') {
      const cid = 'mob_cf_1';
      mobileSockets.set(cid, peer);
      hostSocket?.sendJson({ v: 'arp.v1', type: 'edge.presence', ts: Date.now(), payload: { mobileCount: mobileSockets.size } });
      peer.on('message', (raw) => {
        const env = JSON.parse(raw);
        env.payload = { ...(env.payload || {}), __edgeClientId: cid, __deviceName: 'iPhone over 5G' };
        hostSocket?.sendJson(env);
      });
    }
  });

  await new Promise((resolve) => mockEdgeServer.listen(0, '127.0.0.1', resolve));
  const edgePort = mockEdgeServer.address().port;
  const edgeBaseUrl = `http://127.0.0.1:${edgePort}`;

  const bridge = new BridgeServer({
    port: 0,
    host: '127.0.0.1',
    stateDir,
    brainRoots: [brainRoot],
    defaultWorkspace: repoRoot,
  });
  await bridge.start();

  let edgeMobileWs = null;
  t.after(async () => {
    edgeMobileWs?.close();
    await bridge.stop();
    mockEdgeServer.closeAllConnections?.();
    await new Promise((resolve) => mockEdgeServer.close(resolve));
    rmSync(tempRoot, { recursive: true, force: true });
  });

  // Enable Cloudflare Edge mode dynamically via settings!
  bridge.auth.updateSettings({
    cloudflareMode: 'edge-worker',
    cloudflareEdgeUrl: edgeBaseUrl,
    cloudflareEdgeSecret: 'edge_sec_123',
  });
  bridge._applyCloudflareConfig(bridge.auth.getSettings());

  // Wait for outbound WSS/WS link to connect
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Edge link timeout')), 4000);
    bridge.cloudflare.on('state_changed', (st) => {
      if (st.status === 'connected') {
        clearTimeout(timeout);
        resolve();
      }
    });
  });

  // Connect remote mobile to the Cloudflare Edge Relay & run a quick git command on Desktop!
  edgeMobileWs = new WebSocket(`ws://127.0.0.1:${edgePort}/ws`);

  await new Promise((resolve) => edgeMobileWs.addEventListener('open', resolve));

  const replyPromise = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timeout waiting for Edge RPC result')), 5000);
    edgeMobileWs.addEventListener('message', (ev) => {
      const msg = JSON.parse(String(ev.data));
      if (msg.type === 'sessions.list.result') {
        clearTimeout(timer);
        resolve(msg);
      }
    });
  });

  edgeMobileWs.send(JSON.stringify({ v: 'arp.v1', type: 'sessions.list', reqId: 'cf_1', payload: {} }));
  const reply = await replyPromise;
  assert.equal(reply.reqId, 'cf_1');
  assert.ok(Array.isArray(reply.payload.sessions));
  assert.ok(syncedPairing?.pin);
});

test('E2E Mobile Uploads, Stop Agent Latch, Workspace Switcher, and UDP LAN Discovery Beacon', async (t) => {
  const { createSocket } = await import('node:dgram');
  const { existsSync, readFileSync } = await import('node:fs');

  const tempRoot = mkdtempSync(join(tmpdir(), 'agy-e2e-v12-'));
  const stateDir = join(tempRoot, 'state');
  const brainRoot = join(tempRoot, 'brain');
  const wsOne = join(tempRoot, 'project-alpha');
  const wsTwo = join(tempRoot, 'project-beta');
  mkdirSync(wsOne, { recursive: true });
  mkdirSync(wsTwo, { recursive: true });
  writeFileSync(join(wsOne, 'package.json'), '{"name":"alpha"}');
  writeFileSync(join(wsTwo, 'pubspec.yaml'), 'name: beta\n');

  const convId = '22222222-3333-4444-5555-666666666666';
  const logsDir = join(brainRoot, convId, '.system_generated', 'logs');
  mkdirSync(logsDir, { recursive: true });
  writeFileSync(
    join(logsDir, 'transcript.jsonl'),
    [
      JSON.stringify({
        step_index: 0,
        type: 'USER_INPUT',
        content: `Active Workspaces:\n- ${wsTwo}\n<USER_REQUEST>Оптимизируй виджеты</USER_REQUEST>`,
      }),
      JSON.stringify({
        step_index: 1,
        type: 'PLANNER_RESPONSE',
        thinking: 'Checking files...',
        tool_calls: [{ name: 'read_file', args: { Path: `"${join(wsTwo, 'lib', 'main.dart')}"` } }],
      }),
    ].join('\n') + '\n',
  );

  const server = new BridgeServer({
    port: 0,
    host: '127.0.0.1',
    stateDir,
    brainRoots: [brainRoot],
    defaultWorkspace: wsOne,
    discoveryPort: 0, // bind ephemeral UDP port for deterministic probe testing
    enableMdns: false,
  });

  const st = await server.start();
  t.after(async () => {
    await server.stop();
    rmSync(tempRoot, { recursive: true, force: true });
  });

  // 1. Verify UDP LAN Discovery Beacon (#22)
  assert.ok(server.beacon?.boundUdpPort > 0);
  const beaconReply = await new Promise((resolve, reject) => {
    const sock = createSocket('udp4');
    const timer = setTimeout(() => {
      sock.close();
      reject(new Error('UDP discovery probe timeout'));
    }, 3000);
    sock.on('message', (msg) => {
      clearTimeout(timer);
      sock.close();
      resolve(JSON.parse(msg.toString('utf-8')));
    });
    sock.send(Buffer.from(DISCOVERY_PROBE_MAGIC), server.beacon.boundUdpPort, '127.0.0.1');
  });
  assert.equal(beaconReply.type, 'bridge.beacon');
  assert.equal(beaconReply.machineId, st.machineId);
  assert.equal(beaconReply.port, server.port);

  // Pair mobile client
  const baseHttp = `http://127.0.0.1:${server.port}`;
  const pairRes = await fetch(`${baseHttp}/api/pair`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pin: st.pairing.pin, deviceName: 'Android Mobile', platform: 'flutter-android' }),
  });
  const pairJson = await pairRes.json();
  assert.equal(pairJson.ok, true);

  // 2. Verify LAN HTTP Multipart-free Base64 File Upload (#11)
  const imgBytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x01, 0x02]);
  const uploadRes = await fetch(`${baseHttp}/api/mobile/upload`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${pairJson.deviceToken}`,
    },
    body: JSON.stringify({
      fileName: 'ui screenshot (1).png',
      base64Data: imgBytes.toString('base64'),
      workspace: wsTwo,
    }),
  });
  assert.equal(uploadRes.status, 200);
  const uploaded = await uploadRes.json();
  assert.equal(uploaded.ok, true);
  assert.equal(uploaded.isImage, true);
  assert.equal(uploaded.workspace, wsTwo);
  assert.ok(existsSync(uploaded.savedPath));
  assert.deepEqual(readFileSync(uploaded.savedPath), imgBytes);

  // Connect WebSocket for RPC checks (#11 WS fallback, #12 Stop, #20 Workspaces)
  const inbox = [];
  const waiters = [];
  const waitForType = (type, timeoutMs = 4000) => {
    const idx = inbox.findIndex((m) => m.type === type);
    if (idx !== -1) return Promise.resolve(inbox.splice(idx, 1)[0]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timeout waiting for ${type}`)), timeoutMs);
      waiters.push({
        type,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        },
      });
    });
  };

  const ws = new WebSocket(`ws://127.0.0.1:${server.port}/ws?token=${encodeURIComponent(pairJson.deviceToken)}`);
  t.after(() => ws.close());
  ws.addEventListener('message', (ev) => {
    const env = JSON.parse(String(ev.data));
    const wi = waiters.findIndex((w) => w.type === env.type);
    if (wi !== -1) waiters.splice(wi, 1)[0].resolve(env);
    else inbox.push(env);
  });

  const hello = await waitForType('server.hello');
  assert.equal(hello.payload.activeWorkspace, wsOne);
  assert.equal(hello.payload.sessions[0].workspaceName, 'project-beta');
  assert.ok(hello.payload.workspaces.some((w) => w.name === 'project-alpha' && w.isDefault));
  assert.ok(hello.payload.workspaces.some((w) => w.name === 'project-beta' && w.sessionCount === 1));

  // 3. Switch active workspace (#20)
  ws.send(JSON.stringify({ v: 'arp.v1', type: 'workspace.select', reqId: 'ws_sel', payload: { path: wsTwo } }));
  const wsSelected = await waitForType('workspaces.list.result');
  assert.equal(wsSelected.payload.activeWorkspace, wsTwo);
  assert.equal(server.driver.defaultWorkspace, wsTwo);

  // WS fallback file upload (`workspace.upload_file`)
  ws.send(
    JSON.stringify({
      v: 'arp.v1',
      type: 'workspace.upload_file',
      reqId: 'up_ws',
      payload: {
        fileName: 'spec.txt',
        base64Data: Buffer.from('hello from edge').toString('base64'),
      },
    }),
  );
  const wsUploadRes = await waitForType('workspace.upload_file.result');
  assert.equal(wsUploadRes.payload.ok, true);
  assert.equal(wsUploadRes.payload.isImage, false);
  assert.equal(readFileSync(wsUploadRes.payload.savedPath, 'utf-8'), 'hello from edge');

  // 4. Stop Agent (#12): immediately denies pending PreToolUse AND aborts subsequent PreToolUse until new user prompt!
  const runtimeFile = runtimeDiscoveryPath(stateDir);
  const pendingHook = runGatekeeperSubprocess(
    {
      conversationId: convId,
      cwd: wsTwo,
      toolCall: { id: 'tc_stop_1', name: 'run_command', args: { CommandLine: '"npm run build"' } },
    },
    runtimeFile,
  );
  await waitForType('approval.requested');

  ws.send(JSON.stringify({ v: 'arp.v1', type: 'chat.stop', reqId: 'stop_1', payload: { conversationId: convId } }));
  const stopReply = await waitForType('chat.stop.result');
  assert.equal(stopReply.payload.ok, true);
  assert.equal(stopReply.payload.abortedApprovals, 1);

  const pendingDecision = await pendingHook;
  assert.equal(pendingDecision.decision, 'deny');
  assert.ok(server.getControlStatus().lastStopRequestedAt > 0);

  // Subsequent tool call in the same stopped turn is immediately denied without prompting mobile!
  const followUpTool = await runGatekeeperSubprocess(
    {
      conversationId: convId,
      cwd: wsTwo,
      toolCall: { id: 'tc_stop_2', name: 'write_file', args: { Path: join(wsTwo, 'a.txt') } },
    },
    runtimeFile,
  );
  assert.equal(followUpTool.decision, 'deny');

  // New user invocation clears the stop latch cleanly
  await runGatekeeperSubprocess(
    { hookEventName: 'PreInvocation', conversationId: convId, cwd: wsTwo },
    runtimeFile,
  );
  const resumedTool = await runGatekeeperSubprocess(
    {
      conversationId: convId,
      cwd: wsTwo,
      workspacePaths: [wsTwo],
      toolCall: { id: 'tc_resumed', name: 'write_file', args: { Path: join(wsTwo, 'ok.txt') } },
    },
    runtimeFile,
  );
  assert.equal(resumedTool.decision, 'allow');
});

test('E2E Post-Sleep / Dead-LS Idle Session Wakeup via Sanctioned `agy acp` (Zero Manual Laptop Input Needed)', async (t) => {
  const prevLs = process.env.ANTIGRAVITY_LS_ADDRESS;
  delete process.env.ANTIGRAVITY_LS_ADDRESS;

  const tempRoot = mkdtempSync(join(tmpdir(), 'agy-acp-e2e-'));
  const stateDir = join(tempRoot, 'state');
  const geminiDir = join(tempRoot, '.gemini');
  const brainRoot = join(geminiDir, 'antigravity', 'brain');
  const workspaceDir = join(tempRoot, 'demo-project');
  mkdirSync(stateDir, { recursive: true });
  mkdirSync(workspaceDir, { recursive: true });

  const idleConvId = 'aaaaaaaa-1111-4111-8111-111111111111';
  const idleLogsDir = join(brainRoot, idleConvId, '.system_generated', 'logs');
  mkdirSync(idleLogsDir, { recursive: true });
  const idleTranscript = join(idleLogsDir, 'transcript.jsonl');
  writeFileSync(
    idleTranscript,
    [
      JSON.stringify({
        step_index: 0,
        type: 'USER_INPUT',
        status: 'DONE',
        content: '<USER_REQUEST>\nСделай рефакторинг модуля\n</USER_REQUEST>\nActive Workspaces:\n- ' + workspaceDir,
      }),
      JSON.stringify({
        step_index: 1,
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        content: 'План готов, жду подтверждения.',
      }),
    ].join('\n') + '\n',
    'utf-8',
  );

  // Pre-seed ONLY a dead overnight LS host (simulating MacBook waking after 8 hours of sleep)
  const deadAgentApi = join(tempRoot, 'dead-agentapi');
  writeFileSync(
    deadAgentApi,
    `#!/usr/bin/env node
console.error('dial tcp 127.0.0.1:59998: connect: connection refused');
process.exit(1);
`,
    'utf-8',
  );
  chmodSync(deadAgentApi, 0o755);

  writeFileSync(
    join(stateDir, 'hosts-runtime.json'),
    JSON.stringify({
      updatedAt: Date.now() - 6 * 3600_000,
      hosts: [
        {
          lsAddress: '127.0.0.1:59998',
          csrfToken: 'expired_overnight_csrf',
          agentApiExe: deadAgentApi,
          projectId: 'old_pid',
          appName: 'antigravity-ide',
          workspacePaths: [workspaceDir],
          updatedAt: Date.now() - 6 * 3600_000,
        },
      ],
      conversations: { [idleConvId]: '127.0.0.1:59998' },
    }),
    'utf-8',
  );

  // Mock `agy acp` server implementing ACP v1 (`initialize`, `session/resume`, `session/new`, `session/request_permission`, `session/prompt`, `session/cancel`)
  const acpEventsFile = join(tempRoot, 'acp-events.jsonl');
  const mockAgyBin = join(tempRoot, 'agy');
  writeFileSync(
    mockAgyBin,
    `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const args = process.argv.slice(2);
if (args[0] !== 'acp') {
  console.error('expected acp subcommand');
  process.exit(2);
}
const appDirIdx = args.indexOf('--app-data-dir');
const appDataDir = appDirIdx !== -1 ? args[appDirIdx + 1] : 'antigravity-cli';
const gemIdx = args.indexOf('--gemini-dir');
const gemDir = gemIdx !== -1 ? args[gemIdx + 1] : '';

let permReqSeq = 100;
const pendingPerms = new Map();

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  fs.appendFileSync(${JSON.stringify(acpEventsFile)}, JSON.stringify({ dir: 'in', appDataDir, msg }) + '\\n');

  if (msg.id !== undefined && !msg.method && pendingPerms.has(String(msg.id))) {
    const resolvePerm = pendingPerms.get(String(msg.id));
    pendingPerms.delete(String(msg.id));
    resolvePerm(msg.result);
    return;
  }

  if (msg.method === 'initialize') {
    process.stdout.write(JSON.stringify({
      jsonrpc: '2.0',
      id: msg.id,
      result: { protocolVersion: 1, agentCapabilities: { loadSession: true } }
    }) + '\\n');
    return;
  }

  if (msg.method === 'session/resume') {
    process.stdout.write(JSON.stringify({
      jsonrpc: '2.0',
      id: msg.id,
      result: { sessionId: msg.params.sessionId }
    }) + '\\n');
    return;
  }

  if (msg.method === 'session/new') {
    const newSid = '99999999-aaaa-bbbb-cccc-111111111111';
    const logsDir = path.join(gemDir, appDataDir, 'brain', newSid, '.system_generated', 'logs');
    fs.mkdirSync(logsDir, { recursive: true });
    fs.writeFileSync(path.join(logsDir, 'transcript.jsonl'), '', 'utf-8');
    process.stdout.write(JSON.stringify({
      jsonrpc: '2.0',
      id: msg.id,
      result: { sessionId: newSid }
    }) + '\\n');
    return;
  }

  if (msg.method === 'session/prompt') {
    const sid = msg.params.sessionId;
    const text = msg.params.prompt?.[0]?.text || '';
    const txFile = path.join(gemDir, appDataDir, 'brain', sid, '.system_generated', 'logs', 'transcript.jsonl');

    // Ask ACP permission first just like real \`agy acp\`
    const pid = String(permReqSeq++);
    pendingPerms.set(pid, (permRes) => {
      fs.appendFileSync(${JSON.stringify(acpEventsFile)}, JSON.stringify({ dir: 'perm_outcome', permRes }) + '\\n');
      const existing = fs.existsSync(txFile) ? fs.readFileSync(txFile, 'utf-8').trim().split('\\n').filter(Boolean) : [];
      const baseIdx = existing.length;
      fs.appendFileSync(txFile, JSON.stringify({
        step_index: baseIdx,
        type: 'USER_INPUT',
        source: 'USER_EXPLICIT',
        status: 'DONE',
        content: '<USER_REQUEST>\\n' + text + '\\n</USER_REQUEST>',
      }) + '\\n');
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0',
        method: 'session/update',
        params: { sessionId: sid }
      }) + '\\n');
      fs.appendFileSync(txFile, JSON.stringify({
        step_index: baseIdx + 1,
        type: 'PLANNER_RESPONSE',
        source: 'MODEL',
        status: 'DONE',
        content: 'Выполнено мгновенно через ACP без клика на ноутбуке: ' + text,
      }) + '\\n');
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0',
        id: msg.id,
        result: { stopReason: 'end_turn' }
      }) + '\\n');
    });

    process.stdout.write(JSON.stringify({
      jsonrpc: '2.0',
      id: pid,
      method: 'session/request_permission',
      params: {
        sessionId: sid,
        options: [
          { optionId: 'allow_once', kind: 'allow_once' },
          { optionId: 'reject_once', kind: 'reject_once' }
        ]
      }
    }) + '\\n');
  }
});
`,
    'utf-8',
  );
  chmodSync(mockAgyBin, 0o755);

  const server = new BridgeServer({
    port: 0,
    host: '127.0.0.1',
    stateDir,
    brainRoots: [brainRoot],
    defaultWorkspace: workspaceDir,
    agentApiPath: deadAgentApi,
    agyPath: mockAgyBin,
    geminiDir,
    acpIdleTimeoutMs: 5000,
    discoveryPort: false,
  });

  const st = await server.start();
  t.after(async () => {
    await server.stop();
    if (prevLs !== undefined) process.env.ANTIGRAVITY_LS_ADDRESS = prevLs;
    rmSync(tempRoot, { recursive: true, force: true });
  });

  const baseHttp = `http://127.0.0.1:${server.port}`;
  const pairRes = await fetch(`${baseHttp}/api/pair`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pin: st.pairing.pin, deviceName: 'Mobile Client', platform: 'flutter-android' }),
  });
  const { deviceToken } = await pairRes.json();

  const inbox = [];
  const waiters = [];
  const waitForMatch = (pred, label, timeoutMs = 5000) => {
    const idx = inbox.findIndex(pred);
    if (idx !== -1) return Promise.resolve(inbox.splice(idx, 1)[0]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timeout waiting for ${label}`)), timeoutMs);
      waiters.push({
        pred,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        },
      });
    });
  };

  const ws = new WebSocket(`ws://127.0.0.1:${server.port}/ws?token=${encodeURIComponent(deviceToken)}`);
  t.after(() => ws.close());
  ws.addEventListener('message', (ev) => {
    const env = JSON.parse(String(ev.data));
    const wIdx = waiters.findIndex((w) => w.pred(env));
    if (wIdx !== -1) {
      const [w] = waiters.splice(wIdx, 1);
      w.resolve(env);
    } else {
      inbox.push(env);
    }
  });

  await waitForMatch((m) => m.type === 'server.hello', 'server.hello');

  // 1. Send message from phone after 6h idle when cached LS host is dead -> MUST wake via ACP (`delivery: 'acp'`), NOT `'queued'`!
  ws.send(
    JSON.stringify({
      v: 'arp.v1',
      type: 'chat.send',
      reqId: 'wake_1',
      payload: { conversationId: idleConvId, prompt: 'да всё делай' },
    }),
  );

  const sendAck = await waitForMatch(
    (m) => m.type === 'chat.send.result' && m.reqId === 'wake_1',
    'chat.send.result(wake_1)',
  );
  assert.equal(sendAck.payload.ok, true);
  assert.equal(sendAck.payload.delivery, 'acp');
  assert.equal(sendAck.payload.targetHost, 'agy-acp:antigravity');
  assert.equal(server.driver.queuedMessages.has(idleConvId), false);

  // 2. Verify live `session.steps_delta` streams the assistant reply WITHOUT any laptop input!
  const delta = await waitForMatch(
    (m) =>
      m.type === 'session.steps_delta' &&
      m.payload.conversationId === idleConvId &&
      m.payload.steps.some((s) => s.content.includes('Выполнено мгновенно через ACP')),
    'session.steps_delta(ACP wakeup reply)',
  );
  assert.ok(delta.payload.steps.some((s) => s.role === 'user' && s.content === 'да всё делай'));

  // 3. Verify a subsequent laptop PreInvocation hook does NOT re-inject any duplicate queued message!
  const runtimeFile = runtimeDiscoveryPath(stateDir);
  const preInvOut = await runGatekeeperSubprocess(
    { hookEventName: 'PreInvocation', conversationId: idleConvId, cwd: workspaceDir },
    runtimeFile,
  );
  assert.deepEqual(preInvOut, {});

  // 4. Verify `chat.new` ALSO works via ACP when no LS host is alive!
  ws.send(
    JSON.stringify({
      v: 'arp.v1',
      type: 'chat.new',
      reqId: 'new_acp_1',
      payload: { prompt: 'Новый чат после сна ноутбука', workspace: workspaceDir },
    }),
  );
  const newAck = await waitForMatch(
    (m) => m.type === 'chat.send.result' && m.reqId === 'new_acp_1',
    'chat.send.result(new_acp_1)',
  );
  assert.equal(newAck.payload.ok, true);
  assert.equal(newAck.payload.delivery, 'acp');
  assert.equal(newAck.payload.conversationId, '99999999-aaaa-bbbb-cccc-111111111111');
});
