/**
 * Sanctioned Antigravity Agent Driver:
 * Orchestrates `HostRegistry` (Tier 1 live Language Server `agentapi`),
 * `AcpSessionRunner` (Tier 2 post-sleep `agy acp` wakeup), and `WorkspaceOps`
 * (Git status/diff, mobile uploads, and bounded quick commands).
 */
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { AcpSessionRunner } from './acp-runner.mjs';
import {
  HostRegistry,
  hostMatchesWorkspace,
  isUserWorkspacePath,
  uriToFsPath,
} from './host-registry.mjs';
import { WorkspaceOps } from './workspace-ops.mjs';

const execFileAsync = promisify(execFile);
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

function isDeadHostError(err) {
  const detail = `${err?.code || ''} ${err?.stderr || ''} ${err?.stdout || ''} ${err?.message || ''}`;
  return /ECONNREFUSED|connection refused|dial tcp .* refused|actively refused/i.test(detail);
}

function isTrajectoryNotFoundText(text) {
  return /trajectory not found|code\s*=\s*NotFound|unknown conversation/i.test(String(text || ''));
}

export class AgentDriver {
  #flushingQueue = false;
  /** @type {HostRegistry} */
  #hosts;
  /** @type {WorkspaceOps} */
  #workspaceOps;
  /** @type {AcpSessionRunner} */
  #acpRunner;

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
    this.queuedMessages = new Map(); // convId -> Array<{id, prompt, workspaceHint?, createdAt}>
    this.delegatedExecutor = null; // optional async ({ action, conversationId, prompt }) => result
    this.onQueueFlushed = null; // optional ({ conversationId, messageId, result }) => void

    this.#hosts = new HostRegistry({
      stateDir: opts.stateDir,
      agentApiPath: this.agentApiPath,
      geminiDir: opts.geminiDir,
      discoverSystemHubs: opts.discoverSystemHubs,
      isProcessAlive: opts.isProcessAlive,
      inspectProcessArgs: opts.inspectProcessArgs,
    });
    if (!isUserWorkspacePath(this.defaultWorkspace)) {
      const openWs = this.#hosts.firstOpenUserWorkspace();
      if (openWs) {
        this.defaultWorkspace = openWs;
      }
    }
    this.#workspaceOps = new WorkspaceOps({
      getDefaultWorkspace: () => this.defaultWorkspace,
    });

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
  }

  getRegisteredHostsSummary() {
    return this.#hosts.getSummary({
      acpAvailable: Boolean(this.#acpRunner?.resolveAgyBinary()),
    });
  }

  setDefaultWorkspace(wsPath) {
    if (wsPath && existsSync(wsPath)) {
      this.defaultWorkspace = resolve(wsPath);
    }
    return this.defaultWorkspace;
  }

  listWorkspaces(sessions = []) {
    if (!isUserWorkspacePath(this.defaultWorkspace)) {
      const openWs = this.#hosts.firstOpenUserWorkspace();
      if (openWs) {
        this.defaultWorkspace = openWs;
      }
    }
    return this.#hosts.listWorkspaces(this.defaultWorkspace, sessions);
  }

  registerHookContext(hookPayload = {}) {
    const registeredHost = this.#hosts.registerHookContext(hookPayload);
    if (!isUserWorkspacePath(this.defaultWorkspace)) {
      const openWs = this.#hosts.firstOpenUserWorkspace();
      if (openWs) {
        this.defaultWorkspace = openWs;
      }
    }
    if (
      registeredHost &&
      this.queuedMessages.size > 0 &&
      !this.#flushingQueue &&
      hookPayload?.hookEventName !== 'PreInvocation'
    ) {
      void this.flushQueuedMessages();
    }
  }

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
    const killedCommands = this.#workspaceOps.killActiveCommands();
    return { ok: true, clearedQueued, cancelledAcp, killedCommands };
  }

  async shutdown() {
    this.#workspaceOps.clearActiveCommands();
    if (this.#acpRunner) {
      await this.#acpRunner.shutdown();
    }
  }

  saveUploadedFile(opts = {}) {
    return this.#workspaceOps.saveUploadedFile(opts);
  }

  getWorkspaceStatus(workspacePath = this.defaultWorkspace) {
    return this.#workspaceOps.getWorkspaceStatus(workspacePath);
  }

  getFileDiff(filePath, workspacePath = this.defaultWorkspace) {
    return this.#workspaceOps.getFileDiff(filePath, workspacePath);
  }

  runQuickCommand(command, workspacePath = this.defaultWorkspace, timeoutMs = 25000) {
    return this.#workspaceOps.runQuickCommand(command, workspacePath, timeoutMs);
  }

  async _inspectConversationOnHost(host, conversationId, _retriedAuth = false) {
    const cachedProjectId = this.#hosts.getVerifiedProjectId(conversationId);
    if (!conversationId) {
      return { existsOnHost: true, projectId: host.projectId || '', workspacePath: '', host };
    }

    const { file, prefixArgs } = this.#hosts.resolveAgentApiCommand(
      host.agentApiExe,
      this.agentApiPath,
    );
    try {
      const { stdout } = await execFileAsync(
        file,
        [...prefixArgs, 'get-conversation-metadata', conversationId],
        {
          timeout: 4000,
          windowsHide: true,
          env: this.#hosts.makeExecEnv(host, ''),
        },
      );
      const trimmed = stdout.trim();
      const parsed = trimmed ? JSON.parse(trimmed) : null;
      if (parsed?.error && isTrajectoryNotFoundText(parsed.error)) {
        return { existsOnHost: false, projectId: '', workspacePath: '', host };
      }
      const meta =
        parsed?.response?.conversationMetadata?.metadata ||
        parsed?.response?.conversation_metadata?.metadata;
      const resolvedId = meta?.projectId || meta?.project_id || cachedProjectId;
      if (meta?.projectId || meta?.project_id) {
        this.#hosts.setVerifiedProjectId(conversationId, resolvedId);
      }
      const wsUri =
        meta?.workspaceUris?.[0] ||
        meta?.workspaces?.[0]?.workspaceFolderAbsoluteUri ||
        '';
      return {
        existsOnHost: true,
        projectId: resolvedId,
        workspacePath: uriToFsPath(wsUri),
        host,
      };
    } catch (err) {
      if (isDeadHostError(err)) {
        this.#hosts.pruneDeadHost(host.lsAddress);
        return { existsOnHost: false, dead: true, err, host };
      }
      if (err && err.code === 'ENOENT') {
        return { existsOnHost: false, enoent: true, err, host };
      }
      const detail = `${err?.stdout || ''} ${err?.stderr || ''} ${err?.message || ''}`;
      if (isTrajectoryNotFoundText(detail)) {
        return { existsOnHost: false, notFound: true, err, host };
      }
      if (/invalid CSRF token|code\s*=\s*Unauthenticated/i.test(detail)) {
        if (!_retriedAuth) {
          this.#hosts.refreshDaemonHubs({ force: true });
          const refreshed = this.#hosts.getHost(host.lsAddress);
          if (refreshed && refreshed.csrfToken && refreshed.csrfToken !== host.csrfToken) {
            return this._inspectConversationOnHost(refreshed, conversationId, true);
          }
        }
        return { existsOnHost: false, authFailed: true, err, host };
      }
      return { existsOnHost: true, projectId: cachedProjectId, workspacePath: '', host };
    }
  }

  async hasAgentApi(conversationId = '') {
    if (this.#acpRunner?.resolveAgyBinary()) return true;
    const candidates = this.#hosts.buildCandidateHosts(conversationId);
    if (candidates.length === 0) return false;
    const first = candidates[0];
    const { file, prefixArgs } = this.#hosts.resolveAgentApiCommand(
      first.agentApiExe,
      this.agentApiPath,
    );
    try {
      await execFileAsync(file, [...prefixArgs, '--help'], {
        timeout: 2500,
        windowsHide: true,
        env: this.#hosts.makeExecEnv(first),
      });
      return true;
    } catch (err) {
      return Boolean(err && err.code !== 'ENOENT');
    }
  }

  async _trySendMessageViaHosts(conversationId, cleanPrompt, workspaceHint = '') {
    const cleanHint = isUserWorkspacePath(workspaceHint) ? workspaceHint : '';
    const queue = [...this.#hosts.buildCandidateHosts(conversationId, cleanHint)];
    const deferredAfterMatch = new Set();
    let lastErr = null;
    let discoveredWorkspace = '';

    for (let i = 0; i < queue.length; i++) {
      const candidateHost = queue[i];
      const inspection = await this._inspectConversationOnHost(candidateHost, conversationId);
      const host = inspection.host || candidateHost;
      if (inspection.workspacePath && !discoveredWorkspace) {
        discoveredWorkspace = inspection.workspacePath;
      }
      if (!inspection.existsOnHost) {
        if (inspection.err) lastErr = inspection.err;
        if (inspection.enoent) break;
        continue;
      }

      // If metadata reveals the conversation's workspace and another live IDE window explicitly owns that workspace,
      // route to that IDE window hub first so the open laptop UI updates in real time instead of cold-loading elsewhere!
      const metaWs =
        inspection.workspacePath && isUserWorkspacePath(inspection.workspacePath)
          ? inspection.workspacePath
          : '';
      const effectiveWs = metaWs || cleanHint;
      if (
        effectiveWs &&
        !hostMatchesWorkspace(host, effectiveWs) &&
        !deferredAfterMatch.has(host.lsAddress)
      ) {
        const betterIdx = queue.findIndex(
          (h, idx) => idx > i && hostMatchesWorkspace(h, effectiveWs),
        );
        if (betterIdx !== -1) {
          deferredAfterMatch.add(host.lsAddress);
          const [betterHost] = queue.splice(betterIdx, 1);
          queue.splice(i, 0, betterHost);
          i -= 1;
          continue;
        }
      }

      const { file, prefixArgs } = this.#hosts.resolveAgentApiCommand(
        host.agentApiExe,
        this.agentApiPath,
      );
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
            env: this.#hosts.makeExecEnv(host, pidToUse),
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
          if (this.#hosts.bindConversationHost(conversationId, host)) {
            this.#hosts.save();
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
            this.#hosts.setVerifiedProjectId(conversationId, exactPid, { persist: false });
            this.#hosts.bindConversationHost(conversationId, host);
            this.#hosts.save();
            return {
              ok: true,
              delivery: 'agentapi',
              targetHost: host.appName || 'antigravity',
              output: out,
            };
          }
          if (projectId) {
            const out = await runSendWithPid('');
            this.#hosts.setVerifiedProjectId(conversationId, '', { persist: false });
            this.#hosts.bindConversationHost(conversationId, host);
            this.#hosts.save();
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
          this.#hosts.pruneDeadHost(host.lsAddress);
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
    let candidates = this.#hosts.buildCandidateHosts('', normHint);
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
      const { file, prefixArgs } = this.#hosts.resolveAgentApiCommand(
        host.agentApiExe,
        this.agentApiPath,
      );
      const promptArgs = cleanPrompt.startsWith('-') ? ['--', cleanPrompt] : [cleanPrompt];
      const projectId = host.projectId || '';

      const runCreate = async (pidToUse) => {
        const { stdout, stderr } = await execFileAsync(
          file,
          [...prefixArgs, 'new-conversation', ...promptArgs],
          {
            timeout: 15000,
            windowsHide: true,
            env: this.#hosts.makeExecEnv(host, pidToUse),
          },
        );
        const out = (stdout || stderr || '').trim();
        const idMatch = UUID_RE.exec(out);
        return { out, newId: idMatch ? idMatch[0] : null };
      };

      try {
        try {
          const { out, newId } = await runCreate(projectId);
          if (newId) {
            if (projectId) {
              this.#hosts.setVerifiedProjectId(newId, projectId, { persist: false });
            }
            this.#hosts.bindConversationHost(newId, host);
            this.#hosts.save();
          }
          return {
            ok: true,
            delivery: 'agentapi',
            targetHost: host.appName || 'antigravity',
            conversationId: newId,
            output: out,
          };
        } catch (errWithPid) {
          if (projectId && errWithPid?.code !== 'ENOENT' && !isDeadHostError(errWithPid)) {
            const { out, newId } = await runCreate('');
            return {
              ok: true,
              delivery: 'agentapi',
              targetHost: host.appName || 'antigravity',
              conversationId: newId,
              output: out,
            };
          }
          throw errWithPid;
        }
      } catch (err) {
        if (isDeadHostError(err)) {
          this.#hosts.pruneDeadHost(host.lsAddress);
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
    if (attempt.ok) return attempt;

    if (this.#acpRunner?.resolveAgyBinary()) {
      const targetWorkspace =
        workspaceHint || attempt.discoveredWorkspace || this.defaultWorkspace;
      try {
        return await this.#acpRunner.sendMessage(conversationId, cleanPrompt, {
          workspace: this.#workspaceOps.resolveWorkspace(targetWorkspace),
        });
      } catch (acpErr) {
        return { ok: false, lastErr: acpErr };
      }
    }

    return attempt;
  }

  async _createDirect(cleanPrompt, targetWorkspace = '') {
    const attempt = await this._tryCreateConversationViaHosts(cleanPrompt, targetWorkspace);
    if (attempt.ok) return attempt;

    if (this.#acpRunner?.resolveAgyBinary()) {
      try {
        return await this.#acpRunner.createConversation(cleanPrompt, {
          workspace: this.#workspaceOps.resolveWorkspace(targetWorkspace),
        });
      } catch (acpErr) {
        return { ok: false, lastErr: acpErr };
      }
    }

    return attempt;
  }

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
    if (direct.ok) return direct;

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
    if (direct.ok) return direct;

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
}
