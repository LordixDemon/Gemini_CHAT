/**
 * Antigravity Multi-Window Language Server Host Registry & Workspace Discovery.
 *
 * Tracks active Antigravity 2.0 / IDE windows via Sidecar `HostHeartbeat`,
 * VS Code Extension `WorkspaceHeartbeat`, and lifecycle hooks without ever
 * exposing internal LS ports or CSRF tokens over the network.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const HOST_TTL_MS = 24 * 60 * 60 * 1000; // 24h max retention for persisted LS endpoints
const DAEMON_REFRESH_THROTTLE_MS = 2500;

export function isUserWorkspacePath(rawPath) {
  if (!rawPath || typeof rawPath !== 'string' || !rawPath.trim()) return false;
  const norm = rawPath.trim().replace(/\\/g, '/');
  if (norm.includes('/.gemini/') || norm.endsWith('/.gemini')) return false;
  return true;
}

export function hostMatchesWorkspace(host, rawHint = '') {
  const normHint = String(rawHint || '').replace(/\\/g, '/').replace(/\/+$/, '');
  if (!normHint || !Array.isArray(host?.workspacePaths) || host.workspacePaths.length === 0) {
    return false;
  }
  return host.workspacePaths.some((wp) => {
    const normWp = String(wp || '').replace(/\\/g, '/').replace(/\/+$/, '');
    return Boolean(normWp) && (normHint.startsWith(normWp) || normWp.startsWith(normHint));
  });
}

export function extractLoopbackPort(lsAddress = '') {
  const m = /^(?:localhost|127\.0\.0\.1|\[::1\]):(\d+)$/i.exec(String(lsAddress || '').trim());
  return m ? Number(m[1]) : 0;
}

export function canonicalizeLoopbackAddress(lsAddress = '') {
  const trimmed = String(lsAddress || '').trim();
  if (!trimmed) return '';
  const port = extractLoopbackPort(trimmed);
  return port > 0 ? `127.0.0.1:${port}` : trimmed;
}

export function parseHubProcessCommand(rawCommand = '') {
  const cmd = String(rawCommand || '').trim();
  if (!cmd) return { appName: 'antigravity', workspacePaths: [] };
  const isIdeHub = /(?:^|\s)--hub(?:\s|=|$)/.test(cmd);
  const workspacePaths = [];
  const addDirRe = /(?:^|\s)--add-dir(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))/g;
  let match;
  while ((match = addDirRe.exec(cmd)) !== null) {
    const rawDir = (match[1] || match[2] || match[3] || '').trim();
    if (rawDir && isUserWorkspacePath(rawDir)) {
      workspacePaths.push(resolve(rawDir));
    }
  }
  return {
    appName: isIdeHub ? 'antigravity-ide' : 'antigravity',
    workspacePaths: [...new Set(workspacePaths)],
  };
}

function defaultIsProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err?.code === 'EPERM';
  }
}

function defaultInspectProcessArgs(pid) {
  if (process.platform === 'win32' || !Number.isInteger(pid) || pid <= 0) return '';
  try {
    return execFileSync('ps', ['-p', String(pid), '-o', 'command='], {
      encoding: 'utf-8',
      timeout: 1200,
      windowsHide: true,
    }).trim();
  } catch {
    return '';
  }
}

export function uriToFsPath(uriOrPath) {
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

export class HostRegistry {
  /** @type {Map<string, { lsAddress: string, csrfToken: string, agentApiExe: string, projectId: string, appName: string, workspacePaths: string[], updatedAt: number }>} */
  #conversationHosts = new Map();

  /** @type {Map<string, { lsAddress: string, csrfToken: string, agentApiExe: string, projectId: string, appName: string, workspacePaths: string[], updatedAt: number }>} */
  #knownHosts = new Map();

  /** @type {Map<string, string>} */
  #verifiedProjectIds = new Map();

  /** @type {Map<string, number>} */
  #openWorkspaces = new Map();

  #hostsFile = '';
  #geminiDir = '';
  #discoverSystemHubs = true;
  #lastDaemonRefreshAt = 0;
  /** @type {Map<number, { appName: string, workspacePaths: string[] }>} */
  #pidInfoCache = new Map();
  #isProcessAlive = defaultIsProcessAlive;
  #inspectProcessArgs = defaultInspectProcessArgs;

  /**
   * @param {{
   *   stateDir?: string,
   *   agentApiPath?: string,
   *   geminiDir?: string,
   *   discoverSystemHubs?: boolean,
   *   isProcessAlive?: (pid: number) => boolean,
   *   inspectProcessArgs?: (pid: number) => string
   * }} [opts]
   */
  constructor(opts = {}) {
    this.agentApiPath = opts.agentApiPath || 'agentapi';
    this.#hostsFile = opts.stateDir ? join(opts.stateDir, 'hosts-runtime.json') : '';
    this.#geminiDir =
      opts.geminiDir ||
      (opts.stateDir ? dirname(resolve(opts.stateDir)) : join(homedir(), '.gemini'));
    const customMockApiOnly = Boolean(
      opts.agentApiPath && opts.agentApiPath !== 'agentapi' && !opts.geminiDir,
    );
    this.#discoverSystemHubs =
      opts.discoverSystemHubs !== undefined ? Boolean(opts.discoverSystemHubs) : !customMockApiOnly;
    if (typeof opts.isProcessAlive === 'function') {
      this.#isProcessAlive = opts.isProcessAlive;
    }
    if (typeof opts.inspectProcessArgs === 'function') {
      this.#inspectProcessArgs = opts.inspectProcessArgs;
    }
    this.load();
    if (this.#discoverSystemHubs) {
      this.refreshDaemonHubs({ force: true });
    }
  }

  load() {
    if (!this.#hostsFile || !existsSync(this.#hostsFile)) return;
    try {
      const parsed = JSON.parse(readFileSync(this.#hostsFile, 'utf-8'));
      const cutoff = Date.now() - HOST_TTL_MS;
      if (Array.isArray(parsed?.hosts)) {
        for (const h of parsed.hosts) {
          if (h && typeof h.lsAddress === 'string' && h.lsAddress.trim() && (h.updatedAt || 0) >= cutoff) {
            const addr = canonicalizeLoopbackAddress(h.lsAddress);
            if (!addr) continue;
            const prev = this.#knownHosts.get(addr);
            const hUpdated = Number(h.updatedAt) || Date.now();
            const ws = Array.isArray(h.workspacePaths) ? h.workspacePaths.filter((p) => isUserWorkspacePath(p)) : [];
            const mergedWs = prev ? [...new Set([...prev.workspacePaths, ...ws])] : ws;
            const newer = !prev || hUpdated >= prev.updatedAt;
            const appName =
              h.appName === 'antigravity-ide' || prev?.appName === 'antigravity-ide'
                ? 'antigravity-ide'
                : newer
                  ? (typeof h.appName === 'string' && h.appName) || prev?.appName || 'antigravity'
                  : prev?.appName || (typeof h.appName === 'string' && h.appName) || 'antigravity';
            this.#knownHosts.set(addr, {
              lsAddress: addr,
              csrfToken: newer
                ? (typeof h.csrfToken === 'string' && h.csrfToken) || prev?.csrfToken || ''
                : prev?.csrfToken || (typeof h.csrfToken === 'string' ? h.csrfToken : ''),
              agentApiExe: newer
                ? (typeof h.agentApiExe === 'string' && h.agentApiExe) || prev?.agentApiExe || ''
                : prev?.agentApiExe || (typeof h.agentApiExe === 'string' ? h.agentApiExe : ''),
              projectId: newer
                ? (typeof h.projectId === 'string' && h.projectId) || prev?.projectId || ''
                : prev?.projectId || (typeof h.projectId === 'string' ? h.projectId : ''),
              appName,
              workspacePaths: mergedWs,
              updatedAt: Math.max(hUpdated, prev?.updatedAt || 0),
              lastHookAt: Math.max(Number(h.lastHookAt) || 0, prev?.lastHookAt || 0),
            });
          }
        }
      }
      if (parsed?.conversations && typeof parsed.conversations === 'object') {
        for (const [convId, lsAddr] of Object.entries(parsed.conversations)) {
          const canon = typeof lsAddr === 'string' ? canonicalizeLoopbackAddress(lsAddr) : '';
          const host = canon ? this.#knownHosts.get(canon) : null;
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

  save() {
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

  hasKnownHost(lsAddress) {
    const canon = canonicalizeLoopbackAddress(lsAddress);
    return Boolean(canon && this.#knownHosts.has(canon));
  }

  getHost(lsAddress) {
    const canon = canonicalizeLoopbackAddress(lsAddress);
    if (!canon) return null;
    if (this.#knownHosts.has(canon)) return this.#knownHosts.get(canon) || null;
    const port = extractLoopbackPort(canon);
    if (port > 0) {
      for (const h of this.#knownHosts.values()) {
        if (extractLoopbackPort(h.lsAddress) === port) return h;
      }
    }
    return null;
  }

  /**
   * Discovers active Antigravity IDE / Desktop hubs from `<geminiDir>/<surface>/daemon/hub_*.json`
   * so open IDE workspace windows (`agy --hub --add-dir=...`) and rotated CSRF tokens are always live
   * even before any hook fires in that window.
   */
  refreshDaemonHubs({ force = false } = {}) {
    if (!this.#discoverSystemHubs || !this.#geminiDir || !existsSync(this.#geminiDir)) {
      return false;
    }
    const now = Date.now();
    if (!force && now - this.#lastDaemonRefreshAt < DAEMON_REFRESH_THROTTLE_MS) {
      return false;
    }
    this.#lastDaemonRefreshAt = now;

    let mutated = false;
    let surfaces = [];
    try {
      surfaces = readdirSync(this.#geminiDir);
    } catch {
      return false;
    }

    let foundAnyDaemonDir = false;
    const livePorts = new Set();

    for (const surface of surfaces) {
      const daemonDir = join(this.#geminiDir, surface, 'daemon');
      if (!existsSync(daemonDir)) continue;
      foundAnyDaemonDir = true;
      let files = [];
      try {
        files = readdirSync(daemonDir).filter((f) => /^hub_\d+\.json$/i.test(f));
      } catch {
        continue;
      }

      for (const file of files) {
        let hub;
        try {
          hub = JSON.parse(readFileSync(join(daemonDir, file), 'utf-8'));
        } catch {
          continue;
        }
        const pid = Number(hub?.pid) || 0;
        const httpPort = Number(hub?.httpPort) || 0;
        const csrfToken = typeof hub?.csrfToken === 'string' ? hub.csrfToken.trim() : '';
        if (httpPort <= 0 || !csrfToken) continue;

        let existingKey = '';
        for (const k of this.#knownHosts.keys()) {
          if (extractLoopbackPort(k) === httpPort) {
            existingKey = k;
            break;
          }
        }

        if (!this.#isProcessAlive(pid)) {
          this.#pidInfoCache.delete(pid);
          if (existingKey) {
            this.pruneDeadHost(existingKey, { persist: false });
            mutated = true;
          }
          continue;
        }

        livePorts.add(httpPort);

        let procInfo = this.#pidInfoCache.get(pid);
        if (!procInfo) {
          const cmd = this.#inspectProcessArgs(pid);
          procInfo = parseHubProcessCommand(cmd);
          this.#pidInfoCache.set(pid, procInfo);
        }

        const prev = existingKey ? this.#knownHosts.get(existingKey) : null;
        const lsAddress = `127.0.0.1:${httpPort}`;
        if (existingKey && existingKey !== lsAddress) {
          this.#knownHosts.delete(existingKey);
          mutated = true;
        }

        const mergedWorkspaces =
          procInfo.workspacePaths.length > 0
            ? [...new Set([...procInfo.workspacePaths, ...(prev?.workspacePaths || []).filter(isUserWorkspacePath)])]
            : (prev?.workspacePaths || []).filter(isUserWorkspacePath);
        const appName =
          procInfo.appName === 'antigravity-ide'
            ? 'antigravity-ide'
            : prev?.appName || procInfo.appName || 'antigravity';

        for (const wp of procInfo.workspacePaths) {
          this.#openWorkspaces.set(wp, now);
        }

        const changed =
          !prev ||
          prev.csrfToken !== csrfToken ||
          prev.appName !== appName ||
          prev.workspacePaths.length !== mergedWorkspaces.length ||
          prev.workspacePaths.some((p, i) => p !== mergedWorkspaces[i]);

        const record = {
          lsAddress,
          csrfToken,
          agentApiExe: prev?.agentApiExe || '',
          projectId: prev?.projectId || '',
          appName,
          workspacePaths: mergedWorkspaces,
          updatedAt: prev?.updatedAt || now,
          lastHookAt: prev?.lastHookAt || 0,
        };
        this.#knownHosts.set(lsAddress, record);

        for (const [convId, bound] of this.#conversationHosts.entries()) {
          if (bound?.lsAddress === lsAddress || (existingKey && bound?.lsAddress === existingKey)) {
            this.#conversationHosts.set(convId, record);
          }
        }

        if (changed) {
          mutated = true;
        }
      }
    }

    if (foundAnyDaemonDir) {
      for (const [addr, rec] of [...this.#knownHosts.entries()]) {
        const port = extractLoopbackPort(addr);
        if (port > 0 && !livePorts.has(port) && now - (rec.lastHookAt || 0) >= 180_000) {
          this.pruneDeadHost(addr, { persist: false });
          mutated = true;
        }
      }
    }

    if (mutated) {
      this.save();
    }
    return mutated;
  }

  bindConversationHost(conversationId, host) {
    const canon = canonicalizeLoopbackAddress(host?.lsAddress);
    if (!conversationId || !canon || !this.#knownHosts.has(canon)) {
      return false;
    }
    this.#conversationHosts.set(conversationId, this.#knownHosts.get(canon) || host);
    return true;
  }

  getVerifiedProjectId(conversationId) {
    return conversationId ? this.#verifiedProjectIds.get(conversationId) || '' : '';
  }

  setVerifiedProjectId(conversationId, projectId, { persist = true } = {}) {
    if (!conversationId) return;
    if (projectId) {
      this.#verifiedProjectIds.set(conversationId, projectId);
    } else {
      this.#verifiedProjectIds.delete(conversationId);
    }
    if (persist) {
      this.save();
    }
  }

  pruneDeadHost(lsAddress, { persist = true } = {}) {
    if (!lsAddress) return;
    const canon = canonicalizeLoopbackAddress(lsAddress);
    const port = extractLoopbackPort(lsAddress);
    let deleted = false;
    for (const key of [...this.#knownHosts.keys()]) {
      if (key === lsAddress || (canon && key === canon) || (port > 0 && extractLoopbackPort(key) === port)) {
        this.#knownHosts.delete(key);
        deleted = true;
      }
    }
    for (const [convId, h] of this.#conversationHosts.entries()) {
      const hPort = extractLoopbackPort(h?.lsAddress);
      if (h?.lsAddress === lsAddress || (canon && h?.lsAddress === canon) || (port > 0 && hPort === port)) {
        this.#conversationHosts.delete(convId);
      }
    }
    if (deleted && persist) {
      this.save();
    }
  }

  /**
   * Records open workspace paths and/or Antigravity Language Server host context.
   * Returns `true` when an active LS host record was registered/refreshed.
   */
  registerHookContext(hookPayload = {}) {
    if (!hookPayload || typeof hookPayload !== 'object') return false;
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
      const canonAddr = canonicalizeLoopbackAddress(hc.lsAddress);
      if (!canonAddr) return false;
      const prev = this.#knownHosts.get(canonAddr);
      const mergedWorkspaces = [
        ...new Set([...(prev?.workspacePaths || []).filter(isUserWorkspacePath), ...validUserWorkspaces]),
      ];
      const hostProjectId =
        (typeof hc.projectId === 'string' && hc.projectId.trim()) || prev?.projectId || '';

      const record = {
        lsAddress: canonAddr,
        csrfToken: typeof hc.csrfToken === 'string' && hc.csrfToken ? hc.csrfToken : prev?.csrfToken || '',
        agentApiExe: typeof hc.agentApiExe === 'string' && hc.agentApiExe ? hc.agentApiExe : prev?.agentApiExe || '',
        projectId: hostProjectId,
        appName: typeof hc.appName === 'string' && hc.appName ? hc.appName : prev?.appName || 'antigravity',
        workspacePaths: mergedWorkspaces,
        updatedAt: now,
        lastHookAt: now,
      };
      this.#knownHosts.set(record.lsAddress, record);
      if (convId) {
        this.#conversationHosts.set(convId, record);
      }
      this.save();
      return true;
    }

    return false;
  }

  getSummary({ acpAvailable = false } = {}) {
    this.refreshDaemonHubs();
    const hosts = [...this.#knownHosts.values()]
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .map((h) => ({
        appName: h.appName || 'antigravity',
        workspacePaths: h.workspacePaths || [],
        updatedAt: h.updatedAt,
      }));
    return {
      count: hosts.length + (process.env.ANTIGRAVITY_LS_ADDRESS ? 1 : 0),
      acpAvailable: Boolean(acpAvailable),
      hosts,
    };
  }

  listWorkspaces(defaultWorkspace, sessions = []) {
    this.refreshDaemonHubs();
    const map = new Map();
    const homeNorm = homedir().replace(/\\/g, '/').replace(/\/+$/, '');
    const defaultAbs = resolve(defaultWorkspace);
    const addCandidate = (rawPath, { isOpenInHost = false } = {}) => {
      if (!rawPath || typeof rawPath !== 'string' || !rawPath.trim()) return;
      if (rawPath !== defaultWorkspace && !isUserWorkspacePath(rawPath)) return;
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

    if (isUserWorkspacePath(defaultWorkspace)) {
      addCandidate(defaultWorkspace);
    }
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

  firstOpenUserWorkspace() {
    this.refreshDaemonHubs();
    const sortedHosts = [...this.#knownHosts.values()].sort((a, b) => b.updatedAt - a.updatedAt);
    for (const h of sortedHosts) {
      for (const wp of h.workspacePaths || []) {
        if (isUserWorkspacePath(wp) && existsSync(wp)) {
          return resolve(wp);
        }
      }
    }
    let bestPath = '';
    let bestTs = 0;
    for (const [wp, ts] of this.#openWorkspaces.entries()) {
      if (ts > bestTs && isUserWorkspacePath(wp) && existsSync(wp)) {
        bestPath = resolve(wp);
        bestTs = ts;
      }
    }
    return bestPath;
  }

  buildCandidateHosts(conversationId = '', workspaceHint = '') {
    this.refreshDaemonHubs();
    const out = [];
    const seen = new Set();
    const pushHost = (h) => {
      if (!h || !h.lsAddress || seen.has(h.lsAddress)) return;
      seen.add(h.lsAddress);
      out.push(h);
    };

    const bound = conversationId ? this.#conversationHosts.get(conversationId) || null : null;
    const normHint = isUserWorkspacePath(workspaceHint)
      ? String(workspaceHint).replace(/\\/g, '/').replace(/\/+$/, '')
      : '';

    if (normHint) {
      const matching = [...this.#knownHosts.values()]
        .filter((h) => hostMatchesWorkspace(h, normHint))
        .sort((a, b) => b.updatedAt - a.updatedAt);

      if (matching.length > 0) {
        if (bound && hostMatchesWorkspace(bound, normHint)) {
          pushHost(bound);
        }
        for (const h of matching) pushHost(h);
      }
    }

    if (bound) {
      pushHost(bound);
    }

    if (process.env.ANTIGRAVITY_LS_ADDRESS) {
      pushHost({
        lsAddress: canonicalizeLoopbackAddress(process.env.ANTIGRAVITY_LS_ADDRESS),
        csrfToken: process.env.ANTIGRAVITY_CSRF_TOKEN || '',
        agentApiExe: process.env.ANTIGRAVITY_AGENTAPI_EXE || '',
        projectId: process.env.ANTIGRAVITY_PROJECT_ID || '',
        appName: process.env.ANTIGRAVITY_AUTH_SUCCESS_APP || 'sidecar',
        workspacePaths: [],
        updatedAt: 0,
      });
    }

    // Prefer neutral hosts (e.g. standalone Antigravity) ahead of hosts explicitly bound to a different workspace
    const allKnown = [...this.#knownHosts.values()].sort((a, b) => b.updatedAt - a.updatedAt);
    if (normHint) {
      for (const h of allKnown) {
        if (!h.workspacePaths || h.workspacePaths.length === 0) pushHost(h);
      }
    }
    for (const h of allKnown) pushHost(h);

    return out;
  }

  resolveAgentApiCommand(preferredExe = '', agentApiPathOverride = this.agentApiPath) {
    if (agentApiPathOverride && agentApiPathOverride !== 'agentapi') {
      return { file: agentApiPathOverride, prefixArgs: [] };
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
    return { file: agentApiPathOverride || 'agentapi', prefixArgs: [] };
  }

  /**
   * Builds a sanitized child environment for `agentapi` — stripping inherited
   * `ANTIGRAVITY_*` / `AGY_ENABLE_HUB` variables so cross-workspace `send-message`
   * calls never fail with `source project_id` mismatch.
   */
  makeExecEnv(host, explicitProjectId = null) {
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
}
