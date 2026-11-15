import assert from 'node:assert/strict';
import test from 'node:test';

import {
  APPROVAL_MODES,
  DEFAULT_BRIDGE_PORT,
  PROTOCOL_VERSION,
  buildPairingUrl,
  cleanArgsObject,
  createEnvelope,
  extractRemoteSystemPrompt,
  extractUserPrompt,
  isSafeCommand,
  parseEnvelope,
  parsePairingInput,
  summarizeToolCall,
  unquoteArg,
} from '../packages/protocol/src/index.mjs';
import {
  createQrMatrix,
  renderQrSvg,
  renderQrTerminal,
} from '../packages/protocol/src/qr-svg.mjs';

test('Protocol constants expose ARP v1 defaults and approval modes', () => {
  assert.equal(PROTOCOL_VERSION, 'arp.v1');
  assert.equal(DEFAULT_BRIDGE_PORT, 7443);
  assert.deepEqual(APPROVAL_MODES, ['observe', 'ask-mobile', 'auto-safe']);
});

test('isSafeCommand allows read-only diagnostics and blocks shell chaining/newlines/subshells', () => {
  const safeList = [
    'git status',
    '  git diff HEAD~1 --stat ',
    'git log -n 5 --oneline',
    'git branch -a',
    'git show HEAD',
    'npm test',
    'pnpm run lint',
    'yarn run typecheck',
    'flutter analyze',
    'flutter test --coverage',
    'flutter --version',
    'flutter doctor -v',
    'node --test tests/protocol.test.mjs',
  ];
  for (const cmd of safeList) {
    assert.equal(isSafeCommand(cmd), true, `Expected safe: ${cmd}`);
  }

  const unsafeList = [
    '',
    '   ',
    null,
    undefined,
    'rm -rf /tmp/foo',
    'git push --force',
    'git checkout -f',
    'npm install malicious-pkg',
    'git status; rm -rf /',
    'git status && curl evil.example',
    'git status | sh',
    'git status `whoami`',
    'git status $(whoami)',
    'git status (whoami)',
    'git status > /tmp/pwn',
    'git status < /etc/passwd',
    'git status\nrm -rf /',
    'git status\r\nwhoami',
  ];
  for (const cmd of unsafeList) {
    assert.equal(isSafeCommand(cmd), false, `Expected unsafe: ${String(cmd)}`);
  }
});

test('createEnvelope and parseEnvelope handle valid, binary, and malformed inputs', () => {
  const env = createEnvelope('sessions.list', { limit: 10 }, 'req_42');
  assert.equal(env.v, 'arp.v1');
  assert.equal(env.type, 'sessions.list');
  assert.equal(env.reqId, 'req_42');
  assert.deepEqual(env.payload, { limit: 10 });
  assert.equal(typeof env.ts, 'number');

  // Array or primitive payloads normalize to empty object
  assert.deepEqual(createEnvelope('ping', ['bad']).payload, {});
  assert.deepEqual(createEnvelope('ping', null).payload, {});
  assert.equal('reqId' in createEnvelope('ping'), false);

  // Round-trip from string and Buffer
  const parsedStr = parseEnvelope(JSON.stringify(env));
  assert.equal(parsedStr.type, 'sessions.list');
  assert.equal(parsedStr.reqId, 'req_42');
  assert.deepEqual(parsedStr.payload, { limit: 10 });

  const parsedBuf = parseEnvelope(Buffer.from(JSON.stringify({ type: 'client.ping' }), 'utf-8'));
  assert.equal(parsedBuf.v, 'arp.v1');
  assert.equal(parsedBuf.type, 'client.ping');
  assert.deepEqual(parsedBuf.payload, {});
  assert.equal(parsedBuf.reqId, undefined);

  // Non-object payload inside valid envelope falls back to {}
  const arrayPayloadEnv = parseEnvelope('{"type":"x","payload":[1,2,3]}');
  assert.deepEqual(arrayPayloadEnv.payload, {});

  // Malformed inputs return null
  for (const bad of [null, undefined, '', '{broken', '[]', '123', '{}', '{"type":"   "}']) {
    assert.equal(parseEnvelope(bad), null);
  }
});

test('buildPairingUrl and parsePairingInput support URLs and JSON while rejecting unsafe schemes', () => {
  const url = buildPairingUrl({
    baseUrl: 'http://192.168.1.7:7443///',
    token: 'tok_abc',
    machineId: 'mach_01',
    machineName: 'MacBook-Pro',
    cloudflareUrl: 'https://edge.example.workers.dev///',
    sessionId: 'sess_01',
  });

  const parsed = parsePairingInput(url);
  assert.deepEqual(parsed, {
    baseUrl: 'http://192.168.1.7:7443',
    token: 'tok_abc',
    machineId: 'mach_01',
    machineName: 'MacBook-Pro',
    cloudflareUrl: 'https://edge.example.workers.dev',
    sessionId: 'sess_01',
  });

  // Minimal URL falls back machineName to hostname
  const minimal = parsePairingInput('https://agy.example.com/pair?t=t1');
  assert.equal(minimal.baseUrl, 'https://agy.example.com');
  assert.equal(minimal.machineName, 'agy.example.com');
  assert.equal(minimal.cloudflareUrl, '');

  // Raw JSON pairing input
  const fromJson = parsePairingInput(
    JSON.stringify({
      baseUrl: 'http://10.0.0.8:7443/extra',
      token: 'tok_json',
      machineId: 'mach_json',
      cloudflareUrl: 'https://cf.example.com/',
    }),
  );
  assert.deepEqual(fromJson, {
    baseUrl: 'http://10.0.0.8:7443',
    token: 'tok_json',
    machineId: 'mach_json',
    machineName: '10.0.0.8',
    cloudflareUrl: 'https://cf.example.com',
    sessionId: 'mach_json',
  });

  // Rejects empty, malformed, and dangerous schemes
  for (const invalid of [
    '',
    '   ',
    'not-a-url',
    'javascript:alert(1)',
    'file:///etc/passwd',
    'ftp://192.168.1.1/pair',
    '{bad json',
    '{"token":"missing-base"}',
    '{"baseUrl":"javascript:alert(1)"}',
  ]) {
    assert.equal(parsePairingInput(invalid), null, `Expected null for ${invalid}`);
  }
});

test('unquoteArg, cleanArgsObject, extractUserPrompt, and summarizeToolCall cover all branches', () => {
  assert.equal(unquoteArg('"/Users/dev/file.txt"'), '/Users/dev/file.txt');
  assert.equal(unquoteArg('"line1\\nline2"'), 'line1\nline2');
  assert.equal(unquoteArg('"\\q_bad_escape"'), '\\q_bad_escape');
  assert.equal(unquoteArg('plain'), 'plain');
  assert.equal(unquoteArg(42), 42);

  assert.deepEqual(cleanArgsObject(null), {});
  assert.deepEqual(cleanArgsObject(['a', 'b']), {});
  assert.deepEqual(
    cleanArgsObject({ Path: '"/tmp/demo.js"', Count: 3 }),
    { Path: '/tmp/demo.js', Count: 3 },
  );

  assert.equal(
    extractUserPrompt(
      '<ADDITIONAL_METADATA>meta</ADDITIONAL_METADATA>\n<USER_REQUEST>\n  Сделай рефакторинг \n</USER_REQUEST>',
    ),
    'Сделай рефакторинг',
  );
  assert.equal(
    extractUserPrompt(
      '<SYSTEM_MESSAGE>sys</SYSTEM_MESSAGE><USER_SETTINGS_CHANGE>cfg</USER_SETTINGS_CHANGE> Прямой текст ',
    ),
    'Прямой текст',
  );

  // extractRemoteSystemPrompt extracts agentapi send-message prompts even when preamble prose contains literal <SYSTEM_MESSAGE>
  const realRemoteMsg = `The following is a <SYSTEM_MESSAGE> not actually sent by the user:
<SYSTEM_MESSAGE>
[Message] timestamp=2026-11-14T16:10:30Z sender=system id=msg_99 content=Запусти сборку и тесты
</SYSTEM_MESSAGE>`;
  assert.equal(extractRemoteSystemPrompt(realRemoteMsg), 'Запусти сборку и тесты');

  // Background task / subagent notifications must NOT be mistaken for user prompts
  assert.equal(
    extractRemoteSystemPrompt(
      '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-14T16:11:00Z sender=aaaa1111/task-1 content=Command completed\n</SYSTEM_MESSAGE>',
    ),
    null,
  );
  assert.equal(
    extractRemoteSystemPrompt(
      '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-14T16:11:00Z sender=system content=Task id "task-2" finished\n</SYSTEM_MESSAGE>',
    ),
    null,
  );
  assert.equal(extractRemoteSystemPrompt(''), null);

  assert.equal(summarizeToolCall(null), 'Tool call');
  assert.equal(summarizeToolCall({ name: '  ' }), 'Tool call');
  assert.equal(
    summarizeToolCall({ name: 'run_command', args: { toolSummary: '"Unit test run"' } }),
    'Unit test run',
  );
  assert.equal(
    summarizeToolCall({ name: 'run_command', args: { CommandLine: '"git status -sb"' } }),
    '$ git status -sb',
  );
  assert.equal(summarizeToolCall({ name: 'run_command', args: {} }), 'Run command');
  assert.equal(
    summarizeToolCall({ name: 'read_file', args: { Path: '"/a/b/index.mjs"' } }),
    'Read index.mjs',
  );
  assert.equal(summarizeToolCall({ name: 'read_file', args: {} }), 'Read file');
  assert.equal(
    summarizeToolCall({ name: 'write_file', args: { TargetFile: '"C:\\\\proj\\\\app.ts"' } }),
    'Create app.ts',
  );
  assert.equal(summarizeToolCall({ name: 'write_file', args: {} }), 'Write file');
  assert.equal(
    summarizeToolCall({ name: 'edit_file', args: { AbsolutePath: '"/src/main.dart"' } }),
    'Edit main.dart',
  );
  assert.equal(summarizeToolCall({ name: 'edit_file', args: {} }), 'Edit file');
  assert.equal(
    summarizeToolCall({ name: 'search_web', args: { query: '"RFC 6455 masking"' } }),
    'Web: RFC 6455 masking',
  );
  assert.equal(summarizeToolCall({ name: 'search_web', args: {} }), 'Search web');
  assert.equal(summarizeToolCall({ name: 'ask_question', args: {} }), 'Ask user question');
  assert.equal(
    summarizeToolCall({ name: 'custom_tool', args: { Path: '"/dir/data.json"' } }),
    'custom_tool (data.json)',
  );
  assert.equal(summarizeToolCall({ name: 'custom_tool', args: {} }), 'custom_tool');
});

test('QR encoder generates ISO 18004 matrix, crisp SVG, and Unicode terminal output', () => {
  const matrix = createQrMatrix('http://192.168.1.7:7443/pair?t=abc123', 'M');
  assert.ok(matrix.size >= 21);
  assert.equal(matrix.rows.length, matrix.size);

  const svg = renderQrSvg('http://192.168.1.7:7443/pair?t=abc123', { sizePx: 180, margin: 2 });
  assert.ok(svg.startsWith('<svg '));
  assert.ok(svg.includes('width="180"'));
  assert.ok(svg.includes('<rect '));
  assert.ok(svg.includes('<path d="M'));

  const transparentSvg = renderQrSvg('hello', { light: 'transparent' });
  assert.equal(transparentSvg.includes('<rect '), false);

  const term = renderQrTerminal('http://192.168.1.7:7443/pair?t=abc');
  assert.ok(term.split('\n').length >= 10);
});
