/**
 * Antigravity Multi-Window Language Server Host Registry & Workspace Discovery.
 *
 * Tracks active Antigravity 2.0 / IDE windows via Sidecar `HostHeartbeat`,
 * VS Code Extension `WorkspaceHeartbeat`, and lifecycle hooks without ever
 * exposing internal LS ports or CSRF tokens over the network.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const HOST_TTL_MS = 24 * 60 * 60 * 1000; // 24h max retention for persisted LS endpoints

export function isUserWorkspacePath(rawPath) {
  if (!rawPath || typeof rawPath !== 'string' || !rawPath.trim()) return false;
  const norm = rawPath.trim().replace(/\\/g, '/');
  if (norm.includes('/.gemini/') || norm.endsWith('/.gemini')) return false;
  return true;
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

  /**
   * @param {{ stateDir?: string, agentApiPath?: string }} [opts]
   */
  constructor(opts = {}) {
    this.agentApiPath = opts.agentApiPath || 'agentapi';
    this.#hostsFile = opts.stateDir ? join(opts.stateDir, 'hosts-runtime.json') : '';
    this.load();
  }

  load() {
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
    return Boolean(lsAddress && this.#knownHosts.has(lsAddress));
  }

  bindConversationHost(conversationId, host) {
    if (!conversationId || !host?.lsAddress || !this.#knownHosts.has(host.lsAddress)) {
      return false;
    }
    this.#conversationHosts.set(conversationId, host);
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

  pruneDeadHost(lsAddress) {
    if (!lsAddress) return;
    const deleted = this.#knownHosts.delete(lsAddress);
    for (const [convId, h] of this.#conversationHosts.entries()) {
      if (h?.lsAddress === lsAddress) {
        this.#conversationHosts.delete(convId);
      }
    }
    if (deleted) {
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
      this.save();
      return true;
    }

    return false;
  }

  getSummary({ acpAvailable = false } = {}) {
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

    addCandidate(defaultWorkspace);
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

  buildCandidateHosts(conversationId = '', workspaceHint = '') {
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
