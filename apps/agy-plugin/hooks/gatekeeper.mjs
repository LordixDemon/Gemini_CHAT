/**
 * Antigravity Lifecycle Hook (`gatekeeper.mjs`).
 * Handles:
 * - `PreToolUse` -> `/internal/hook/pre-tool` (mobile approval / workspace write staging)
 * - `PostToolUse` -> `/internal/hook/post-tool` (file diff capture for "Save All")
 * - `SessionStart` / `PreInvocation` / `Stop` -> `/internal/hook/lifecycle`
 *   (registers active Antigravity window host context so mobile `chat.send` routes
 *    directly to the exact open Antigravity IDE / Antigravity 2.0 conversation window,
 *    and drains queued mobile messages via `injectSteps` when needed).
 *
 * Safety invariant: If the Bridge is offline or times out, returns immediately with
 * `{ decision: 'ask' }` (for `PreToolUse`) or `{}` (for all other events).
 */
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const VALID_DECISIONS = new Set(['allow', 'deny', 'ask', 'force_ask']);

export function readStdin(stream = process.stdin) {
  return new Promise((resolvePromise) => {
    let buf = '';
    stream.setEncoding?.('utf-8');
    stream.on('data', (chunk) => {
      buf += chunk;
    });
    stream.on('end', () => resolvePromise(buf));
    stream.on('error', () => resolvePromise(''));
  });
}

function captureHostContext() {
  const lsAddress = process.env.ANTIGRAVITY_LS_ADDRESS || '';
  if (!lsAddress) return undefined;
  return {
    lsAddress,
    csrfToken: process.env.ANTIGRAVITY_CSRF_TOKEN || '',
    agentApiExe: process.env.ANTIGRAVITY_AGENTAPI_EXE || '',
    projectId: process.env.ANTIGRAVITY_PROJECT_ID || '',
    appName: process.env.ANTIGRAVITY_AUTH_SUCCESS_APP || '',
  };
}

/**
 * Evaluates a hook JSON string against the local Bridge IPC endpoint.
 * Pure & injectable for unit testing.
 * @param {string} rawStdin
 * @param {{ runtimeFile?: string, timeoutMs?: number, fetchImpl?: typeof fetch }} [opts]
 */
export async function evaluateGatekeeperPayload(rawStdin, opts = {}) {
  let hookPayload = {};
  try {
    hookPayload = rawStdin ? JSON.parse(rawStdin) : {};
    if (!hookPayload || typeof hookPayload !== 'object' || Array.isArray(hookPayload)) {
      return { decision: 'ask' };
    }
  } catch {
    return { decision: 'ask' };
  }

  const eventName = hookPayload.hookEventName || 'PreToolUse';
  const isPreTool = eventName === 'PreToolUse';
  const isPostTool = eventName === 'PostToolUse';
  const isStop = eventName === 'Stop';
  const fallback = isPreTool ? { decision: 'ask' } : isStop ? { decision: 'allow' } : {};

  const runtimeFile =
    opts.runtimeFile ||
    process.env.AGY_REMOTE_RUNTIME_FILE ||
    join(homedir(), '.gemini', 'antigravity-remote', 'bridge-runtime.json');

  if (!existsSync(runtimeFile)) {
    return fallback;
  }

  try {
    const disc = JSON.parse(readFileSync(runtimeFile, 'utf-8'));
    if (!disc?.port || !disc?.ipcSecret) {
      return fallback;
    }

    const defaultTimeout = isPreTool ? 54_000 : isPostTool ? 4_000 : 3_000;
    const timeoutMs = opts.timeoutMs ?? defaultTimeout;
    const fetchFn = opts.fetchImpl || fetch;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    const endpoint = isPreTool
      ? '/internal/hook/pre-tool'
      : isPostTool
        ? '/internal/hook/post-tool'
        : '/internal/hook/lifecycle';

    const hostContext = captureHostContext();
    const bodyPayload = hostContext ? { ...hookPayload, __hostContext: hostContext } : hookPayload;

    const res = await fetchFn(`http://127.0.0.1:${disc.port}${endpoint}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Bridge-Secret': disc.ipcSecret,
      },
      body: JSON.stringify(bodyPayload),
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (isPostTool) {
      return {};
    }
    if (!res.ok) {
      return fallback;
    }

    const respObj = await res.json();
    if (isPreTool) {
      return VALID_DECISIONS.has(respObj?.decision) ? respObj : { decision: 'ask' };
    }
    if (eventName === 'PreInvocation' && Array.isArray(respObj?.injectSteps) && respObj.injectSteps.length > 0) {
      return { injectSteps: respObj.injectSteps };
    }
    if (isStop) {
      return {
        decision: typeof respObj?.decision === 'string' && respObj.decision ? respObj.decision : 'allow',
      };
    }
    return {};
  } catch {
    return fallback;
  }
}

async function main() {
  const raw = await readStdin();
  const result = await evaluateGatekeeperPayload(raw);
  process.stdout.write(JSON.stringify(result) + '\n');
}

const isMain =
  process.argv[1] && resolve(fileURLToPath(import.meta.url)) === resolve(process.argv[1]);

if (isMain) {
  void main();
}
