/**
 * Sanctioned Antigravity Agent Driver + Multi-Window Host Router + ACP Wakeup + Git/Terminal Runner.
 *
 * Two-Tier Immediate Delivery Architecture:
 *  - Tier 1 (`agentapi`): Routes `send-message` / `new-conversation` to live Antigravity 2.0 or
 *    Antigravity IDE Language Servers with clean environment isolation and verified per-conversation
 *    `projectId` lookup via `get-conversation-metadata` (avoiding cross-project `PermissionDenied`
 *    and skipping hosts where the trajectory is `NotFound`).
 *  - Tier 2 (`agy acp`): Actively wakes and resumes idle or post-sleep conversations directly in
 *    `~/.gemini/<surface>/brain/<conversationId>` via the official Agent Client Protocol (`agy acp`)
 *    whenever no live Language Server is registered or reachable — so mobile messages execute
 *    immediately without waiting for manual input on the laptop.
 */
import { execFile, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, extname, isAbsolute, join, normalize, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { AcpSessionRunner } from './acp-runner.mjs';

const execFileAsync = promisify(execFile);
const MAX_DIFF_BYTES = 96 * 1024;
const MAX_CMD_OUTPUT = 64 * 1024;
const MAX_UPLOAD_BYTES = 20 * 1024 * 1024; // 20 MiB max mobile upload
const HOST_TTL_MS = 24 * 60 * 60 * 1000; // 24h max retention for persisted LS endpoints
const IMAGE_EXT_RE = /^\.(png|jpe?g|webp|gif|heic|heif|bmp|svg)$/i;

function isDeadHostError(err) {
  const detail = `${err?.code || ''} ${err?.stderr || ''} ${err?.stdout || ''} ${err?.message || ''}`;
  return /ECONNREFUSED|connection refused|dial tcp .* refused|actively refused/i.test(detail);
}

function isTrajectoryNotFoundText(text) {
  return /trajectory not found|code\s*=\s*NotFound|unknown conversation/i.test(String(text || ''));
}

function isUserWorkspacePath(rawPath) {
  if (!rawPath || typeof rawPath !== 'string' || !rawPath.trim()) return false;
  const norm = rawPath.trim().replace(/\\/g, '/');
  if (norm.includes('/.gemini/') || norm.endsWith('/.gemini')) return false;
  return true;
}

function uriToFsPath(uriOrPath) {
  if (!uriOrPath || typeof uriOrPath !== 'string') return '';
  const trimmed = uriOrPath.trim();
  if (trimmed.startsWith('file://')) {
    try {
      return fileURLToPath(trimmed);
    } catch {
      return '';
    }
  }
  return trimmed;
}

export class AgentDriver {
  /** @type {Map<string, { lsAddress: string, csrfToken: string, agentApiExe: string, projectId: string, appName: string, workspacePaths: string[], updatedAt: number }>} */
  #conversationHosts = new Map();

  /** @type {Map<string, { lsAddress: string, csrfToken: string, agentApiExe: string, projectId: string, appName: string, workspacePaths: string[], updatedAt: number }>} */
  #knownHosts = new Map();

  /** @type {Map<string, string>} */
  #verifiedProjectIds = new Map();

  /** @type {Map<string, number>} */
  #openWorkspaces = new Map();

  #hostsFile = '';
  #flushingQueue = false;
  #activeCommandProcs = new Set();
  /** @type {AcpSessionRunner | null} */
  #acpRunner = null;

  /**
   * @param {{
   *   defaultWorkspace?: string,
   *   agentApiPath?: string,
   *   agyPath?: string | false,
   *   geminiDir?: string,
   *   stateDir?: string,
   *   acpIdleTimeoutMs?: number,
   *   isSessionStopped?: (sessionId: string) => boolean,
   *   onTurnActivity?: (sessionId: string) => void
   * }} [opts]
   */
  constructor(opts = {}) {
    this.defaultWorkspace = opts.defaultWorkspace || process.cwd();
    this.agentApiPath = opts.agentApiPath || 'agentapi';
    this.#hostsFile = opts.stateDir ? join(opts.stateDir, 'hosts-runtime.json') : '';
    this.queuedMessages = new Map(); // convId -> Array<{id, prompt, workspaceHint?, createdAt}>
    this.delegatedExecutor = null; // optional async ({ action, conversationId, prompt }) => result
    this.onQueueFlushed = null; // optional ({ conversationId, messageId, result }) => void

    const customAgentApiOnly = Boolean(
      opts.agentApiPath && opts.agentApiPath !== 'agentapi' && opts.agyPath === undefined,
    );
    const resolvedAgyOpt =
      opts.agyPath !== undefined ? opts.agyPath : customAgentApiOnly ? false : undefined;

    this.#acpRunner = new AcpSessionRunner({
      agyPath: resolvedAgyOpt,
      geminiDir: opts.geminiDir,
      runtimeFile: opts.stateDir ? join(opts.stateDir, 'bridge-runtime.json') : '',
      idleTimeoutMs: opts.acpIdleTimeoutMs,
      isSessionStopped: opts.isSessionStopped,
      onTurnActivity: opts.onTurnActivity,
    });

    this._loadPersistedHosts();
  }

  _loadPersistedHosts() {
    if (!this.#hostsFile || !existsSync(this.#hostsFile)) return;
    try {
      const parsed = JSON.parse(readFileSync(this.#hostsFile, 'utf-8'));
      const cutoff = Date.now() - HOST_TTL_MS;
      if (Array.isArray(parsed?.hosts)) {
        for (const h of parsed.hosts) {
          if (h && typeof h.lsAddress === 'string' && h.lsAddress.trim() && (h.updatedAt || 0) >= cutoff) {
            this.#knownHosts.set(h.lsAddress.trim(), {
              lsAddress: h.lsAddress.trim(),
              csrfToken: typeof h.csrfToken === 'string' ? h.csrfToken : '',
              agentApiExe: typeof h.agentApiExe === 'string' ? h.agentApiExe : '',
              projectId: typeof h.projectId === 'string' ? h.projectId : '',
              appName: typeof h.appName === 'string' ? h.appName : 'antigravity',
              workspacePaths: Array.isArray(h.workspacePaths)
                ? h.workspacePaths.filter((p) => isUserWorkspacePath(p))
                : [],
              updatedAt: Number(h.updatedAt) || Date.now(),
            });
          }
        }
      }
      if (parsed?.conversations && typeof parsed.conversations === 'object') {
        for (const [convId, lsAddr] of Object.entries(parsed.conversations)) {
          const host = typeof lsAddr === 'string' ? this.#knownHosts.get(lsAddr) : null;
          if (convId && host) {
            this.#conversationHosts.set(convId, host);
          }
        }
      }
      if (parsed?.verifiedProjectIds && typeof parsed.verifiedProjectIds === 'object') {
        for (const [convId, pid] of Object.entries(parsed.verifiedProjectIds)) {
          if (convId && typeof pid === 'string' && pid) {
            this.#verifiedProjectIds.set(convId, pid);
          }
        }
      }
    } catch {}
  }

  _savePersistedHosts() {
    if (!this.#hostsFile) return;
    try {
      mkdirSync(dirname(this.#hostsFile), { recursive: true });
      const conversations = {};
      for (const [convId, host] of this.#conversationHosts.entries()) {
        if (host?.lsAddress && this.#knownHosts.has(host.lsAddress)) {
          conversations[convId] = host.lsAddress;
        }
      }
      const verifiedProjectIds = Object.fromEntries(this.#verifiedProjectIds.entries());
      writeFileSync(
        this.#hostsFile,
        JSON.stringify(
          {
            updatedAt: Date.now(),
            hosts: [...this.#knownHosts.values()],
            conversations,
            verifiedProjectIds,
          },
          null,
          2,
        ),
        { mode: 0o600 },
      );
    } catch {}
  }

  _pruneDeadHost(lsAddress) {
    if (!lsAddress) return;
    const deleted = this.#knownHosts.delete(lsAddress);
    for (const [convId, h] of this.#conversationHosts.entries()) {
      if (h?.lsAddress === lsAddress) {
        this.#conversationHosts.delete(convId);
      }
    }
    if (deleted) {
      this._savePersistedHosts();
    }
  }

  /**
   * Non-sensitive diagnostic summary of registered Antigravity windows (never exposes LS ports/tokens).
   */
  getRegisteredHostsSummary() {
    const hosts = [...this.#knownHosts.values()]
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .map((h) => ({
        appName: h.appName || 'antigravity',
        workspacePaths: h.workspacePaths || [],
        updatedAt: h.updatedAt,
      }));
    return {
      count: hosts.length + (process.env.ANTIGRAVITY_LS_ADDRESS ? 1 : 0),
      acpAvailable: Boolean(this.#acpRunner?.resolveAgyBinary()),
      hosts,
    };
  }

  setDefaultWorkspace(wsPath) {
    if (wsPath && existsSync(wsPath)) {
      this.defaultWorkspace = resolve(wsPath);
    }
    return this.defaultWorkspace;
  }

  /**
   * Lists known/open workspaces across active Antigravity hosts, IDE heartbeats, defaultWorkspace, and brain sessions.
   * @param {Array<{ workspaceHint?: string }>} [sessions]
   */
  listWorkspaces(sessions = []) {
    const map = new Map();
    const homeNorm = homedir().replace(/\\/g, '/').replace(/\/+$/, '');
    const defaultAbs = resolve(this.defaultWorkspace);
    const addCandidate = (rawPath, { isOpenInHost = false } = {}) => {
      if (!rawPath || typeof rawPath !== 'string' || !rawPath.trim()) return;
      if (rawPath !== this.defaultWorkspace && !isUserWorkspacePath(rawPath)) return;
      const abs = resolve(rawPath.trim());
      const normAbs = abs.replace(/\\/g, '/');
      const base = basename(abs) || abs;
      if (abs !== defaultAbs && !isOpenInHost) {
        if (base.startsWith('.') || normAbs.startsWith(`${homeNorm}/.`)) return;
      }
      if (abs !== defaultAbs && !existsSync(abs)) return;
      const existing = map.get(abs);
      if (existing) {
        if (isOpenInHost) existing.isOpenInHost = true;
        return;
      }
      map.set(abs, {
        path: abs,
        name: base,
        isDefault: abs === defaultAbs,
        isOpenInHost: Boolean(isOpenInHost),
        sessionCount: 0,
      });
    };

    addCandidate(this.defaultWorkspace);
    for (const h of this.#knownHosts.values()) {
      for (const wp of h.workspacePaths || []) {
        addCandidate(wp, { isOpenInHost: true });
      }
    }
    const openCutoff = Date.now() - HOST_TTL_MS;
    for (const [wp, ts] of this.#openWorkspaces.entries()) {
      if (ts >= openCutoff) {
        addCandidate(wp, { isOpenInHost: true });
      }
    }
    for (const s of sessions || []) {
      if (s?.workspaceHint) {
        addCandidate(s.workspaceHint);
      }
    }

    for (const s of sessions || []) {
      if (!s?.workspaceHint) continue;
      const normS = resolve(s.workspaceHint).replace(/\\/g, '/');
      for (const ws of map.values()) {
        const normW = ws.path.replace(/\\/g, '/');
        if (normS === normW || normS.startsWith(`${normW}/`)) {
          ws.sessionCount += 1;
        }
      }
    }

    return [...map.values()].sort((a, b) => {
      if (a.isDefault !== b.isDefault) return a.isDefault ? -1 : 1;
      if (a.isOpenInHost !== b.isOpenInHost) return a.isOpenInHost ? -1 : 1;
      if (b.sessionCount !== a.sessionCount) return b.sessionCount - a.sessionCount;
      return a.name.localeCompare(b.name);
    });
  }

  /**
   * Cancels queued messages, interrupts active ACP turns, and terminates running quick terminal commands.
   */
  stopConversation(conversationId = '') {
    let clearedQueued = 0;
    if (conversationId && conversationId !== '*') {
      clearedQueued = (this.queuedMessages.get(conversationId) || []).length;
      this.queuedMessages.delete(conversationId);
    } else {
      for (const items of this.queuedMessages.values()) {
        clearedQueued += items.length;
      }
      this.queuedMessages.clear();
    }

    const cancelledAcp = this.#acpRunner ? this.#acpRunner.cancelSession(conversationId) : 0;

    let killedCommands = 0;
    for (const proc of [...this.#activeCommandProcs]) {
      try {
        proc.kill('SIGTERM');
        killedCommands += 1;
      } catch {}
    }
    return { ok: true, clearedQueued, cancelledAcp, killedCommands };
  }

  async shutdown() {
    for (const proc of [...this.#activeCommandProcs]) {
      try {
        proc.kill('SIGTERM');
      } catch {}
    }
    this.#activeCommandProcs.clear();
    if (this.#acpRunner) {
      await this.#acpRunner.shutdown();
    }
  }

  /**
   * Saves a mobile photo or file upload into `<workspace>/.antigravity-uploads/` so Antigravity
   * can inspect it directly via `read_file` or project tools.
   */
  saveUploadedFile({ fileName, base64Data, workspacePath } = {}) {
    const rawStr = String(base64Data || '').trim();
    if (!rawStr) {
      throw new Error('base64Data is required');
    }
    const cleanB64 = rawStr.includes(',') ? rawStr.slice(rawStr.indexOf(',') + 1) : rawStr;
    const buf = Buffer.from(cleanB64, 'base64');
    if (buf.length === 0) {
      throw new Error('Uploaded file is empty');
    }
    if (buf.length > MAX_UPLOAD_BYTES) {
      throw new Error('File exceeds 20 MiB upload limit');
    }

    const cwd = this._resolveWorkspace(workspacePath);
    const uploadsDir = join(cwd, '.antigravity-uploads');
    mkdirSync(uploadsDir, { recursive: true });

    const rawBase = basename(String(fileName || 'attachment.bin').replace(/\\/g, '/'));
    const safeName = rawBase.replace(/[^a-zA-Z0-9._-]+/g, '_').replace(/^_+/, '').slice(0, 120) || 'attachment.bin';
    const stampedName = `${Date.now()}_${safeName}`;
    const savedPath = join(uploadsDir, stampedName);
    writeFileSync(savedPath, buf);

    const ext = extname(safeName);
    return {
      ok: true,
      fileName: safeName,
      savedPath,
      relativePath: relative(cwd, savedPath).replace(/\\/g, '/'),
      workspace: cwd,
      sizeBytes: buf.length,
      isImage: IMAGE_EXT_RE.test(ext),
    };
  }

  /**
   * Records open workspace paths and/or Antigravity Language Server host context supplied by
   * Sidecar `HostHeartbeat`, VS Code Extension `WorkspaceHeartbeat`, or lifecycle hooks.
   */
  registerHookContext(hookPayload = {}) {
    if (!hookPayload || typeof hookPayload !== 'object') return;
    const hc = hookPayload.__hostContext;
    const convId = typeof hookPayload.conversationId === 'string' ? hookPayload.conversationId.trim() : '';
    const rawWsPaths = Array.isArray(hookPayload.workspacePaths) ? hookPayload.workspacePaths : [];
    const cwd = typeof hookPayload.cwd === 'string' && hookPayload.cwd.trim() ? hookPayload.cwd.trim() : '';

    const validUserWorkspaces = [...rawWsPaths, ...(cwd ? [cwd] : [])]
      .filter((p) => isUserWorkspacePath(p))
      .map((p) => resolve(p.trim()));

    const now = Date.now();
    for (const wp of validUserWorkspaces) {
      this.#openWorkspaces.set(wp, now);
    }

    if (hc && typeof hc === 'object' && typeof hc.lsAddress === 'string' && hc.lsAddress.trim()) {
      const prev = this.#knownHosts.get(hc.lsAddress.trim());
      const mergedWorkspaces = [
        ...new Set([...(prev?.workspacePaths || []).filter(isUserWorkspacePath), ...validUserWorkspaces]),
      ];
      const hostProjectId =
        (typeof hc.projectId === 'string' && hc.projectId.trim()) || prev?.projectId || '';

      const record = {
        lsAddress: hc.lsAddress.trim(),
        csrfToken: typeof hc.csrfToken === 'string' && hc.csrfToken ? hc.csrfToken : prev?.csrfToken || '',
        agentApiExe: typeof hc.agentApiExe === 'string' && hc.agentApiExe ? hc.agentApiExe : prev?.agentApiExe || '',
        projectId: hostProjectId,
        appName: typeof hc.appName === 'string' && hc.appName ? hc.appName : prev?.appName || 'antigravity',
        workspacePaths: mergedWorkspaces,
        updatedAt: now,
      };
      this.#knownHosts.set(record.lsAddress, record);
      if (convId) {
        this.#conversationHosts.set(convId, record);
      }
      this._savePersistedHosts();

      if (this.queuedMessages.size > 0 && !this.#flushingQueue && hookPayload.hookEventName !== 'PreInvocation') {
        void this.flushQueuedMessages();
      }
    }
  }

  /**
   * Resolves the `agentapi` binary + argument prefix across Sidecar (`ANTIGRAVITY_AGENTAPI_EXE`),
   * registered IDE host context, and standard Antigravity installation paths.
   */
  _resolveAgentApiCommand(preferredExe = '') {
    if (this.agentApiPath && this.agentApiPath !== 'agentapi') {
      return { file: this.agentApiPath, prefixArgs: [] };
    }
    const envExe = preferredExe || process.env.ANTIGRAVITY_AGENTAPI_EXE;
    if (envExe && existsSync(envExe)) {
      const base = envExe.replace(/\\/g, '/').split('/').pop()?.toLowerCase() || '';
      const isDirectAgentApi = base === 'agentapi' || base === 'agentapi.exe';
      return { file: envExe, prefixArgs: isDirectAgentApi ? [] : ['agentapi'] };
    }
    const binExt = process.platform === 'win32' ? '.exe' : '';
    const candidates = [
      join(homedir(), '.gemini', 'antigravity', 'bin', `agentapi${binExt}`),
      join(homedir(), '.gemini', 'antigravity-ide', 'bin', `agentapi${binExt}`),
      join(homedir(), '.gemini', 'antigravity-cli', 'bin', `agentapi${binExt}`),
    ];
    for (const candidate of candidates) {
      if (existsSync(candidate)) {
        return { file: candidate, prefixArgs: [] };
      }
    }
    const agyBin = join(homedir(), '.gemini', 'bin', `agy${binExt}`);
    if (existsSync(agyBin)) {
      return { file: agyBin, prefixArgs: ['agentapi'] };
    }
    return { file: this.agentApiPath || 'agentapi', prefixArgs: [] };
  }

  /**
   * Returns ordered candidate Antigravity host environments for `conversationId`.
   */
  _buildCandidateHosts(conversationId = '', workspaceHint = '') {
    const out = [];
    const seen = new Set();
    const pushHost = (h) => {
      if (!h || !h.lsAddress || seen.has(h.lsAddress)) return;
      seen.add(h.lsAddress);
      out.push(h);
    };

    if (conversationId && this.#conversationHosts.has(conversationId)) {
      pushHost(this.#conversationHosts.get(conversationId));
    }

    const normHint = String(workspaceHint || '').replace(/\\/g, '/').replace(/\/+$/, '');
    if (normHint) {
      const matching = [...this.#knownHosts.values()]
        .filter((h) =>
          h.workspacePaths.some((wp) => {
            const normWp = wp.replace(/\\/g, '/').replace(/\/+$/, '');
            return normHint.startsWith(normWp) || normWp.startsWith(normHint);
          }),
        )
        .sort((a, b) => b.updatedAt - a.updatedAt);
      for (const h of matching) pushHost(h);
    }

    if (process.env.ANTIGRAVITY_LS_ADDRESS) {
      pushHost({
        lsAddress: process.env.ANTIGRAVITY_LS_ADDRESS,
        csrfToken: process.env.ANTIGRAVITY_CSRF_TOKEN || '',
        agentApiExe: process.env.ANTIGRAVITY_AGENTAPI_EXE || '',
        projectId: process.env.ANTIGRAVITY_PROJECT_ID || '',
        appName: process.env.ANTIGRAVITY_AUTH_SUCCESS_APP || 'sidecar',
        workspacePaths: [],
        updatedAt: 0,
      });
    }

    const remaining = [...this.#knownHosts.values()].sort((a, b) => b.updatedAt - a.updatedAt);
    for (const h of remaining) pushHost(h);

    return out;
  }

  /**
   * Builds a strictly sanitized child environment for `agentapi` — stripping inherited
   * `ANTIGRAVITY_CONVERSATION_ID` / `ANTIGRAVITY_TRAJECTORY_ID` / `ANTIGRAVITY_PROJECT_ID`
   * so cross-workspace `send-message` calls never fail with `source project_id` mismatch.
   */
  _makeExecEnv(host, explicitProjectId = null) {
    const env = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (v === undefined) continue;
      if (k.startsWith('ANTIGRAVITY_')) continue;
      if (k === 'AGY_ENABLE_HUB') continue;
      env[k] = v;
    }

    env.ANTIGRAVITY_LS_ADDRESS = host.lsAddress;
    if (host.csrfToken) {
      env.ANTIGRAVITY_CSRF_TOKEN = host.csrfToken;
    }
    if (host.agentApiExe) {
      env.ANTIGRAVITY_AGENTAPI_EXE = host.agentApiExe;
    }
    const pid = explicitProjectId !== null ? explicitProjectId : host.projectId || '';
    if (pid) {
      env.ANTIGRAVITY_PROJECT_ID = pid;
    }
    return env;
  }

  /**
   * Queries `get-conversation-metadata` on `host` to verify that `<conversationId>` exists in
   * this host's brain surface and to extract its true `metadata.projectId` (never guessing `host.projectId`!).
   */
  async _inspectConversationOnHost(host, conversationId) {
    const cachedProjectId = conversationId ? this.#verifiedProjectIds.get(conversationId) || '' : '';
    if (!conversationId) {
      return { existsOnHost: true, projectId: host.projectId || '', workspacePath: '' };
    }

    const { file, prefixArgs } = this._resolveAgentApiCommand(host.agentApiExe);
    try {
      const { stdout } = await execFileAsync(
        file,
        [...prefixArgs, 'get-conversation-metadata', conversationId],
        {
          timeout: 4000,
          windowsHide: true,
          env: this._makeExecEnv(host, ''),
        },
      );
      const trimmed = stdout.trim();
      const parsed = trimmed ? JSON.parse(trimmed) : null;
      if (parsed?.error && isTrajectoryNotFoundText(parsed.error)) {
        return { existsOnHost: false, projectId: '', workspacePath: '' };
      }
      const meta =
        parsed?.response?.conversationMetadata?.metadata ||
        parsed?.response?.conversation_metadata?.metadata;
      const resolvedId = meta?.projectId || meta?.project_id || cachedProjectId;
      if (meta?.projectId || meta?.project_id) {
        this.#verifiedProjectIds.set(conversationId, resolvedId);
        this._savePersistedHosts();
      }
      const wsUri =
        meta?.workspaceUris?.[0] ||
        meta?.workspaces?.[0]?.workspaceFolderAbsoluteUri ||
        '';
      return {
        existsOnHost: true,
        projectId: resolvedId,
        workspacePath: uriToFsPath(wsUri),
      };
    } catch (err) {
      if (isDeadHostError(err)) {
        this._pruneDeadHost(host.lsAddress);
        return { existsOnHost: false, dead: true, err };
      }
      if (err && err.code === 'ENOENT') {
        return { existsOnHost: false, enoent: true, err };
      }
      const detail = `${err?.stdout || ''} ${err?.stderr || ''} ${err?.message || ''}`;
      if (isTrajectoryNotFoundText(detail)) {
        return { existsOnHost: false, notFound: true, err };
      }
      return { existsOnHost: true, projectId: cachedProjectId, workspacePath: '' };
    }
  }

  /**
   * Checks whether either `agentapi` (via a live host) or `agy acp` is available on this machine.
   */
  async hasAgentApi(conversationId = '') {
    if (this.#acpRunner?.resolveAgyBinary()) return true;
    const candidates = this._buildCandidateHosts(conversationId);
    if (candidates.length === 0) return false;
    const first = candidates[0];
    const { file, prefixArgs } = this._resolveAgentApiCommand(first.agentApiExe);
    try {
      await execFileAsync(file, [...prefixArgs, '--help'], {
        timeout: 2500,
        windowsHide: true,
        env: this._makeExecEnv(first),
      });
      return true;
    } catch (err) {
      return Boolean(err && err.code !== 'ENOENT');
    }
  }

  async _trySendMessageViaHosts(conversationId, cleanPrompt, workspaceHint = '') {
    const candidates = this._buildCandidateHosts(conversationId, workspaceHint);
    let lastErr = null;
    let discoveredWorkspace = '';

    for (const host of candidates) {
      const inspection = await this._inspectConversationOnHost(host, conversationId);
      if (inspection.workspacePath && !discoveredWorkspace) {
        discoveredWorkspace = inspection.workspacePath;
      }
      if (!inspection.existsOnHost) {
        if (inspection.err) lastErr = inspection.err;
        if (inspection.enoent) break;
        continue;
      }

      const { file, prefixArgs } = this._resolveAgentApiCommand(host.agentApiExe);
      const msgArgs = cleanPrompt.startsWith('-')
        ? ['--', conversationId, cleanPrompt]
        : [conversationId, cleanPrompt];
      const projectId = inspection.projectId || '';

      const runSendWithPid = async (pidToUse) => {
        const { stdout, stderr } = await execFileAsync(
          file,
          [...prefixArgs, 'send-message', ...msgArgs],
          {
            timeout: 15000,
            windowsHide: true,
            env: this._makeExecEnv(host, pidToUse),
          },
        );
        const out = (stdout || stderr || '').trim();
        if (out.startsWith('{')) {
          try {
            const parsedOut = JSON.parse(out);
            if (parsedOut?.error) {
              const rpcErr = new Error(String(parsedOut.error));
              rpcErr.stdout = stdout;
              rpcErr.stderr = stderr;
              throw rpcErr;
            }
          } catch (parseOrRpcErr) {
            if (parseOrRpcErr instanceof Error && !(parseOrRpcErr instanceof SyntaxError)) {
              throw parseOrRpcErr;
            }
          }
        }
        return out;
      };

      try {
        try {
          const out = await runSendWithPid(projectId);
          if (this.#knownHosts.has(host.lsAddress)) {
            this.#conversationHosts.set(conversationId, host);
            this._savePersistedHosts();
          }
          return {
            ok: true,
            delivery: 'agentapi',
            targetHost: host.appName || 'antigravity',
            output: out,
          };
        } catch (errFirst) {
          if (errFirst?.code === 'ENOENT' || isDeadHostError(errFirst)) {
            throw errFirst;
          }
          const detail = `${errFirst?.stdout || ''} ${errFirst?.stderr || ''} ${errFirst?.message || ''}`;
          const targetPidMatch = /target project_id\s+"([^"]+)"/i.exec(detail);
          if (targetPidMatch && targetPidMatch[1] && targetPidMatch[1] !== projectId) {
            const exactPid = targetPidMatch[1];
            const out = await runSendWithPid(exactPid);
            this.#verifiedProjectIds.set(conversationId, exactPid);
            if (this.#knownHosts.has(host.lsAddress)) {
              this.#conversationHosts.set(conversationId, host);
            }
            this._savePersistedHosts();
            return {
              ok: true,
              delivery: 'agentapi',
              targetHost: host.appName || 'antigravity',
              output: out,
            };
          }
          if (projectId) {
            const out = await runSendWithPid('');
            this.#verifiedProjectIds.delete(conversationId);
            if (this.#knownHosts.has(host.lsAddress)) {
              this.#conversationHosts.set(conversationId, host);
              this._savePersistedHosts();
            }
            return {
              ok: true,
              delivery: 'agentapi',
              targetHost: host.appName || 'antigravity',
              output: out,
            };
          }
          throw errFirst;
        }
      } catch (err) {
        if (isDeadHostError(err)) {
          this._pruneDeadHost(host.lsAddress);
        }
        if (err && err.code === 'ENOENT') {
          lastErr = err;
          break;
        }
        lastErr = err;
      }
    }

    return { ok: false, lastErr, discoveredWorkspace };
  }

  async _tryCreateConversationViaHosts(cleanPrompt, workspaceHint = '') {
    const normHint = workspaceHint && existsSync(workspaceHint) ? resolve(workspaceHint) : '';
    let candidates = this._buildCandidateHosts('', normHint);
    // For new conversations targeting a specific workspace, only use an LS host that matches
    // that workspace (or has no specific workspace bound); otherwise let `agy acp` create it
    // directly in the exact target `cwd`!
    if (normHint && this.#acpRunner?.resolveAgyBinary()) {
      const normSlash = normHint.replace(/\\/g, '/').replace(/\/+$/, '');
      candidates = candidates.filter(
        (h) =>
          h.workspacePaths.length === 0 ||
          h.workspacePaths.some((wp) => {
            const n = wp.replace(/\\/g, '/').replace(/\/+$/, '');
            return normSlash.startsWith(n) || n.startsWith(normSlash);
          }),
      );
    }

    let lastErr = null;
    for (const host of candidates) {
      const { file, prefixArgs } = this._resolveAgentApiCommand(host.agentApiExe);
      const promptArgs = cleanPrompt.startsWith('-') ? ['--', cleanPrompt] : [cleanPrompt];
      const projectId = host.projectId || '';

      try {
        try {
          const { stdout, stderr } = await execFileAsync(
            file,
            [...prefixArgs, 'new-conversation', ...promptArgs],
            {
              timeout: 15000,
              windowsHide: true,
              env: this._makeExecEnv(host, projectId),
            },
          );
          const out = (stdout || stderr || '').trim();
          const idMatch = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.exec(out);
          if (idMatch) {
            if (projectId) this.#verifiedProjectIds.set(idMatch[0], projectId);
            if (this.#knownHosts.has(host.lsAddress)) {
              this.#conversationHosts.set(idMatch[0], host);
            }
            this._savePersistedHosts();
          }
          return {
            ok: true,
            delivery: 'agentapi',
            targetHost: host.appName || 'antigravity',
            conversationId: idMatch ? idMatch[0] : null,
            output: out,
          };
        } catch (errWithPid) {
          if (projectId && errWithPid?.code !== 'ENOENT' && !isDeadHostError(errWithPid)) {
            const { stdout, stderr } = await execFileAsync(
              file,
              [...prefixArgs, 'new-conversation', ...promptArgs],
              {
                timeout: 15000,
                windowsHide: true,
                env: this._makeExecEnv(host, ''),
              },
            );
            const out = (stdout || stderr || '').trim();
            const idMatch = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.exec(out);
            return {
              ok: true,
              delivery: 'agentapi',
              targetHost: host.appName || 'antigravity',
              conversationId: idMatch ? idMatch[0] : null,
              output: out,
            };
          }
          throw errWithPid;
        }
      } catch (err) {
        if (isDeadHostError(err)) {
          this._pruneDeadHost(host.lsAddress);
        }
        if (err && err.code === 'ENOENT') {
          lastErr = err;
          break;
        }
        lastErr = err;
      }
    }

    return { ok: false, lastErr };
  }

  async _deliverDirect(conversationId, cleanPrompt, workspaceHint = '') {
    const attempt = await this._trySendMessageViaHosts(conversationId, cleanPrompt, workspaceHint);
    if (attempt.ok) {
      return attempt;
    }

    if (this.#acpRunner?.resolveAgyBinary()) {
      const targetWorkspace =
        workspaceHint || attempt.discoveredWorkspace || this.defaultWorkspace;
      try {
        return await this.#acpRunner.sendMessage(conversationId, cleanPrompt, {
          workspace: this._resolveWorkspace(targetWorkspace),
        });
      } catch (acpErr) {
        return { ok: false, lastErr: acpErr };
      }
    }

    return attempt;
  }

  async _createDirect(cleanPrompt, targetWorkspace = '') {
    const attempt = await this._tryCreateConversationViaHosts(cleanPrompt, targetWorkspace);
    if (attempt.ok) {
      return attempt;
    }

    if (this.#acpRunner?.resolveAgyBinary()) {
      try {
        return await this.#acpRunner.createConversation(cleanPrompt, {
          workspace: this._resolveWorkspace(targetWorkspace),
        });
      } catch (acpErr) {
        return { ok: false, lastErr: acpErr };
      }
    }

    return attempt;
  }

  /**
   * Atomically claims and delivers queued prompts without racing `PreInvocation` `consumeQueuedMessages`.
   */
  async flushQueuedMessages() {
    if (this.#flushingQueue || this.queuedMessages.size === 0) return 0;
    this.#flushingQueue = true;
    let deliveredCount = 0;
    try {
      for (const convKey of [...this.queuedMessages.keys()]) {
        const claimed = this.queuedMessages.get(convKey);
        if (!Array.isArray(claimed) || claimed.length === 0) {
          this.queuedMessages.delete(convKey);
          continue;
        }
        // Claim atomically before awaiting async I/O so PreInvocation cannot double-inject
        this.queuedMessages.delete(convKey);

        const remaining = [];
        for (const item of claimed) {
          const res =
            convKey === '__new__'
              ? await this._createDirect(item.prompt, item.workspaceHint || '')
              : await this._deliverDirect(convKey, item.prompt, item.workspaceHint || '');
          if (res.ok && (res.delivery === 'agentapi' || res.delivery === 'acp')) {
            deliveredCount++;
            this.onQueueFlushed?.({
              conversationId: convKey === '__new__' ? res.conversationId || null : convKey,
              messageId: item.id,
              result: res,
            });
          } else {
            remaining.push(item);
          }
        }
        if (remaining.length > 0) {
          const arrivedDuringFlush = this.queuedMessages.get(convKey) || [];
          this.queuedMessages.set(convKey, [...remaining, ...arrivedDuringFlush]);
        }
      }
    } finally {
      this.#flushingQueue = false;
    }
    return deliveredCount;
  }

  /**
   * Sends a follow-up prompt to an existing Antigravity conversation immediately via
   * Tier 1 (`agentapi`) or Tier 2 (`agy acp`), falling back to `queuedMessages` only if
   * no Antigravity runtime binary exists on the machine.
   * @param {string} conversationId
   * @param {string} prompt
   * @param {{ workspaceHint?: string }} [opts]
   */
  async sendMessage(conversationId, prompt, opts = {}) {
    const cleanPrompt = String(prompt || '').trim();
    if (!conversationId || !cleanPrompt) {
      throw new Error('conversationId and prompt are required');
    }

    if (this.delegatedExecutor) {
      return this.delegatedExecutor({
        action: 'send-message',
        conversationId,
        prompt: cleanPrompt,
      });
    }

    const direct = await this._deliverDirect(
      conversationId,
      cleanPrompt,
      opts.workspaceHint || '',
    );
    if (direct.ok) {
      return direct;
    }

    const list = this.queuedMessages.get(conversationId) || [];
    const item = {
      id: `msg_${Date.now()}`,
      prompt: cleanPrompt,
      workspaceHint: opts.workspaceHint || '',
      createdAt: Date.now(),
    };
    list.push(item);
    this.queuedMessages.set(conversationId, list);
    const errDetail = direct.lastErr
      ? String(direct.lastErr.stderr || direct.lastErr.message || direct.lastErr).trim()
      : undefined;
    return {
      ok: true,
      delivery: 'queued',
      messageId: item.id,
      warning: errDetail || undefined,
      note: 'Queued for Antigravity host heartbeat or PreInvocation hook pickup.',
    };
  }

  /**
   * Starts a brand-new Antigravity conversation with the given prompt immediately via
   * Tier 1 (`agentapi`) or Tier 2 (`agy acp`).
   * @param {string} prompt
   * @param {{ workspaceHint?: string }} [opts]
   */
  async createConversation(prompt, opts = {}) {
    const cleanPrompt = String(prompt || '').trim();
    if (!cleanPrompt) throw new Error('Prompt is required');

    const wsHint = opts.workspaceHint ? String(opts.workspaceHint).trim() : '';
    if (wsHint) {
      this.setDefaultWorkspace(wsHint);
    }
    const targetWorkspace = wsHint || this.defaultWorkspace;

    if (this.delegatedExecutor) {
      return this.delegatedExecutor({
        action: 'new-conversation',
        prompt: cleanPrompt,
        workspaceHint: targetWorkspace,
      });
    }

    const direct = await this._createDirect(cleanPrompt, targetWorkspace);
    if (direct.ok) {
      return direct;
    }

    const list = this.queuedMessages.get('__new__') || [];
    const item = {
      id: `new_${Date.now()}`,
      prompt: cleanPrompt,
      workspaceHint: targetWorkspace,
      createdAt: Date.now(),
    };
    list.push(item);
    this.queuedMessages.set('__new__', list);
    return {
      ok: true,
      delivery: 'queued',
      messageId: item.id,
      note: 'Queued new conversation request.',
    };
  }

  consumeQueuedMessages(conversationId) {
    const items = this.queuedMessages.get(conversationId) || [];
    this.queuedMessages.delete(conversationId);
    return items;
  }

  /**
   * Inspects workspace Git branch & modified/untracked files for mobile code review.
   */
  async getWorkspaceStatus(workspacePath = this.defaultWorkspace) {
    const cwd = this._resolveWorkspace(workspacePath);
    try {
      const { stdout } = await execFileAsync('git', ['status', '--porcelain=v1', '-b'], {
        cwd,
        timeout: 6000,
        windowsHide: true,
      });
      const lines = stdout.split(/\r?\n/).filter(Boolean);
      let branch = 'main';
      const files = [];
      for (const line of lines) {
        if (line.startsWith('## ')) {
          branch = line.slice(3).split('...')[0].trim();
          continue;
        }
        const status = line.slice(0, 2).trim() || 'M';
        const filePath = line.slice(3).trim();
        files.push({ status, path: filePath });
      }
      return { ok: true, workspace: cwd, isGitRepo: true, branch, files };
    } catch {
      return { ok: true, workspace: cwd, isGitRepo: false, branch: null, files: [] };
    }
  }

  /**
   * Returns a unified diff for a specific file inside the workspace.
   */
  async getFileDiff(filePath, workspacePath = this.defaultWorkspace) {
    const cwd = this._resolveWorkspace(workspacePath);
    const fullTarget = resolve(cwd, String(filePath || ''));
    const rel = relative(cwd, fullTarget);
    if (!rel || rel.startsWith('..') || isAbsolute(rel)) {
      throw new Error('File path outside workspace is not allowed');
    }

    try {
      const { stdout } = await execFileAsync('git', ['diff', 'HEAD', '--', rel], {
        cwd,
        timeout: 6000,
        maxBuffer: MAX_DIFF_BYTES * 2,
        windowsHide: true,
      });
      if (stdout.trim()) {
        return { ok: true, path: rel, diff: stdout.slice(0, MAX_DIFF_BYTES) };
      }
    } catch {}

    if (existsSync(fullTarget)) {
      const st = statSync(fullTarget);
      if (st.isFile() && st.size <= MAX_DIFF_BYTES) {
        const text = readFileSync(fullTarget, 'utf-8');
        const body = text
          .split(/\r?\n/)
          .slice(0, 400)
          .map((l) => `+${l}`)
          .join('\n');
        return {
          ok: true,
          path: rel,
          diff: `--- /dev/null\n+++ b/${rel.replace(/\\/g, '/')}\n@@ -0,0 +1 @@\n${body}`,
        };
      }
    }
    return { ok: true, path: rel, diff: '(No diff or binary file)' };
  }

  /**
   * Executes an explicit user-triggered command from an authenticated mobile session.
   */
  runQuickCommand(command, workspacePath = this.defaultWorkspace, timeoutMs = 25000) {
    const cwd = this._resolveWorkspace(workspacePath);
    const cmdStr = String(command || '').trim();
    if (!cmdStr) return Promise.reject(new Error('Empty command'));

    const isWin = process.platform === 'win32';
    const shell = isWin ? 'powershell.exe' : '/bin/sh';
    const args = isWin ? ['-NoProfile', '-Command', cmdStr] : ['-c', cmdStr];

    return new Promise((resolvePromise) => {
      const startedAt = Date.now();
      const proc = spawn(shell, args, { cwd, windowsHide: true });
      this.#activeCommandProcs.add(proc);
      let output = '';
      let truncated = false;
      let killedByTimeout = false;

      const timer = setTimeout(() => {
        killedByTimeout = true;
        try {
          proc.kill('SIGTERM');
        } catch {}
      }, timeoutMs);

      const append = (chunk) => {
        if (truncated) return;
        const text = chunk.toString('utf-8');
        if (output.length + text.length > MAX_CMD_OUTPUT) {
          const remaining = Math.max(0, MAX_CMD_OUTPUT - output.length);
          output += text.slice(0, remaining) + '\n...[output truncated]';
          truncated = true;
        } else {
          output += text;
        }
      };

      proc.stdout.on('data', append);
      proc.stderr.on('data', append);
      proc.on('error', (err) => {
        this.#activeCommandProcs.delete(proc);
        clearTimeout(timer);
        resolvePromise({
          ok: false,
          exitCode: -1,
          durationMs: Date.now() - startedAt,
          output: err.message,
        });
      });
      proc.on('close', (code) => {
        this.#activeCommandProcs.delete(proc);
        clearTimeout(timer);
        resolvePromise({
          ok: code === 0 && !killedByTimeout,
          exitCode: code ?? -1,
          timedOut: killedByTimeout,
          durationMs: Date.now() - startedAt,
          output: output.trim(),
        });
      });
    });
  }

  _resolveWorkspace(wsPath) {
    const target = normalize(wsPath || this.defaultWorkspace);
    return existsSync(target) ? resolve(target) : this.defaultWorkspace;
  }
}
