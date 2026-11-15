import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';

import {
  AgentDriver,
  ApprovalGate,
  AuthManager,
  BrainWatcher,
  ChangeTracker,
  CloudflareConnector,
  applyCorsHeaders,
  computeUnifiedTextDiff,
  discoverLanAddresses,
  dispatchClientRpc,
  extractBearerToken,
  readJsonBody,
  runtimeDiscoveryPath,
  sendJson,
  serveStaticAsset,
  startOrAttachBridge,
} from '../packages/bridge-core/src/index.mjs';
import { evaluateGatekeeperPayload, readStdin } from '../apps/agy-plugin/hooks/gatekeeper.mjs';

test('AuthManager persists state, recovers from corruption, pairs via PIN/QR, and blocks replay/tampering', () => {
  const dir = mkdtempSync(join(tmpdir(), 'agy-auth-test-'));
  try {
    // Write corrupt state.json first to verify graceful recovery
    writeFileSync(join(dir, 'state.json'), '{corrupt-json', 'utf-8');
    const auth = new AuthManager({ stateDir: dir });
    assert.ok(auth.state.machineId.startsWith('mach_'));

    // Reload from persisted state.json preserves machineId & signingSecret
    const authReloaded = new AuthManager({ stateDir: dir });
    assert.equal(authReloaded.state.machineId, auth.state.machineId);

    // Expired pairing auto-rotates on getPairingInfo()
    const oldPin = auth.pairing.pin;
    auth.pairing.expiresAt = Date.now() - 1000;
    const rotated = auth.getPairingInfo();
    assert.ok(rotated.expiresAt > Date.now());
    assert.notEqual(rotated.token, '');

    // Reject wrong PIN/token
    assert.equal(auth.pairDevice({ pin: '000000' }).ok, false);

    // Pair with formatted PIN ("123 456")
    const pinWithSpace = `${rotated.pin.slice(0, 3)} ${rotated.pin.slice(3)}`;
    const paired1 = auth.pairDevice({ pin: pinWithSpace, deviceName: 'Pixel 9', platform: 'android' });
    assert.equal(paired1.ok, true);

    // Replay of same PIN must fail because rotatePairing() ran
    assert.equal(auth.pairDevice({ pin: rotated.pin }).ok, false);

    // Pair second device via QR token
    const nextPairing = auth.getPairingInfo();
    const paired2 = auth.pairDevice({ token: nextPairing.token, deviceName: 'iPhone', platform: 'ios' });
    assert.equal(paired2.ok, true);
    assert.equal(auth.listDevices().length, 2);

    // Verify device token & reject tampered tokens
    assert.equal(auth.verifyDeviceToken(paired1.deviceToken).name, 'Pixel 9');
    assert.equal(auth.verifyDeviceToken('bad-token'), null);
    assert.equal(auth.verifyDeviceToken('dev_missing.123.sig'), null);
    assert.equal(auth.verifyDeviceToken(`${paired1.deviceToken}x`), null);
    const [devId, issued] = paired1.deviceToken.split('.');
    assert.equal(auth.verifyDeviceToken(`${devId}.${issued}.${'a'.repeat(43)}`), null);

    // IPC secret & device revocation & runtime discovery
    assert.equal(auth.verifyIpcSecret(auth.state.ipcSecret), true);
    assert.equal(auth.verifyIpcSecret('wrong'), false);
    assert.equal(auth.revokeDevice('dev_unknown'), false);
    assert.equal(auth.revokeDevice(paired1.deviceId), true);
    assert.equal(auth.verifyDeviceToken(paired1.deviceToken), null);

    const updated = auth.updateSettings({ approvalMode: 'auto-safe' });
    assert.equal(updated.approvalMode, 'auto-safe');

    auth.writeRuntimeDiscovery(7443, { custom: true });
    assert.equal(existsSync(runtimeDiscoveryPath(dir)), true);
    auth.clearRuntimeDiscovery();
    assert.equal(existsSync(runtimeDiscoveryPath(dir)), false);

    assert.ok(Array.isArray(discoverLanAddresses()));
    void oldPin;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('ApprovalGate handles observe, auto-safe, session rules, deny, timeout, and history cap', async () => {
  let mode = 'observe';
  let mobileOnline = true;
  const gate = new ApprovalGate({
    getMode: () => mode,
    hasActiveMobileClients: () => mobileOnline,
    defaultTimeoutMs: 40,
  });

  // 1. Observe mode never blocks
  const obs = await gate.evaluateHook({ toolCall: { name: 'write_file', args: { Path: '"/a.txt"' } } });
  assert.equal(obs.decision, 'ask');

  // 2. Auto-safe allows safe commands, holds unsafe commands
  mode = 'auto-safe';
  const safeRes = await gate.evaluateHook({
    conversationId: 'c1',
    toolCall: { name: 'run_command', args: { CommandLine: '"git status -sb"' } },
  });
  assert.equal(safeRes.decision, 'allow');

  // 3. Offline mobile falls back immediately to 'ask'
  mobileOnline = false;
  const offlineRes = await gate.evaluateHook({
    conversationId: 'c1',
    toolCall: { name: 'run_command', args: { CommandLine: '"rm -rf tmp"' } },
  });
  assert.equal(offlineRes.decision, 'ask');

  // 4. Online mobile: allow_session caches rule for subsequent calls!
  mobileOnline = true;
  mode = 'ask-mobile';
  let requestedItem = null;
  gate.once('approval_requested', (item) => {
    requestedItem = item;
  });

  const pendingAllow = gate.evaluateHook({
    conversationId: 'conv_sess',
    cwd: '/workspace',
    toolCall: { name: 'edit_file', args: { Path: '"/workspace/app.js"' } },
  });
  await new Promise((r) => setImmediate(r));
  assert.ok(requestedItem);
  assert.equal(gate.listPending().length, 1);

  const decRes = gate.decide({ id: requestedItem.id, decision: 'allow_session', byDevice: 'Pixel' });
  assert.equal(decRes.ok, true);
  assert.equal((await pendingAllow).decision, 'allow');

  // Second call to same conversationId + toolName auto-allows via session rule!
  const cachedRes = await gate.evaluateHook({
    conversationId: 'conv_sess',
    toolCall: { name: 'edit_file', args: { Path: '"/workspace/other.js"' } },
  });
  assert.equal(cachedRes.decision, 'allow');
  assert.match(cachedRes.reason, /session rule/i);

  // 5. Deny flow
  let denyItem = null;
  gate.once('approval_requested', (item) => {
    denyItem = item;
  });
  const pendingDeny = gate.evaluateHook({
    conversationId: 'conv_2',
    toolCall: { name: 'run_command', args: { CommandLine: '"curl http://example.com"' } },
  });
  await new Promise((r) => setImmediate(r));
  gate.decide({ id: denyItem.id, decision: 'deny' });
  assert.equal((await pendingDeny).decision, 'deny');

  // 6. Timeout fallback -> 'ask'
  const timedOut = await gate.evaluateHook(
    { conversationId: 'conv_3', toolCall: { name: 'write_file', args: {} } },
    25,
  );
  assert.equal(timedOut.decision, 'ask');

  // 7. Unknown ID & history cap at 100
  assert.equal(gate.decide({ id: 'apr_missing', decision: 'allow' }).ok, false);
  for (let i = 0; i < 110; i++) {
    gate._recordHistory({ toolName: 't', decision: 'allow' });
  }
  assert.equal(gate.history.length, 100);
  assert.equal(gate.listHistory(5).length, 5);
});

test('BrainWatcher parses transcripts, statuses, step deltas, and blocks artifact path traversal', async () => {
  const root = mkdtempSync(join(tmpdir(), 'agy-brain-test-'));
  const brainDir = join(root, 'antigravity', 'brain');
  const convWorking = '11111111-2222-3333-4444-555555555555';
  const convError = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  try {
    const dirW = join(brainDir, convWorking, '.system_generated', 'logs');
    const dirE = join(brainDir, convError, '.system_generated', 'logs');
    mkdirSync(dirW, { recursive: true });
    mkdirSync(dirE, { recursive: true });
    mkdirSync(join(brainDir, 'invalid..name'), { recursive: true });

    const txW = join(dirW, 'transcript.jsonl');
    writeFileSync(
      txW,
      [
        '{corrupt json line that must be skipped',
        JSON.stringify({
          step_index: 0,
          type: 'USER_INPUT',
          content: '<USER_REQUEST>Проверь архитектуру</USER_REQUEST>',
        }),
        JSON.stringify({
          step_index: 1,
          type: 'PLANNER_RESPONSE',
          thinking: 'Читаю файлы',
          content: '',
          tool_calls: [{ name: 'read_file', args: { Path: '"/Users/dev/proj/src/app.ts"' } }],
        }),
        JSON.stringify({
          step_index: 2,
          type: 'TOOL_OUTPUT',
          content: 'file contents',
        }),
      ].join('\n') + '\n',
    );
    writeFileSync(join(brainDir, convWorking, 'report.md'), '# Отчёт\nВсё чисто');
    writeFileSync(join(brainDir, convWorking, '.hidden.md'), 'secret');

    const txE = join(dirE, 'transcript.jsonl');
    writeFileSync(
      txE,
      JSON.stringify({ step_index: 0, type: 'PLANNER_RESPONSE', status: 'ERROR', content: 'Boom' }) + '\n',
    );

    const watcher = new BrainWatcher({ brainRoots: [brainDir], pollIntervalMs: 5000 });
    watcher.start();
    const sessions = watcher.listSessions();
    assert.equal(sessions.length, 2);

    const sWork = sessions.find((s) => s.id === convWorking);
    const sErr = sessions.find((s) => s.id === convError);
    assert.equal(sWork.status, 'working');
    assert.equal(sWork.title, 'Проверь архитектуру');
    assert.equal(sWork.artifactCount, 1);
    assert.equal(sErr.status, 'error');

    // Append final assistant reply -> emits steps_delta and transitions to 'idle'
    const deltas = [];
    watcher.on('steps_delta', (d) => deltas.push(d));
    const future = new Date(Date.now() + 2000);
    writeFileSync(
      txW,
      [
        JSON.stringify({ step_index: 0, type: 'USER_INPUT', content: '<USER_REQUEST>Проверь архитектуру</USER_REQUEST>' }),
        JSON.stringify({ step_index: 1, type: 'PLANNER_RESPONSE', content: 'Готово!' }),
      ].join('\n') + '\n',
    );
    utimesSync(txW, future, future);
    watcher.scanNow(true);

    assert.equal(deltas.length, 1);
    assert.equal(watcher.getSessionDetail(convWorking).summary.status, 'idle');
    assert.equal(watcher.getSessionDetail('bad/id'), null);

    // Safe artifact read vs traversal / hidden rejections
    assert.equal(watcher.getArtifactContent(convWorking, 'report.md').content, '# Отчёт\nВсё чисто');
    assert.equal(watcher.getArtifactContent(convWorking, '../secret.md'), null);
    assert.equal(watcher.getArtifactContent(convWorking, '.hidden.md'), null);
    assert.equal(watcher.getArtifactContent(convWorking, 'missing.md'), null);
    watcher.stop();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('AgentDriver covers mock agentapi, queue fallback, Git status/diff, traversal guard, and command runner', async () => {
  const ws = mkdtempSync(join(tmpdir(), 'agy-driver-ws-'));
  const prevLs = process.env.ANTIGRAVITY_LS_ADDRESS;

  try {
    // 1. Validation & Fallback Queue (when ANTIGRAVITY_LS_ADDRESS is unset)
    delete process.env.ANTIGRAVITY_LS_ADDRESS;
    const driver = new AgentDriver({ defaultWorkspace: ws, agentApiPath: '/nonexistent/agentapi' });
    await assert.rejects(() => driver.sendMessage('', 'hi'), /required/);
    await assert.rejects(() => driver.createConversation('   '), /required/);
    await assert.rejects(() => driver.runQuickCommand('   '), /Empty command/);

    const queuedSend = await driver.sendMessage('conv_q', 'Продолжай');
    assert.equal(queuedSend.delivery, 'queued');
    assert.equal(driver.consumeQueuedMessages('conv_q').length, 1);
    assert.equal(driver.consumeQueuedMessages('conv_q').length, 0);

    const queuedNew = await driver.createConversation('Новая задача');
    assert.equal(queuedNew.delivery, 'queued');
    assert.equal(driver.consumeQueuedMessages('__new__').length, 1);

    // 2. Delegated executor hook
    driver.delegatedExecutor = async (req) => ({ ok: true, delegated: req });
    const delRes = await driver.sendMessage('c1', 'hello');
    assert.equal(delRes.delegated.action, 'send-message');
    driver.delegatedExecutor = null;

    // 3. Real mock agentapi script (including prompts starting with '-')
    const mockApi = join(ws, 'mock-agentapi.mjs');
    writeFileSync(
      mockApi,
      `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === '--help') { console.log('agentapi help'); process.exit(0); }
if (args[0] === 'send-message') { console.log('SENT:' + args[1] + ':' + args[2]); process.exit(0); }
if (args[0] === 'new-conversation') {
  const prompt = args[1] === '--' ? args[2] : args[1];
  console.log('Created 12345678-1234-1234-1234-123456789abc for ' + prompt);
  process.exit(0);
}
`,
      'utf-8',
    );
    chmodSync(mockApi, 0o755);
    process.env.ANTIGRAVITY_LS_ADDRESS = '127.0.0.1:45678';

    const apiDriver = new AgentDriver({ defaultWorkspace: ws, agentApiPath: mockApi });
    assert.equal(await apiDriver.hasAgentApi(), true);
    const sent = await apiDriver.sendMessage('conv_live', 'Test msg');
    assert.equal(sent.delivery, 'agentapi');
    assert.match(sent.output, /SENT:conv_live:Test msg/);

    const createdDash = await apiDriver.createConversation('-flag-like prompt');
    assert.equal(createdDash.delivery, 'agentapi');
    assert.equal(createdDash.conversationId, '12345678-1234-1234-1234-123456789abc');
    assert.match(createdDash.output, /-flag-like prompt/);

    // 4. Non-git folder vs initialized Git repo status & diffs
    const nonGit = mkdtempSync(join(tmpdir(), 'agy-nongit-'));
    try {
      const stNonGit = await apiDriver.getWorkspaceStatus(nonGit);
      assert.equal(stNonGit.isGitRepo, false);
    } finally {
      rmSync(nonGit, { recursive: true, force: true });
    }

    execFileSync('git', ['init', '-b', 'main'], { cwd: ws });
    execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: ws });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: ws });
    writeFileSync(join(ws, 'tracked.txt'), 'line1\n', 'utf-8');
    execFileSync('git', ['add', 'tracked.txt'], { cwd: ws });
    execFileSync('git', ['commit', '-m', 'init'], { cwd: ws });

    writeFileSync(join(ws, 'tracked.txt'), 'line1\nline2\n', 'utf-8');
    writeFileSync(join(ws, 'untracked.txt'), 'fresh file\n', 'utf-8');

    const gitSt = await apiDriver.getWorkspaceStatus();
    assert.equal(gitSt.isGitRepo, true);
    assert.equal(gitSt.branch, 'main');
    assert.ok(gitSt.files.some((f) => f.path === 'tracked.txt'));
    assert.ok(gitSt.files.some((f) => f.path === 'untracked.txt'));

    const trackedDiff = await apiDriver.getFileDiff('tracked.txt');
    assert.match(trackedDiff.diff, /\+line2/);

    const untrackedDiff = await apiDriver.getFileDiff('untracked.txt');
    assert.match(untrackedDiff.diff, /\+fresh file/);

    await assert.rejects(() => apiDriver.getFileDiff('../outside.txt'), /outside workspace/);

    // 5. Quick terminal command: success, non-zero exit, timeout, and >64KB truncation
    const okCmd = await apiDriver.runQuickCommand('echo "hello-agy"');
    assert.equal(okCmd.ok, true);
    assert.equal(okCmd.output, 'hello-agy');

    const failCmd = await apiDriver.runQuickCommand('exit 3');
    assert.equal(failCmd.ok, false);
    assert.equal(failCmd.exitCode, 3);

    const timeoutCmd = await apiDriver.runQuickCommand('sleep 5', ws, 80);
    assert.equal(timeoutCmd.ok, false);
    assert.equal(timeoutCmd.timedOut, true);

    const hugeCmd = await apiDriver.runQuickCommand(`"${process.execPath}" -e "process.stdout.write('X'.repeat(80000))"`);
    assert.match(hugeCmd.output, /\[output truncated\]/);
  } finally {
    if (prevLs === undefined) delete process.env.ANTIGRAVITY_LS_ADDRESS;
    else process.env.ANTIGRAVITY_LS_ADDRESS = prevLs;
    rmSync(ws, { recursive: true, force: true });
  }
});

test('http-helpers, dispatchClientRpc, gatekeeper, CloudflareConnector, and startOrAttachBridge work cleanly', async () => {
  // 1. HTTP helpers
  const headers = {};
  let statusWritten = 0;
  let bodyWritten = '';
  const mockRes = {
    setHeader: (k, v) => {
      headers[k] = v;
    },
    writeHead: (code, h) => {
      statusWritten = code;
      Object.assign(headers, h);
      return mockRes;
    },
    end: (b = '') => {
      bodyWritten = Buffer.isBuffer(b) ? b.toString('utf-8') : String(b);
    },
  };
  applyCorsHeaders(mockRes);
  assert.equal(headers['Access-Control-Allow-Origin'], '*');

  assert.equal(
    extractBearerToken({ headers: { authorization: 'Bearer tok_1' } }, new URL('http://x/api')),
    'tok_1',
  );
  assert.equal(
    extractBearerToken({ headers: {} }, new URL('http://x/api?token=tok_q')),
    'tok_q',
  );

  // readJsonBody limits & validation
  const makeReq = (payload) => {
    const s = new PassThrough();
    s.end(payload);
    return s;
  };
  assert.deepEqual(await readJsonBody(makeReq('')), {});
  assert.deepEqual(await readJsonBody(makeReq('{"a":1}')), { a: 1 });
  await assert.rejects(() => readJsonBody(makeReq('[1,2]')), /must be an object/);
  await assert.rejects(() => readJsonBody(makeReq('{bad')), /Invalid JSON/);
  await assert.rejects(() => readJsonBody(makeReq('{"x":"' + 'a'.repeat(200) + '"}'), 32), /Payload too large/);

  // serveStaticAsset path traversal protection
  const assetDir = mkdtempSync(join(tmpdir(), 'agy-assets-'));
  try {
    writeFileSync(join(assetDir, 'index.html'), '<h1>PWA</h1>');
    serveStaticAsset(mockRes, assetDir, 'index.html', 'text/html');
    assert.equal(statusWritten, 200);
    assert.equal(bodyWritten, '<h1>PWA</h1>');

    serveStaticAsset(mockRes, assetDir, '../etc/passwd', 'text/plain');
    assert.equal(statusWritten, 403);

    serveStaticAsset(mockRes, assetDir, 'missing.js', 'text/javascript');
    assert.equal(statusWritten, 404);
  } finally {
    rmSync(assetDir, { recursive: true, force: true });
  }

  // 2. dispatchClientRpc all routes + error & unsupported branches
  const replies = [];
  const broadcasted = [];
  let statusChangedCount = 0;
  const mockServices = {
    brain: {
      listSessions: () => [{ id: 's1' }],
      getSessionDetail: (id) => ({ id }),
      getArtifactContent: (_id, name) => ({ fileName: name, content: 'ok' }),
      scanNow: () => {},
    },
    driver: {
      sendMessage: async (_id, prompt) => ({ ok: true, echoed: prompt }),
      createConversation: async (prompt) => ({ ok: true, conversationId: 'new_1', prompt }),
      getWorkspaceStatus: async () => ({ ok: true, branch: 'main', files: [] }),
      getFileDiff: async (path) => ({ ok: true, path, diff: '+ok' }),
      runQuickCommand: async (cmd) => ({ ok: true, exitCode: 0, output: cmd }),
    },
    approvals: {
      decide: ({ id, decision }) => ({ ok: true, id, decision }),
    },
    auth: {
      updateSettings: (patch) => ({ ...patch }),
    },
    broadcast: (e) => broadcasted.push(e),
    onStatusChanged: () => {
      statusChangedCount++;
    },
  };

  for (const rpc of [
    { type: 'client.ping', reqId: 'r1', payload: {} },
    { type: 'sessions.list', reqId: 'r2', payload: {} },
    { type: 'session.detail', reqId: 'r3', payload: { conversationId: 's1' } },
    { type: 'session.artifact', reqId: 'r4', payload: { conversationId: 's1', fileName: 'a.md' } },
    { type: 'chat.send', reqId: 'r5', payload: { conversationId: 's1', prompt: 'hi' } },
    { type: 'chat.new', reqId: 'r6', payload: { prompt: 'start' } },
    { type: 'approval.decide', reqId: 'r7', payload: { id: 'apr_1', decision: 'allow' } },
    { type: 'settings.set', reqId: 'r8', payload: { approvalMode: 'auto-safe' } },
    { type: 'workspace.status', reqId: 'r9', payload: {} },
    { type: 'workspace.diff', reqId: 'r10', payload: { path: 'a.js' } },
    { type: 'terminal.exec', reqId: 'r11', payload: { command: 'ls' } },
  ]) {
    await dispatchClientRpc(rpc, { deviceName: 'Test', reply: (e) => replies.push(e) }, mockServices);
  }
  assert.equal(broadcasted.length, 1);
  assert.equal(statusChangedCount, 1);

  replies.length = 0;
  await dispatchClientRpc(
    { type: 'unknown.method', reqId: 'r_unknown', payload: {} },
    { deviceName: 'Test', reply: (e) => replies.push(e) },
    {},
  );
  assert.equal(replies[0].type, 'error');
  assert.match(replies[0].payload.message, /Unsupported RPC type/);

  await dispatchClientRpc(
    { type: 'chat.send', reqId: 'r_err', payload: {} },
    { deviceName: 'Test', reply: (e) => replies.push(e) },
    {
      driver: {
        sendMessage: async () => {
          throw new Error('driver exploded');
        },
      },
    },
  );
  assert.equal(replies[1].type, 'error');
  assert.equal(replies[1].payload.message, 'driver exploded');

  void sendJson;

  // 3. gatekeeper.mjs unit tests
  const stdinStream = new PassThrough();
  stdinStream.end('{"toolCall":{"name":"run_command"}}');
  assert.equal(await readStdin(stdinStream), '{"toolCall":{"name":"run_command"}}');

  const errStream = new EventEmitter();
  setImmediate(() => errStream.emit('error', new Error('broken pipe')));
  assert.equal(await readStdin(errStream), '');

  const gkDir = mkdtempSync(join(tmpdir(), 'agy-gk-'));
  try {
    const rtFile = join(gkDir, 'bridge-runtime.json');
    assert.deepEqual(await evaluateGatekeeperPayload('{bad', { runtimeFile: rtFile }), { decision: 'ask' });
    assert.deepEqual(await evaluateGatekeeperPayload('[1,2]', { runtimeFile: rtFile }), { decision: 'ask' });
    assert.deepEqual(await evaluateGatekeeperPayload('{}', { runtimeFile: rtFile }), { decision: 'ask' });

    writeFileSync(rtFile, '{"port":0}', 'utf-8');
    assert.deepEqual(await evaluateGatekeeperPayload('{}', { runtimeFile: rtFile }), { decision: 'ask' });

    writeFileSync(rtFile, JSON.stringify({ port: 7443, ipcSecret: 'sec_1' }), 'utf-8');
    const allowRes = await evaluateGatekeeperPayload('{"toolCall":{"name":"edit_file"}}', {
      runtimeFile: rtFile,
      fetchImpl: async () => ({ ok: true, json: async () => ({ decision: 'allow', reason: 'ok' }) }),
    });
    assert.equal(allowRes.decision, 'allow');

    const invalidDecRes = await evaluateGatekeeperPayload('{}', {
      runtimeFile: rtFile,
      fetchImpl: async () => ({ ok: true, json: async () => ({ decision: 'evil_value' }) }),
    });
    assert.deepEqual(invalidDecRes, { decision: 'ask' });

    const http500Res = await evaluateGatekeeperPayload('{}', {
      runtimeFile: rtFile,
      fetchImpl: async () => ({ ok: false, status: 500 }),
    });
    assert.deepEqual(http500Res, { decision: 'ask' });
  } finally {
    rmSync(gkDir, { recursive: true, force: true });
  }

  // 4. CloudflareConnector with mocked global WebSocket
  const origWs = globalThis.WebSocket;
  try {
    const sentFrames = [];
    let activeMockWs = null;
    globalThis.WebSocket = class MockWs {
      constructor(url) {
        this.url = url;
        this.listeners = {};
        activeMockWs = this;
      }
      addEventListener(ev, fn) {
        (this.listeners[ev] ||= []).push(fn);
      }
      send(data) {
        sentFrames.push(JSON.parse(data));
      }
      close() {}
      emit(ev, payload) {
        for (const fn of this.listeners[ev] || []) fn(payload);
      }
    };

    const cf = new CloudflareConnector();
    cf.configure({ mode: 'edge-worker', edgeUrl: '', machineId: 'm1', machineName: 'Mac', localPort: 7443 });
    assert.equal(cf.status, 'error');

    const forwarded = [];
    cf.on('edge_message', (env) => forwarded.push(env));
    cf.configure({
      mode: 'edge-worker',
      edgeUrl: 'https://edge.example.workers.dev/',
      edgeSecret: 's1',
      machineId: 'm1',
      machineName: 'Mac',
      localPort: 7443,
      getInitialSnapshot: () => ({ sessions: [] }),
    });
    activeMockWs.emit('open', {});
    assert.equal(cf.status, 'connected');
    assert.equal(sentFrames[0].type, 'host.snapshot');

    activeMockWs.emit('message', {
      data: JSON.stringify({ v: 'arp.v1', type: 'edge.presence', payload: { mobileCount: 2 } }),
    });
    assert.equal(cf.hasConnectedEdgeMobiles(), true);

    activeMockWs.emit('message', {
      data: JSON.stringify({ v: 'arp.v1', type: 'sessions.list', reqId: 'r1', payload: {} }),
    });
    assert.equal(forwarded.length, 1);
    cf.stop();
    assert.equal(cf.status, 'disconnected');
  } finally {
    globalThis.WebSocket = origWs;
  }

  // 5. startOrAttachBridge singleton attach + stale discovery recovery
  const attachDir = mkdtempSync(join(tmpdir(), 'agy-attach-'));
  writeFileSync(runtimeDiscoveryPath(attachDir), '{"port":65530,"ipcSecret":"stale"}', 'utf-8');
  let hosted = null;
  try {
    hosted = await startOrAttachBridge({ port: 0, stateDir: attachDir });
    assert.equal(hosted.mode, 'hosted');

    const attached = await startOrAttachBridge({ port: hosted.server.port, stateDir: attachDir });
    assert.equal(attached.mode, 'attached');
    assert.equal(attached.server, null);

    const rotated = await attached.client.rotatePin();
    assert.equal(rotated.ok, true);
    const updated = await attached.client.updateSettings({ approvalMode: 'observe' });
    assert.equal(updated.settings.approvalMode, 'observe');
  } finally {
    if (hosted?.server) await hosted.server.stop();
    rmSync(attachDir, { recursive: true, force: true });
  }
});

test('ChangeTracker stages workspace edits non-blockingly, blocks external writes, and supports Save All & Revert', async () => {
  const wsDir = mkdtempSync(join(tmpdir(), 'agy-changes-ws-'));
  const extDir = mkdtempSync(join(tmpdir(), 'agy-changes-ext-'));
  const tracker = new ChangeTracker();

  try {
    const existingFile = join(wsDir, 'src', 'app.js');
    mkdirSync(join(wsDir, 'src'), { recursive: true });
    writeFileSync(existingFile, 'const a = 1;\nconst b = 2;\n', 'utf-8');

    const gate = new ApprovalGate({
      getMode: () => 'auto-safe',
      hasActiveMobileClients: () => true,
      defaultTimeoutMs: 200,
      changeTracker: tracker,
      getDefaultWorkspace: () => wsDir,
    });

    // 1. Brain artifact write auto-allows without staging
    const artDecision = await gate.evaluateHook({
      conversationId: 'c1',
      cwd: wsDir,
      artifactDirectoryPath: join(wsDir, '.brain'),
      toolCall: { name: 'write_file', args: { Path: join(wsDir, '.brain', 'plan.md') } },
    });
    assert.equal(artDecision.decision, 'allow');
    assert.equal(tracker.listPending().length, 0);

    // 2. Workspace edit_file (MOD) + repeated edit preserves original baseline!
    const editPayload = {
      conversationId: 'c1',
      cwd: wsDir,
      workspacePaths: [wsDir],
      toolCall: { name: 'edit_file', args: { Path: existingFile } },
    };
    const modDecision = await gate.evaluateHook(editPayload);
    assert.equal(modDecision.decision, 'allow');
    writeFileSync(existingFile, 'const a = 10;\nconst b = 2;\n', 'utf-8');
    tracker.recordAfterWrite(editPayload, wsDir);

    // Second edit to the same file
    await gate.evaluateHook(editPayload);
    writeFileSync(existingFile, 'const a = 10;\nconst b = 20;\nconst c = 30;\n', 'utf-8');
    const modEntry = tracker.recordAfterWrite(editPayload, wsDir);
    assert.equal(modEntry.status, 'MOD');
    assert.equal(modEntry.path, 'src/app.js');
    assert.ok(modEntry.additions >= 2);

    // 3. Workspace write_file (NEW)
    const createdFile = join(wsDir, 'src', 'new-helper.js');
    const createPayload = {
      conversationId: 'c1',
      cwd: wsDir,
      workspacePaths: [wsDir],
      toolCall: { name: 'write_file', args: { Path: createdFile } },
    };
    assert.equal((await gate.evaluateHook(createPayload)).decision, 'allow');
    writeFileSync(createdFile, 'export const ok = true;\n', 'utf-8');
    const newEntry = tracker.recordAfterWrite(createPayload, wsDir);
    assert.equal(newEntry.status, 'NEW');
    assert.equal(tracker.listPending().length, 2);

    const diffRes = tracker.getPendingDiff('src/app.js');
    assert.equal(diffRes.ok, true);
    assert.match(diffRes.diff, /\+const c = 30;/);

    // 4. Revert single modified file -> restores exact V0 bytes; then Revert all -> deletes newly created file!
    const revOne = tracker.revertChanges({ paths: ['src/app.js'] });
    assert.equal(revOne.revertedCount, 1);
    assert.equal(readFileSync(existingFile, 'utf-8'), 'const a = 1;\nconst b = 2;\n');
    assert.equal(tracker.listPending().length, 1);

    const revAll = tracker.revertChanges({ all: true });
    assert.equal(revAll.revertedCount, 1);
    assert.equal(existsSync(createdFile), false);
    assert.equal(tracker.listPending().length, 0);

    // 5. Save All keeps disk changes and clears review queue
    await gate.evaluateHook(createPayload);
    writeFileSync(createdFile, 'export const saved = 42;\n', 'utf-8');
    tracker.recordAfterWrite(createPayload, wsDir);
    assert.equal(tracker.listPending().length, 1);

    const saved = tracker.saveChanges();
    assert.equal(saved.savedCount, 1);
    assert.equal(tracker.listPending().length, 0);
    assert.equal(existsSync(createdFile), true);

    // 6. External file outside workspace MUST still hold for mobile approval + decideBatch resolves all!
    const extTarget1 = join(extDir, 'outside1.txt');
    const extTarget2 = join(extDir, 'outside2.txt');
    const p1 = gate.evaluateHook({
      conversationId: 'c1',
      cwd: wsDir,
      workspacePaths: [wsDir],
      toolCall: { name: 'write_file', args: { Path: extTarget1 } },
    });
    const p2 = gate.evaluateHook({
      conversationId: 'c1',
      cwd: wsDir,
      workspacePaths: [wsDir],
      toolCall: { name: 'write_file', args: { Path: extTarget2 } },
    });
    await new Promise((r) => setImmediate(r));
    assert.equal(gate.listPending().length, 2);

    const batchRes = gate.decideBatch({ decision: 'allow', byDevice: 'Phone' });
    assert.equal(batchRes.count, 2);
    assert.equal((await p1).decision, 'allow');
    assert.equal((await p2).decision, 'allow');

    // 7. PostToolUse gatekeeper routing returns {}
    const rtFile = join(wsDir, 'rt.json');
    writeFileSync(rtFile, JSON.stringify({ port: 7443, ipcSecret: 'sec' }), 'utf-8');
    let hitEndpoint = '';
    const postOut = await evaluateGatekeeperPayload(
      JSON.stringify({ hookEventName: 'PostToolUse', toolCall: { name: 'write_file' } }),
      {
        runtimeFile: rtFile,
        fetchImpl: async (url) => {
          hitEndpoint = String(url);
          return { ok: true, json: async () => ({ ok: true }) };
        },
      },
    );
    assert.deepEqual(postOut, {});
    assert.match(hitEndpoint, /\/internal\/hook\/post-tool$/);

    // 8. computeUnifiedTextDiff deletion branch
    const delStats = computeUnifiedTextDiff('old.txt', 'a\nb', '', true, false);
    assert.equal(delStats.deletions, 2);
    assert.equal(delStats.additions, 0);
  } finally {
    tracker.clearTimers();
    rmSync(wsDir, { recursive: true, force: true });
    rmSync(extDir, { recursive: true, force: true });
  }
});

test('BrainWatcher hydrates middle-truncated plans from transcript_full.jsonl, filters tool_result noise, parses mobile SYSTEM_MESSAGEs, and reads large artifacts', () => {
  const brainDir = mkdtempSync(join(tmpdir(), 'agy-brain-full-'));
  try {
    const convId = 'aaaa1111-bbbb-2222-cccc-3333dddd4444';
    const convDir = join(brainDir, convId);
    const logsDir = join(convDir, '.system_generated', 'logs');
    mkdirSync(logsDir, { recursive: true });

    // Create a 400 KB Markdown plan artifact (> old 256 KB limit)
    const bigArtifactBody = '# Wave 4 Full Plan\n\n' + '- Detailed scene upgrade item\n'.repeat(14000);
    assert.ok(Buffer.byteLength(bigArtifactBody, 'utf-8') > 350 * 1024);
    const artifactPath = join(convDir, 'wave4_plan.md');
    writeFileSync(artifactPath, bigArtifactBody, 'utf-8');

    // Build a 32 KB assistant plan that is middle-truncated in transcript.jsonl (`truncated_fields: ["content", "thinking"]`)
    const fullPlanText =
      '## Начало огромного плана\n\n' +
      Array.from({ length: 120 }, (_, i) => `### Сцена ${i + 1}\nПодробное описание архитектуры и шейдеров сцены ${i + 1}.`).join('\n\n') +
      '\n\n## Финал плана';
    const compactPlanText =
      fullPlanText.slice(0, 900) + '\n...<truncated 30500 chars>...\n' + fullPlanText.slice(-600);

    const compactLines = [];
    const fullLines = [];

    // 0: Initial user prompt
    const u0 = JSON.stringify({
      step_index: 0,
      type: 'USER_INPUT',
      status: 'DONE',
      content: '<USER_REQUEST>составь огромный план на 120 сцен</USER_REQUEST>',
    });
    compactLines.push(u0);
    fullLines.push(u0);

    // 1..300: 300 GENERIC tool_result steps (previously evicted older chat history when slicing!)
    for (let i = 1; i <= 300; i++) {
      const tr = JSON.stringify({
        step_index: i,
        type: 'GENERIC',
        status: 'DONE',
        content: `tool output #${i}`,
      });
      compactLines.push(tr);
      fullLines.push(tr);
    }

    // 301: Truncated assistant plan + artifact write_file tool call
    compactLines.push(
      JSON.stringify({
        step_index: 301,
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        thinking: 'Начало мысли...<truncated 5000 chars>...конец',
        content: compactPlanText,
        truncated_fields: ['content', 'thinking'],
        tool_calls: [
          {
            name: 'write_file',
            args: {
              Path: JSON.stringify(artifactPath),
              ArtifactMetadata: { Summary: 'Wave 4 120-scene upgrade plan' },
            },
          },
        ],
      }),
    );
    fullLines.push(
      JSON.stringify({
        step_index: 301,
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        thinking: 'Полная мысль архитектора без единого пропуска на 6000 символов!',
        content: fullPlanText,
        tool_calls: [
          {
            name: 'write_file',
            args: {
              Path: JSON.stringify(artifactPath),
              ArtifactMetadata: { Summary: 'Wave 4 120-scene upgrade plan' },
            },
          },
        ],
      }),
    );

    // 302: Background task notification (must be ignored, NOT shown as user bubble)
    const bgSys = JSON.stringify({
      step_index: 302,
      type: 'SYSTEM_MESSAGE',
      status: 'DONE',
      content:
        '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-14T16:10:00Z sender=aaaa1111/task-1 content=Background check done\n</SYSTEM_MESSAGE>',
    });
    compactLines.push(bgSys);
    fullLines.push(bgSys);

    // 303: Mobile prompt injected via `agentapi send-message` (note step_index reset to 120 as happens across hub turns!)
    const mobileSys = JSON.stringify({
      step_index: 120,
      type: 'SYSTEM_MESSAGE',
      status: 'DONE',
      content:
        'The following is a <SYSTEM_MESSAGE> not actually sent by the user:\n<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-14T16:10:30Z sender=system content=отлично!!! делаем всё!!!!\n</SYSTEM_MESSAGE>',
    });
    compactLines.push(mobileSys);
    fullLines.push(mobileSys);

    writeFileSync(join(logsDir, 'transcript.jsonl'), compactLines.join('\n') + '\n', 'utf-8');
    writeFileSync(join(logsDir, 'transcript_full.jsonl'), fullLines.join('\n') + '\n', 'utf-8');

    const watcher = new BrainWatcher({ brainRoots: [brainDir] });
    watcher.scanNow(true);

    const detail = watcher.getSessionDetail(convId);
    assert.ok(detail);

    // Despite 300 tool_result steps, all 3 human/assistant chat turns remain intact in visibleSteps!
    assert.equal(detail.steps.length, 3);
    assert.equal(detail.steps[0].role, 'user');
    assert.equal(detail.steps[0].content, 'составь огромный план на 120 сцен');

    // Step 301 hydrated 100% of fullPlanText & thinking from transcript_full.jsonl without <truncated>!
    const planStep = detail.steps[1];
    assert.equal(planStep.stepIndex, 301);
    assert.equal(planStep.content, fullPlanText);
    assert.equal(planStep.content.includes('<truncated'), false);
    assert.match(planStep.content, /### Сцена 60/);
    assert.equal(planStep.thinking, 'Полная мысль архитектора без единого пропуска на 6000 символов!');
    assert.equal(planStep.toolCalls[0].artifactFileName, 'wave4_plan.md');
    assert.equal(planStep.toolCalls[0].artifactSummary, 'Wave 4 120-scene upgrade plan');

    // Mobile SYSTEM_MESSAGE parsed as role='user', source='mobile', with monotonic seq > planStep.seq!
    const mobileStep = detail.steps[2];
    assert.equal(mobileStep.role, 'user');
    assert.equal(mobileStep.source, 'mobile');
    assert.equal(mobileStep.content, 'отлично!!! делаем всё!!!!');
    assert.ok(mobileStep.seq > planStep.seq);

    // Large >350 KB artifact reads cleanly without truncation!
    const loadedArtifact = watcher.getArtifactContent(convId, 'wave4_plan.md');
    assert.ok(loadedArtifact);
    assert.equal(loadedArtifact.content.length, bigArtifactBody.length);
  } finally {
    rmSync(brainDir, { recursive: true, force: true });
  }
});

test('AgentDriver routes sendMessage to exact Antigravity IDE window host via registerHookContext and resolves projectId', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'agy-hostrouter-'));
  const prevLs = process.env.ANTIGRAVITY_LS_ADDRESS;
  const prevCsrf = process.env.ANTIGRAVITY_CSRF_TOKEN;
  const prevExe = process.env.ANTIGRAVITY_AGENTAPI_EXE;
  try {
    const logFile = join(tmp, 'invocations.jsonl');
    const mockAgyBin = join(tmp, 'agy');
    writeFileSync(
      mockAgyBin,
      `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(logFile)}, JSON.stringify({
  args,
  ls: process.env.ANTIGRAVITY_LS_ADDRESS || '',
  csrf: process.env.ANTIGRAVITY_CSRF_TOKEN || '',
  projectId: process.env.ANTIGRAVITY_PROJECT_ID || '',
}) + '\\n');
if (args[0] === 'agentapi' && args[1] === 'get-conversation-metadata') {
  // Only the IDE hub (127.0.0.1:61103) owns conv_ide; desktop app LS (127.0.0.1:50001) rejects!
  if (process.env.ANTIGRAVITY_LS_ADDRESS === '127.0.0.1:61103') {
    console.log(JSON.stringify({
      response: { conversationMetadata: { metadata: { projectId: 'proj_game_app' } } }
    }));
    process.exit(0);
  }
  console.error('unknown conversation on desktop LS');
  process.exit(1);
}
if (args[0] === 'agentapi' && args[1] === 'send-message') {
  if (process.env.ANTIGRAVITY_LS_ADDRESS !== '127.0.0.1:61103' || process.env.ANTIGRAVITY_CSRF_TOKEN !== 'csrf_ide_window') {
    console.error('wrong host LS!');
    process.exit(2);
  }
  console.log('DELIVERED_TO_IDE:' + args[2] + ':' + args[3]);
  process.exit(0);
}
process.exit(0);
`,
      'utf-8',
    );
    chmodSync(mockAgyBin, 0o755);

    // Simulate Sidecar running inside Antigravity.app (wrong LS 127.0.0.1:50001)
    process.env.ANTIGRAVITY_LS_ADDRESS = '127.0.0.1:50001';
    process.env.ANTIGRAVITY_CSRF_TOKEN = 'csrf_desktop_app';
    process.env.ANTIGRAVITY_AGENTAPI_EXE = mockAgyBin;

    const driver = new AgentDriver({ defaultWorkspace: tmp });

    // Register Antigravity IDE window (`127.0.0.1:61103`) via PreInvocation/PreToolUse hook context!
    driver.registerHookContext({
      conversationId: 'conv_ide',
      cwd: '/Users/dev/projects/game-app',
      workspacePaths: ['/Users/dev/projects/game-app'],
      __hostContext: {
        lsAddress: '127.0.0.1:61103',
        csrfToken: 'csrf_ide_window',
        agentApiExe: mockAgyBin,
        appName: 'antigravity-ide',
      },
    });

    const res = await driver.sendMessage('conv_ide', 'Запусти тесты и сборку');
    assert.equal(res.ok, true);
    assert.equal(res.delivery, 'agentapi');
    assert.equal(res.targetHost, 'antigravity-ide');
    assert.match(res.output, /DELIVERED_TO_IDE:conv_ide:Запусти тесты и сборку/);

    const calls = readFileSync(logFile, 'utf-8')
      .trim()
      .split('\n')
      .map((l) => JSON.parse(l));
    const sendCall = calls.find((c) => c.args[1] === 'send-message');
    assert.ok(sendCall);
    assert.equal(sendCall.ls, '127.0.0.1:61103');
    assert.equal(sendCall.csrf, 'csrf_ide_window');
    assert.equal(sendCall.projectId, 'proj_game_app');
  } finally {
    if (prevLs === undefined) delete process.env.ANTIGRAVITY_LS_ADDRESS;
    else process.env.ANTIGRAVITY_LS_ADDRESS = prevLs;
    if (prevCsrf === undefined) delete process.env.ANTIGRAVITY_CSRF_TOKEN;
    else process.env.ANTIGRAVITY_CSRF_TOKEN = prevCsrf;
    if (prevExe === undefined) delete process.env.ANTIGRAVITY_AGENTAPI_EXE;
    else process.env.ANTIGRAVITY_AGENTAPI_EXE = prevExe;
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('AgentDriver persists hosts across restarts, isolates parent env, prunes dead ECONNREFUSED hosts, and actively flushes queued messages on HostHeartbeat', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'agy-hostpersist-'));
  const stateDir = join(tmp, 'state');
  mkdirSync(stateDir, { recursive: true });
  const prevLs = process.env.ANTIGRAVITY_LS_ADDRESS;
  const prevPid = process.env.ANTIGRAVITY_PROJECT_ID;
  const prevCsrf = process.env.ANTIGRAVITY_CSRF_TOKEN;

  try {
    const logFile = join(tmp, 'calls.jsonl');
    const mockExe = join(tmp, 'agentapi');
    writeFileSync(
      mockExe,
      `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
const ls = process.env.ANTIGRAVITY_LS_ADDRESS || '';
const pid = process.env.ANTIGRAVITY_PROJECT_ID || '';
fs.appendFileSync(${JSON.stringify(logFile)}, JSON.stringify({ args, ls, pid, csrf: process.env.ANTIGRAVITY_CSRF_TOKEN || '' }) + '\\n');
if (ls === '127.0.0.1:59999') {
  console.error('dial tcp 127.0.0.1:59999: connect: connection refused');
  process.exit(1);
}
if (args[0] === 'send-message') {
  // Reject wrong parent projectId, succeed only when projectId is empty!
  if (pid === 'wrong_parent_project') {
    console.error('project mismatch');
    process.exit(2);
  }
  console.log('FLUSHED_OK:' + args[1] + ':' + args[2]);
  process.exit(0);
}
console.log('{}');
`,
      'utf-8',
    );
    chmodSync(mockExe, 0o755);

    delete process.env.ANTIGRAVITY_LS_ADDRESS;
    process.env.ANTIGRAVITY_PROJECT_ID = 'wrong_parent_project';
    process.env.ANTIGRAVITY_CSRF_TOKEN = 'leaked_parent_csrf';

    // 1. Register one dead host and one live host, then simulate Bridge daemon restart!
    const d1 = new AgentDriver({ defaultWorkspace: tmp, agentApiPath: mockExe, stateDir });
    d1.registerHookContext({
      conversationId: 'conv_persisted',
      cwd: '/Users/dev/remote-bridge',
      __hostContext: {
        lsAddress: '127.0.0.1:59999',
        csrfToken: 'dead_tok',
        agentApiExe: mockExe,
        appName: 'closed-ide',
      },
    });
    d1.registerHookContext({
      cwd: '/Users/dev/remote-bridge',
      __hostContext: {
        lsAddress: '127.0.0.1:60001',
        csrfToken: 'live_tok',
        agentApiExe: mockExe,
        projectId: 'wrong_parent_project',
        appName: 'antigravity-desktop',
      },
    });

    // Restart: create brand-new AgentDriver pointing at same stateDir
    const d2 = new AgentDriver({ defaultWorkspace: tmp, agentApiPath: mockExe, stateDir });
    assert.equal(d2.getRegisteredHostsSummary().count, 2);

    // Sending to conv_persisted tries dead 59999 (prunes it!), then tries 60001 (retries without wrong projectId and delivers!)
    const res = await d2.sendMessage('conv_persisted', 'Привет после рестарта Bridge!');
    assert.equal(res.ok, true);
    assert.equal(res.delivery, 'agentapi');
    assert.equal(res.targetHost, 'antigravity-desktop');
    assert.equal(d2.getRegisteredHostsSummary().count, 1);

    // 2. Active queue flush: queue message when zero hosts exist, then fire HostHeartbeat -> auto-delivers!
    const emptyState = join(tmp, 'empty-state');
    const d3 = new AgentDriver({ defaultWorkspace: tmp, agentApiPath: '/nonexistent/agentapi', stateDir: emptyState });
    const qRes = await d3.sendMessage('conv_idle', 'Сообщение из очереди без клика на ноутбуке');
    assert.equal(qRes.delivery, 'queued');
    assert.equal(d3.queuedMessages.get('conv_idle').length, 1);

    d3.agentApiPath = mockExe;
    const flushedEvents = [];
    d3.onQueueFlushed = (ev) => flushedEvents.push(ev);
    d3.registerHookContext({
      hookEventName: 'HostHeartbeat',
      __hostContext: {
        lsAddress: '127.0.0.1:60002',
        csrfToken: 'hb_tok',
        agentApiExe: mockExe,
        appName: 'antigravity-sidecar',
      },
    });

    // Wait briefly for async flushQueuedMessages() triggered by registerHookContext
    for (let i = 0; i < 30 && flushedEvents.length === 0; i++) {
      await new Promise((r) => setTimeout(r, 20));
    }
    assert.equal(flushedEvents.length, 1);
    assert.equal(flushedEvents[0].conversationId, 'conv_idle');
    assert.equal(flushedEvents[0].result.delivery, 'agentapi');
    assert.equal(d3.queuedMessages.has('conv_idle'), false);
  } finally {
    if (prevLs === undefined) delete process.env.ANTIGRAVITY_LS_ADDRESS;
    else process.env.ANTIGRAVITY_LS_ADDRESS = prevLs;
    if (prevPid === undefined) delete process.env.ANTIGRAVITY_PROJECT_ID;
    else process.env.ANTIGRAVITY_PROJECT_ID = prevPid;
    if (prevCsrf === undefined) delete process.env.ANTIGRAVITY_CSRF_TOKEN;
    else process.env.ANTIGRAVITY_CSRF_TOKEN = prevCsrf;
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('AgentDriver resolves cross-project metadata, strips ANTIGRAVITY_CONVERSATION_ID, skips NotFound trajectories, and ignores poisoned legacy projectIds', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'agy-crossproj-'));
  const stateDir = join(tmp, 'state');
  mkdirSync(stateDir, { recursive: true });
  const prevConv = process.env.ANTIGRAVITY_CONVERSATION_ID;
  const prevTraj = process.env.ANTIGRAVITY_TRAJECTORY_ID;
  const prevLs = process.env.ANTIGRAVITY_LS_ADDRESS;

  try {
    const mockExe = join(tmp, 'agentapi');
    const callsFile = join(tmp, 'calls.jsonl');
    writeFileSync(
      mockExe,
      `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
const ls = process.env.ANTIGRAVITY_LS_ADDRESS || '';
const pid = process.env.ANTIGRAVITY_PROJECT_ID || '';
const convEnv = process.env.ANTIGRAVITY_CONVERSATION_ID || '';
const trajEnv = process.env.ANTIGRAVITY_TRAJECTORY_ID || '';
fs.appendFileSync(${JSON.stringify(callsFile)}, JSON.stringify({ args, ls, pid, convEnv, trajEnv }) + '\\n');

if (args[0] === 'get-conversation-metadata') {
  const cid = args[1];
  if (ls === '127.0.0.1:60100' && cid === 'conv_cli_only') {
    console.log(JSON.stringify({ response: {}, error: 'rpc error: code = NotFound desc = trajectory not found: ' + cid }));
    process.exit(1);
  }
  console.log(JSON.stringify({
    response: {
      conversationMetadata: {
        metadata: {
          projectId: 'aaaa1111-2222-4333-8444-555555555555',
          workspaceUris: ['file:///Users/dev/projects/game-app']
        }
      }
    }
  }));
  process.exit(0);
}

if (args[0] === 'send-message') {
  if (convEnv || trajEnv) {
    console.log(JSON.stringify({ response: {}, error: 'rpc error: code = PermissionDenied desc = contaminated source conversation env' }));
    process.exit(1);
  }
  if (pid !== 'aaaa1111-2222-4333-8444-555555555555') {
    console.log(JSON.stringify({ response: {}, error: 'rpc error: code = PermissionDenied desc = source project_id "' + pid + '" does not match target project_id "aaaa1111-2222-4333-8444-555555555555"' }));
    process.exit(1);
  }
  console.log(JSON.stringify({ response: { sendMessage: { recipientId: args[1], content: args[2] } } }));
  process.exit(0);
}
`,
      'utf-8',
    );
    chmodSync(mockExe, 0o755);

    // Pre-seed legacy poisoned `projectIds` + `.gemini` internal sidecar cwd in hosts-runtime.json
    writeFileSync(
      join(stateDir, 'hosts-runtime.json'),
      JSON.stringify({
        updatedAt: Date.now(),
        hosts: [
          {
            lsAddress: '127.0.0.1:60100',
            csrfToken: 'desktop_csrf',
            agentApiExe: mockExe,
            projectId: 'bbbb2222-3333-4444-8555-666666666666',
            appName: 'antigravity',
            workspacePaths: ['/Users/dev/.gemini/config/plugins/antigravity-remote/sidecars/control-pane'],
            updatedAt: Date.now(),
          },
        ],
        conversations: {},
        projectIds: {
          'cccc3333-4444-4555-8666-777777777777': 'dddd4444-5555-4666-8777-888888888888',
        },
      }),
      'utf-8',
    );

    delete process.env.ANTIGRAVITY_LS_ADDRESS;
    process.env.ANTIGRAVITY_CONVERSATION_ID = 'eeee5555-6666-4777-8888-999999999999';
    process.env.ANTIGRAVITY_TRAJECTORY_ID = 'eeee5555-6666-4777-8888-999999999999';

    const driver = new AgentDriver({
      defaultWorkspace: tmp,
      agentApiPath: mockExe,
      agyPath: false,
      stateDir,
    });

    // Internal `.gemini/...` sidecar directory must NOT leak into listWorkspaces()
    const wsList = driver.listWorkspaces();
    assert.equal(wsList.some((w) => w.path.includes('/.gemini/')), false);

    // Cross-project sendMessage resolves `aaaa1111-...` via metadata and strips `ANTIGRAVITY_CONVERSATION_ID`!
    const sendRes = await driver.sendMessage('cccc3333-4444-4555-8666-777777777777', 'Запускай проверку');
    assert.equal(sendRes.ok, true);
    assert.equal(sendRes.delivery, 'agentapi');

    // Trajectory `conv_cli_only` returns NotFound in metadata -> must NOT falsely call send-message on 60100!
    const cliRes = await driver.sendMessage('conv_cli_only', 'проверка');
    assert.equal(cliRes.delivery, 'queued');
    const allCalls = readFileSync(callsFile, 'utf-8')
      .trim()
      .split('\n')
      .map((l) => JSON.parse(l));
    assert.equal(
      allCalls.some((c) => c.args[0] === 'send-message' && c.args[1] === 'conv_cli_only'),
      false,
    );
  } finally {
    if (prevConv === undefined) delete process.env.ANTIGRAVITY_CONVERSATION_ID;
    else process.env.ANTIGRAVITY_CONVERSATION_ID = prevConv;
    if (prevTraj === undefined) delete process.env.ANTIGRAVITY_TRAJECTORY_ID;
    else process.env.ANTIGRAVITY_TRAJECTORY_ID = prevTraj;
    if (prevLs === undefined) delete process.env.ANTIGRAVITY_LS_ADDRESS;
    else process.env.ANTIGRAVITY_LS_ADDRESS = prevLs;
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('BrainWatcher + chat.stop persist idle state, ignore orphan background task notices, age out frozen working sessions, and prune deleted sessions', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'agy-stop-latch-'));
  try {
    const brainRoot = join(tmp, 'antigravity', 'brain');
    const cidOrphan = '33333333-4444-4555-8666-777777777777';
    const cidFrozen = '11111111-2222-4333-8444-555555555555';
    const cidActive = '22222222-3333-4444-8555-666666666666';

    for (const cid of [cidOrphan, cidFrozen, cidActive]) {
      mkdirSync(join(brainRoot, cid, '.system_generated', 'logs'), { recursive: true });
    }

    // 1. Orphan background task notice (`SYSTEM_MESSAGE` with `finished with result:`) must be `idle` immediately
    const orphanTranscript = join(brainRoot, cidOrphan, '.system_generated', 'logs', 'transcript.jsonl');
    writeFileSync(
      orphanTranscript,
      [
        JSON.stringify({ step_index: 0, type: 'USER_INPUT', content: 'Тестовая фоновая задача' }),
        JSON.stringify({ step_index: 1, type: 'PLANNER_RESPONSE', content: 'Готово!' }),
        JSON.stringify({
          step_index: 2,
          type: 'SYSTEM_MESSAGE',
          content: 'Task id `bg_1` finished with result:\nSIGTERM',
        }),
      ].join('\n') + '\n',
      'utf-8',
    );

    // 2. Active session currently executing a tool (`status: 'working'`)
    const frozenTranscript = join(brainRoot, cidFrozen, '.system_generated', 'logs', 'transcript.jsonl');
    writeFileSync(
      frozenTranscript,
      [
        JSON.stringify({ step_index: 0, type: 'USER_INPUT', content: 'run build' }),
        JSON.stringify({
          step_index: 1,
          type: 'PLANNER_RESPONSE',
          content: '',
          tool_calls: [{ name: 'run_command', args: { CommandLine: 'npm test' } }],
        }),
      ].join('\n') + '\n',
      'utf-8',
    );

    const activeTranscript = join(brainRoot, cidActive, '.system_generated', 'logs', 'transcript.jsonl');
    writeFileSync(
      activeTranscript,
      [
        JSON.stringify({ step_index: 0, type: 'USER_INPUT', content: 'long task' }),
        JSON.stringify({
          step_index: 1,
          type: 'PLANNER_RESPONSE',
          content: '',
          tool_calls: [{ name: 'run_command', args: { CommandLine: 'npm run build' } }],
        }),
      ].join('\n') + '\n',
      'utf-8',
    );

    const brain = new BrainWatcher({ brainRoots: [brainRoot] });
    const initial = brain.listSessions();
    assert.equal(initial.find((s) => s.id === cidOrphan)?.status, 'idle');
    assert.equal(initial.find((s) => s.id === cidFrozen)?.status, 'working');
    assert.equal(initial.find((s) => s.id === cidActive)?.status, 'working');

    // 3. Frozen working session ages past 90s WITHOUT file size changing -> scanNow flips cached entry to `idle`!
    // Wait: backdate mtime FIRST while simulating cached mtime match so we hit the unchanged-file branch!
    const oldSec = (Date.now() - 95_000) / 1000;
    utimesSync(frozenTranscript, oldSec, oldSec);
    // First scan re-parses with old mtime -> idle; now test unchanged-file branch by forcing cached status='working'
    brain.scanNow(false);
    assert.equal(brain.listSessions().find((s) => s.id === cidFrozen)?.status, 'idle');
    brain._cache.get(cidFrozen).summary.status = 'working';
    const emittedUpdates = [];
    const emittedDeltas = [];
    brain.on('sessions_updated', (s) => emittedUpdates.push(s));
    brain.on('steps_delta', (d) => emittedDeltas.push(d));
    brain.scanNow(true);
    assert.equal(brain.listSessions().find((s) => s.id === cidFrozen)?.status, 'idle');
    assert.equal(emittedDeltas.some((d) => d.conversationId === cidFrozen && d.summary.status === 'idle'), true);
    assert.equal(emittedUpdates.length >= 1, true);

    // 4. `chat.stop` on `cidActive` immediately flips BrainWatcher + broadcasts `sessions.updated` with `idle`
    const approvals = new ApprovalGate({ getMode: () => 'ask-mobile', hasActiveMobileClients: () => true });
    const driver = new AgentDriver({ defaultWorkspace: tmp, agentApiPath: false, agyPath: false });
    const replies = [];
    const broadcasts = [];
    await dispatchClientRpc(
      { type: 'chat.stop', reqId: 'stop_1', payload: { conversationId: cidActive } },
      { deviceName: 'Mobile Client', reply: (e) => replies.push(e) },
      {
        brain,
        driver,
        approvals,
        changes: null,
        auth: null,
        broadcast: (e) => broadcasts.push(e),
        onStatusChanged: () => {},
      },
    );
    assert.equal(replies[0].type, 'chat.stop.result');
    assert.equal(brain.listSessions().find((s) => s.id === cidActive)?.status, 'idle');
    const updatedBroadcast = broadcasts.find((b) => b.type === 'sessions.updated');
    assert.ok(updatedBroadcast);
    assert.equal(updatedBroadcast.payload.sessions.find((s) => s.id === cidActive)?.status, 'idle');

    // Even if an aborted TOOL_OUTPUT step appends right after Stop, session MUST stay `idle`!
    writeFileSync(
      activeTranscript,
      readFileSync(activeTranscript, 'utf-8') +
        JSON.stringify({ step_index: 2, type: 'TOOL_OUTPUT', content: 'Aborted by user' }) +
        '\n',
      'utf-8',
    );
    brain.scanNow(true);
    assert.equal(brain.listSessions().find((s) => s.id === cidActive)?.status, 'idle');

    // When a brand-new USER_INPUT step arrives later, stop latch clears and status becomes `working`!
    writeFileSync(
      activeTranscript,
      readFileSync(activeTranscript, 'utf-8') +
        JSON.stringify({
          step_index: 3,
          type: 'USER_INPUT',
          created_at: new Date(Date.now() + 2000).toISOString(),
          content: 'новая задача',
        }) +
        '\n',
      'utf-8',
    );
    brain.scanNow(true);
    assert.equal(brain.listSessions().find((s) => s.id === cidActive)?.status, 'working');

    // 5. Deleting a brain directory prunes it from `listSessions()`
    rmSync(join(brainRoot, cidOrphan), { recursive: true, force: true });
    assert.equal(brain.listSessions().some((s) => s.id === cidOrphan), false);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
