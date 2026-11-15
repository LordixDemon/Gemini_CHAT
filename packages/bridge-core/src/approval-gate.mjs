/**
 * Remote Tool Approval Gatekeeper (`PreToolUse` hook coordinator).
 * Allows the user to approve or block sensitive Antigravity tool executions
 * (`run_command`, `write_file`, `edit_file`) directly from their phone!
 */
import { randomBytes } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { cleanArgsObject, isSafeCommand, summarizeToolCall } from '@agy-remote/protocol';

export class ApprovalGate extends EventEmitter {
  /**
   * @param {{
   *   getMode: () => string,
   *   hasActiveMobileClients: () => boolean,
   *   defaultTimeoutMs?: number,
   *   changeTracker?: import('./change-tracker.mjs').ChangeTracker | null,
   *   getDefaultWorkspace?: () => string
   * }} opts
   */
  constructor(opts) {
    super();
    this.getMode = opts.getMode;
    this.hasActiveMobileClients = opts.hasActiveMobileClients;
    this.defaultTimeoutMs = opts.defaultTimeoutMs || 50_000;
    this.changeTracker = opts.changeTracker || null;
    this.getDefaultWorkspace = opts.getDefaultWorkspace || (() => '');
    this.pending = new Map(); // id -> { item, resolve, timer }
    this.history = [];
    this.sessionAllowRules = new Set(); // `${conversationId}:${toolName}`
    this.stoppedConversations = new Map(); // convId ('*' for all) -> expiresAtMs
  }

  /**
   * Sets an immediate mobile Stop/Interrupt latch for `conversationId` and denies any
   * currently pending `PreToolUse` approval for that session.
   */
  requestStop(conversationId = '', byDevice = 'Antigravity Mobile') {
    const key = conversationId && conversationId.trim() ? conversationId.trim() : '*';
    this.stoppedConversations.set(key, Date.now() + 15 * 60_000);

    const matchingIds = [];
    for (const [id, entry] of this.pending.entries()) {
      if (key === '*' || entry.item.conversationId === key) {
        matchingIds.push(id);
      }
    }
    const batch = matchingIds.length > 0
      ? this.decideBatch({
          ids: matchingIds,
          decision: 'deny',
          reason: `Остановлено пользователем с ${byDevice}.`,
          byDevice,
        })
      : { count: 0, resolved: [] };

    return { ok: true, conversationId: key, abortedApprovals: batch.count };
  }

  clearStop(conversationId = '') {
    this.stoppedConversations.delete('*');
    if (conversationId) {
      this.stoppedConversations.delete(conversationId);
    }
  }

  isConversationStopped(conversationId = '') {
    const now = Date.now();
    for (const [k, exp] of this.stoppedConversations.entries()) {
      if (exp <= now) {
        this.stoppedConversations.delete(k);
      }
    }
    return (
      this.stoppedConversations.has('*') ||
      (Boolean(conversationId) && this.stoppedConversations.has(conversationId))
    );
  }

  _isConversationStopped(conversationId = '') {
    return this.isConversationStopped(conversationId);
  }

  listPending() {
    return [...this.pending.values()].map((entry) => entry.item);
  }

  listHistory(limit = 25) {
    return this.history.slice(-limit).reverse();
  }

  /**
   * Evaluates a `PreToolUse` payload coming from `hooks/gatekeeper.mjs`.
   * Returns an Antigravity-compliant Hook stdout object:
   *   `{ decision: 'allow' | 'deny' | 'ask', reason?: string }`
   */
  async evaluateHook(hookPayload = {}, timeoutMs = this.defaultTimeoutMs) {
    const mode = this.getMode() || 'ask-mobile';
    const tc = hookPayload.toolCall || {};
    const toolName = tc.name || 'unknown_tool';
    const args = cleanArgsObject(tc.args);
    const conversationId = hookPayload.conversationId || 'global';
    const summary = summarizeToolCall({ name: toolName, args });

    // 0. Mobile Stop/Interrupt latch: immediately abort tool execution so the agent halts its loop cleanly!
    if (this._isConversationStopped(conversationId)) {
      const stopReason =
        'Выполнение остановлено пользователем с телефона (кнопка «Стоп»). Немедленно прекрати вызов инструментов и дождись следующего сообщения пользователя.';
      this._recordHistory({ toolName, summary, conversationId, decision: 'deny (mobile stop)' });
      return { decision: 'deny', reason: stopReason };
    }

    const fileCheck =
      this.changeTracker && (toolName === 'write_file' || toolName === 'edit_file')
        ? this.changeTracker.classifyFileTool(hookPayload, this.getDefaultWorkspace())
        : null;

    // 1. Native Antigravity-style non-blocking workspace file staging:
    //    Snapshot pre-edit baseline and let workspace / brain artifact writes proceed immediately
    //    (without forcing Desktop or Mobile per-file modal popups!). Users review the unified
    //    changed-files list and tap "Save All" or "Revert".
    if (fileCheck?.kind === 'artifact') {
      this._recordHistory({ toolName, summary, conversationId, decision: 'allow (artifact)' });
      return {
        decision: 'allow',
        reason: 'Auto-approved Antigravity session artifact.',
      };
    }
    if (fileCheck?.kind === 'workspace') {
      this.changeTracker.captureBeforeWrite({
        ...fileCheck,
        conversationId,
        hookPayload,
      });
      this._recordHistory({ toolName, summary, conversationId, decision: 'allow (staged)' });
      return {
        decision: 'allow',
        reason: 'Staged in Antigravity Remote Pending Changes.',
      };
    }

    // 2. Observe mode: never hold up execution; emit live telemetry only
    if (mode === 'observe') {
      this._recordHistory({ toolName, summary, conversationId, decision: 'ask (observe)' });
      return { decision: 'ask' };
    }

    // 3. Session-scoped "Always Allow" granted earlier from mobile
    const ruleKey = `${conversationId}:${toolName}`;
    if (this.sessionAllowRules.has(ruleKey)) {
      this._recordHistory({ toolName, summary, conversationId, decision: 'allow (session rule)' });
      return {
        decision: 'allow',
        reason: `Allowed by mobile session rule for ${toolName}.`,
      };
    }

    // 4. Auto-safe mode: automatically allow verified read/test commands
    if (mode === 'auto-safe' && toolName === 'run_command' && isSafeCommand(args.CommandLine)) {
      this._recordHistory({ toolName, summary, conversationId, decision: 'allow (auto-safe)' });
      return {
        decision: 'allow',
        reason: 'Auto-approved safe read/test command by Antigravity Remote.',
      };
    }

    // 5. If no mobile device is actively connected, fall back immediately to desktop 'ask'
    if (!this.hasActiveMobileClients()) {
      return { decision: 'ask' };
    }

    // 6. Hold hook & push real-time interactive approval request to mobile clients
    const id = `apr_${randomBytes(6).toString('hex')}`;
    const now = Date.now();
    const item = {
      id,
      conversationId,
      toolName,
      summary,
      args,
      cwd: hookPayload.cwd || (hookPayload.workspacePaths && hookPayload.workspacePaths[0]) || '',
      createdAt: now,
      expiresAt: now + timeoutMs,
    };

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this._recordHistory({ ...item, decision: 'timeout_fallback_ask' });
        this.emit('approval_resolved', { id, decision: 'ask', reason: 'Timed out waiting for mobile' });
        resolve({ decision: 'ask' });
      }, timeoutMs);

      this.pending.set(id, { item, resolve, timer });
      this.emit('approval_requested', item);
    });
  }

  /**
   * Resolves a pending approval from a mobile user's tap.
   * @param {{ id: string, decision: 'allow' | 'allow_session' | 'deny' | 'ask', reason?: string, byDevice?: string }} input
   */
  decide(input) {
    const entry = this.pending.get(input?.id);
    if (!entry) return { ok: false, error: 'Approval request not found or already resolved.' };

    clearTimeout(entry.timer);
    this.pending.delete(input.id);

    let hookDecision = 'ask';
    let reason = input.reason || '';

    if (input.decision === 'allow' || input.decision === 'allow_session') {
      hookDecision = 'allow';
      if (input.decision === 'allow_session') {
        this.sessionAllowRules.add(`${entry.item.conversationId}:${entry.item.toolName}`);
      }
      reason = reason || `Approved remotely via ${input.byDevice || 'Antigravity Mobile'}.`;
    } else if (input.decision === 'deny') {
      hookDecision = 'deny';
      reason = reason || `Blocked remotely via ${input.byDevice || 'Antigravity Mobile'}.`;
    }

    const record = {
      ...entry.item,
      decision: hookDecision,
      reason,
      byDevice: input.byDevice || 'mobile',
      resolvedAt: Date.now(),
    };
    this._recordHistory(record);
    this.emit('approval_resolved', record);
    entry.resolve({ decision: hookDecision, reason });

    return { ok: true, resolved: record };
  }

  /**
   * Resolves multiple (or all) pending approvals in one tap ("Сохранить всё / Разрешить всё").
   * @param {{ ids?: string[], decision: 'allow' | 'allow_session' | 'deny' | 'ask', reason?: string, byDevice?: string }} [input]
   */
  decideBatch(input = {}) {
    const targetIds =
      Array.isArray(input?.ids) && input.ids.length > 0
        ? input.ids
        : [...this.pending.keys()];
    const resolved = [];
    for (const id of targetIds) {
      const res = this.decide({
        id,
        decision: input.decision,
        reason: input.reason,
        byDevice: input.byDevice,
      });
      if (res.ok && res.resolved) {
        resolved.push(res.resolved);
      }
    }
    return { ok: true, count: resolved.length, resolved };
  }

  _recordHistory(entry) {
    this.history.push({ ...entry, ts: Date.now() });
    if (this.history.length > 100) this.history.shift();
  }
}

