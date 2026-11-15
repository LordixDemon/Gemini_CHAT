/**
 * Sanctioned Antigravity ACP (`agy acp`) Session Wakeup & Execution Runner.
 *
 * Used as Tier-2 direct executor whenever no live Language Server (`agentapi`) owns or can
 * reach an idle/cross-window conversation (for example after hours of MacBook sleep when IDE
 * windows rotated ephemeral ports, when `Antigravity.app` is closed, or for CLI trajectories).
 *
 * Speaks standard JSON-RPC 2.0 over stdio (`initialize`, `session/resume`, `session/load`,
 * `session/new`, `session/prompt`, `session/cancel`), writing directly to the conversation's
 * `~/.gemini/<surface>/brain/<conversationId>/.system_generated/logs/transcript.jsonl` while
 * preserving `gatekeeper.mjs` (`PreToolUse` / `PostToolUse` / `Stop`) mobile approvals.
 */
import { spawn } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DEFAULT_IDLE_TIMEOUT_MS = 90_000;
const PREFERRED_SURFACES = ['antigravity', 'antigravity-ide', 'antigravity-cli'];

function buildCleanAcpEnv(runtimeFile = '') {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined) continue;
    if (k.startsWith('ANTIGRAVITY_')) continue;
    if (k === 'AGY_ENABLE_HUB') continue;
    env[k] = v;
  }
  if (runtimeFile) {
    env.AGY_REMOTE_RUNTIME_FILE = runtimeFile;
  }
  return env;
}

function pickAllowOptionId(options) {
  if (!Array.isArray(options) || options.length === 0) return 'allow';
  const once = options.find((o) => {
    const id = String(o?.optionId || '').toLowerCase();
    const kind = String(o?.kind || '').toLowerCase();
    return id === 'allow_once' || id === 'allow' || kind === 'allow_once';
  });
  if (once?.optionId) return String(once.optionId);
  const anyAllow = options.find((o) => {
    const id = String(o?.optionId || '').toLowerCase();
    const kind = String(o?.kind || '').toLowerCase();
    return id.includes('allow') || kind.includes('allow');
  });
  if (anyAllow?.optionId) return String(anyAllow.optionId);
  return String(options[0]?.optionId || 'allow');
}

export class AcpSessionRunner {
  /** @type {Map<string, any>} */
  #workers = new Map();

  /**
   * @param {{
   *   agyPath?: string | false,
   *   geminiDir?: string,
   *   runtimeFile?: string,
   *   idleTimeoutMs?: number,
   *   isSessionStopped?: (sessionId: string) => boolean,
   *   onTurnActivity?: (sessionId: string) => void
   * }} [opts]
   */
  constructor(opts = {}) {
    this.agyPath = opts.agyPath;
    this.geminiDir = opts.geminiDir || join(homedir(), '.gemini');
    this.runtimeFile = opts.runtimeFile || '';
    this.idleTimeoutMs = opts.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS;
    this.isSessionStopped = opts.isSessionStopped || null;
    this.onTurnActivity = opts.onTurnActivity || null;
  }

  resolveAgyBinary() {
    if (this.agyPath === false) return null;
    if (typeof this.agyPath === 'string' && this.agyPath.trim()) {
      return existsSync(this.agyPath.trim()) ? this.agyPath.trim() : null;
    }
    const binExt = process.platform === 'win32' ? '.exe' : '';
    const stdAgy = join(this.geminiDir, 'bin', `agy${binExt}`);
    if (existsSync(stdAgy)) return stdAgy;
    const homeAgy = join(homedir(), '.gemini', 'bin', `agy${binExt}`);
    if (existsSync(homeAgy)) return homeAgy;
    return null;
  }

  detectAppDataDirName(conversationId = '') {
    if (conversationId && existsSync(this.geminiDir)) {
      for (const surface of PREFERRED_SURFACES) {
        if (existsSync(join(this.geminiDir, surface, 'brain', conversationId))) {
          return surface;
        }
      }
      try {
        for (const entry of readdirSync(this.geminiDir)) {
          if (existsSync(join(this.geminiDir, entry, 'brain', conversationId))) {
            return entry;
          }
        }
      } catch {}
    }
    return 'antigravity';
  }

  async _getOrStartWorker(appDataDirName, cwd) {
    const existing = this.#workers.get(appDataDirName);
    if (existing && !existing.closed) {
      if (existing.initPromise) {
        await existing.initPromise;
      }
      this._clearIdleTimer(existing);
      return existing;
    }

    const agyBin = this.resolveAgyBinary();
    if (!agyBin) {
      const err = new Error('agy binary not found for ACP session wakeup');
      err.code = 'ENOENT';
      throw err;
    }

    const args = ['acp', '--app-data-dir', appDataDirName];
    const defaultGeminiDir = join(homedir(), '.gemini');
    if (this.geminiDir && this.geminiDir !== defaultGeminiDir) {
      args.push('--gemini-dir', this.geminiDir);
    }

    const proc = spawn(agyBin, args, {
      cwd: cwd && existsSync(cwd) ? cwd : process.cwd(),
      env: buildCleanAcpEnv(this.runtimeFile),
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });

    const worker = {
      appDataDirName,
      proc,
      closed: false,
      nextId: 1,
      pending: new Map(), // idStr -> { resolve, reject, timer }
      loadedSessions: new Set(),
      promptChains: new Map(), // sessionId -> Promise
      inFlightPrompts: 0,
      idleTimer: null,
      stderrTail: '',
      initPromise: null,
    };

    let stdoutBuf = '';
    proc.stdout.setEncoding('utf-8');
    proc.stdout.on('data', (chunk) => {
      stdoutBuf += chunk;
      let nl;
      while ((nl = stdoutBuf.indexOf('\n')) !== -1) {
        const line = stdoutBuf.slice(0, nl).trim();
        stdoutBuf = stdoutBuf.slice(nl + 1);
        if (line) {
          this._handleWorkerLine(worker, line);
        }
      }
    });

    proc.stderr.setEncoding('utf-8');
    proc.stderr.on('data', (chunk) => {
      worker.stderrTail = (worker.stderrTail + chunk).slice(-2048);
    });

    const onExit = (errOrCode) => {
      if (worker.closed) return;
      worker.closed = true;
      this._clearIdleTimer(worker);
      if (this.#workers.get(appDataDirName) === worker) {
        this.#workers.delete(appDataDirName);
      }
      const reason =
        errOrCode instanceof Error
          ? errOrCode.message
          : `ACP worker exited (${errOrCode ?? 'closed'}): ${worker.stderrTail.trim()}`;
      for (const [, waiter] of worker.pending.entries()) {
        clearTimeout(waiter.timer);
        waiter.reject(new Error(reason));
      }
      worker.pending.clear();
    };

    proc.on('error', onExit);
    proc.on('close', onExit);

    this.#workers.set(appDataDirName, worker);

    worker.initPromise = this._rpc(
      worker,
      'initialize',
      {
        protocolVersion: 1,
        clientCapabilities: {},
        clientInfo: { name: 'antigravity-remote-bridge', version: '1.0.0' },
      },
      15_000,
    ).finally(() => {
      worker.initPromise = null;
    });

    await worker.initPromise;
    return worker;
  }

  _handleWorkerLine(worker, line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (!msg || typeof msg !== 'object') return;

    // 1. Response to a client->server RPC call
    if (msg.id !== undefined && msg.id !== null && !msg.method) {
      const key = String(msg.id);
      const waiter = worker.pending.get(key);
      if (!waiter) return;
      worker.pending.delete(key);
      clearTimeout(waiter.timer);
      if (msg.error) {
        const err = new Error(msg.error.message || JSON.stringify(msg.error));
        err.rpcCode = msg.error.code;
        waiter.reject(err);
      } else {
        waiter.resolve(msg.result);
      }
      return;
    }

    // 2. Server->client JSON-RPC request (e.g. `session/request_permission`)
    if (msg.id !== undefined && msg.id !== null && typeof msg.method === 'string') {
      if (msg.method === 'session/request_permission') {
        const sessionId = String(msg.params?.sessionId || '');
        const stopped = Boolean(this.isSessionStopped?.(sessionId));
        const outcome = stopped
          ? { outcome: 'cancelled' }
          : {
              outcome: 'selected',
              optionId: pickAllowOptionId(msg.params?.options),
            };
        this._writeJson(worker, {
          jsonrpc: '2.0',
          id: msg.id,
          result: { outcome },
        });
      } else {
        this._writeJson(worker, {
          jsonrpc: '2.0',
          id: msg.id,
          error: { code: -32601, message: `Unsupported client method: ${msg.method}` },
        });
      }
      return;
    }

    // 3. Server->client streaming notification (`session/update`)
    if (msg.method === 'session/update' && msg.params?.sessionId) {
      this.onTurnActivity?.(String(msg.params.sessionId));
    }
  }

  _writeJson(worker, payload) {
    if (worker.closed || !worker.proc.stdin || worker.proc.stdin.destroyed) return false;
    try {
      worker.proc.stdin.write(`${JSON.stringify(payload)}\n`);
      return true;
    } catch {
      return false;
    }
  }

  _rpc(worker, method, params, timeoutMs = 15_000) {
    if (worker.closed) {
      return Promise.reject(new Error('ACP worker is closed'));
    }
    const id = worker.nextId++;
    const key = String(id);
    return new Promise((resolve, reject) => {
      const timer =
        timeoutMs > 0
          ? setTimeout(() => {
              worker.pending.delete(key);
              reject(new Error(`ACP ${method} timed out after ${timeoutMs}ms`));
            }, timeoutMs)
          : null;
      timer?.unref?.();
      worker.pending.set(key, { resolve, reject, timer });
      if (!this._writeJson(worker, { jsonrpc: '2.0', id, method, params })) {
        clearTimeout(timer);
        worker.pending.delete(key);
        reject(new Error(`Failed to write ACP ${method} to stdin`));
      }
    });
  }

  _clearIdleTimer(worker) {
    if (worker.idleTimer) {
      clearTimeout(worker.idleTimer);
      worker.idleTimer = null;
    }
  }

  _scheduleIdleReap(worker) {
    this._clearIdleTimer(worker);
    if (worker.closed || worker.inFlightPrompts > 0 || this.idleTimeoutMs <= 0) return;
    worker.idleTimer = setTimeout(() => {
      if (!worker.closed && worker.inFlightPrompts === 0 && worker.pending.size === 0) {
        this._terminateWorker(worker);
      }
    }, this.idleTimeoutMs);
    worker.idleTimer.unref?.();
  }

  _terminateWorker(worker) {
    if (!worker || worker.closed) return;
    worker.closed = true;
    this._clearIdleTimer(worker);
    if (this.#workers.get(worker.appDataDirName) === worker) {
      this.#workers.delete(worker.appDataDirName);
    }
    try {
      worker.proc.stdin?.end();
    } catch {}
    try {
      worker.proc.kill('SIGTERM');
    } catch {}
  }

  _enqueuePromptTurn(worker, sessionId, promptText) {
    const prevChain = worker.promptChains.get(sessionId) || Promise.resolve();
    worker.inFlightPrompts += 1;
    this._clearIdleTimer(worker);

    const nextChain = prevChain
      .catch(() => {})
      .then(async () => {
        if (worker.closed || this.isSessionStopped?.(sessionId)) return;
        this.onTurnActivity?.(sessionId);
        await this._rpc(
          worker,
          'session/prompt',
          {
            sessionId,
            prompt: [{ type: 'text', text: promptText }],
          },
          0, // Turns can run for minutes while executing multi-step coding tasks
        );
      })
      .catch(() => {})
      .finally(() => {
        worker.inFlightPrompts = Math.max(0, worker.inFlightPrompts - 1);
        if (worker.promptChains.get(sessionId) === nextChain) {
          worker.promptChains.delete(sessionId);
        }
        this.onTurnActivity?.(sessionId);
        this._scheduleIdleReap(worker);
      });

    worker.promptChains.set(sessionId, nextChain);
  }

  /**
   * Resumes an idle/cross-window conversation via `agy acp` and starts the prompt turn immediately.
   */
  async sendMessage(conversationId, prompt, { workspace = '' } = {}) {
    const appDataDirName = this.detectAppDataDirName(conversationId);
    const cwd = workspace && existsSync(workspace) ? workspace : process.cwd();
    const worker = await this._getOrStartWorker(appDataDirName, cwd);

    if (!worker.loadedSessions.has(conversationId)) {
      try {
        await this._rpc(
          worker,
          'session/resume',
          { sessionId: conversationId, cwd, mcpServers: [] },
          15_000,
        );
      } catch (resumeErr) {
        // Fallback to ACP standard `session/load` if `session/resume` failed
        try {
          await this._rpc(
            worker,
            'session/load',
            { sessionId: conversationId, cwd, mcpServers: [] },
            15_000,
          );
        } catch {
          this._scheduleIdleReap(worker);
          throw resumeErr;
        }
      }
      worker.loadedSessions.add(conversationId);
    }

    this._enqueuePromptTurn(worker, conversationId, prompt);
    return {
      ok: true,
      delivery: 'acp',
      targetHost: `agy-acp:${appDataDirName}`,
      conversationId,
    };
  }

  /**
   * Creates a brand-new conversation in `~/.gemini/antigravity/brain` via `agy acp` when no LS is active.
   */
  async createConversation(prompt, { workspace = '' } = {}) {
    const appDataDirName = 'antigravity';
    const cwd = workspace && existsSync(workspace) ? workspace : process.cwd();
    const worker = await this._getOrStartWorker(appDataDirName, cwd);

    const created = await this._rpc(
      worker,
      'session/new',
      { cwd, mcpServers: [] },
      15_000,
    );
    const sessionId = String(created?.sessionId || created?.session_id || '').trim();
    if (!sessionId) {
      this._scheduleIdleReap(worker);
      throw new Error('ACP session/new did not return a sessionId');
    }

    worker.loadedSessions.add(sessionId);
    this._enqueuePromptTurn(worker, sessionId, prompt);
    return {
      ok: true,
      delivery: 'acp',
      targetHost: `agy-acp:${appDataDirName}`,
      conversationId: sessionId,
    };
  }

  /**
   * Sends ACP `session/cancel` to interrupt an active turn immediately on mobile Stop.
   */
  cancelSession(conversationId = '') {
    let sent = 0;
    for (const worker of this.#workers.values()) {
      if (worker.closed) continue;
      if (!conversationId || conversationId === '*') {
        for (const sid of worker.loadedSessions) {
          if (this._writeJson(worker, { jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: sid } })) {
            sent += 1;
          }
        }
      } else if (worker.loadedSessions.has(conversationId)) {
        if (
          this._writeJson(worker, {
            jsonrpc: '2.0',
            method: 'session/cancel',
            params: { sessionId: conversationId },
          })
        ) {
          sent += 1;
        }
      }
    }
    return sent;
  }

  async shutdown() {
    for (const worker of [...this.#workers.values()]) {
      this._terminateWorker(worker);
    }
    this.#workers.clear();
  }
}
