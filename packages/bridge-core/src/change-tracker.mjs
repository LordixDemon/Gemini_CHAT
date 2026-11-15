/**
 * Native Antigravity-style Pending File Changes Tracker (`ChangeTracker`).
 *
 * Instead of interrupting the user with blocking modal popups before every single
 * `write_file` / `edit_file` tool call, snapshots the pre-edit baseline of workspace
 * files and streams a live "Files Changed" review list to Mobile / PWA / IDE with:
 *  - One-tap "Save All" (`saveChanges`) and single-file accept
 *  - Per-file or bulk "Revert" (`revertChanges`) back to exact pre-agent bytes
 *  - Unified diff + `+additions / -deletions` computed directly against the pre-edit snapshot
 */
import { EventEmitter } from 'node:events';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, normalize, relative, resolve } from 'node:path';
import { cleanArgsObject } from '@agy-remote/protocol';

const MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024; // 2 MiB per file baseline cap
const MAX_DIFF_CHARS = 96 * 1024;

function normalizeSlashes(p) {
  return String(p || '').replace(/\\/g, '/');
}

function isInsideDir(targetAbs, dirAbs) {
  if (!dirAbs) return false;
  const rel = relative(resolve(dirAbs), resolve(targetAbs));
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}

/**
 * Computes compact line addition/deletion counts and a unified diff string
 * between `beforeText` and `afterText`.
 */
export function computeUnifiedTextDiff(relPath, beforeText, afterText, existedBefore, existsAfter) {
  const cleanRel = normalizeSlashes(relPath);
  if (!existedBefore && existsAfter) {
    const lines = afterText.length ? afterText.split(/\r?\n/) : [];
    const preview = lines
      .slice(0, 400)
      .map((l) => `+${l}`)
      .join('\n');
    return {
      additions: lines.length,
      deletions: 0,
      diff: `--- /dev/null\n+++ b/${cleanRel}\n@@ -0,0 +1,${lines.length} @@\n${preview}`.slice(
        0,
        MAX_DIFF_CHARS,
      ),
    };
  }

  if (existedBefore && !existsAfter) {
    const lines = beforeText.length ? beforeText.split(/\r?\n/) : [];
    const preview = lines
      .slice(0, 400)
      .map((l) => `-${l}`)
      .join('\n');
    return {
      additions: 0,
      deletions: lines.length,
      diff: `--- a/${cleanRel}\n+++ /dev/null\n@@ -1,${lines.length} +0,0 @@\n${preview}`.slice(
        0,
        MAX_DIFF_CHARS,
      ),
    };
  }

  const oldLines = beforeText.split(/\r?\n/);
  const newLines = afterText.split(/\r?\n/);

  // Trim common prefix and suffix for fast, clean hunks even on large files
  let prefix = 0;
  while (
    prefix < oldLines.length &&
    prefix < newLines.length &&
    oldLines[prefix] === newLines[prefix]
  ) {
    prefix++;
  }

  let oldEnd = oldLines.length - 1;
  let newEnd = newLines.length - 1;
  while (oldEnd >= prefix && newEnd >= prefix && oldLines[oldEnd] === newLines[newEnd]) {
    oldEnd--;
    newEnd--;
  }

  const removedMid = oldLines.slice(prefix, oldEnd + 1);
  const addedMid = newLines.slice(prefix, newEnd + 1);

  // Exclude identical lines that merely shifted inside the changed block for accurate +/- counts
  const remainOld = new Map();
  for (const line of removedMid) {
    remainOld.set(line, (remainOld.get(line) || 0) + 1);
  }
  let sharedInMiddle = 0;
  for (const line of addedMid) {
    const count = remainOld.get(line) || 0;
    if (count > 0) {
      sharedInMiddle++;
      remainOld.set(line, count - 1);
    }
  }

  const additions = Math.max(0, addedMid.length - sharedInMiddle);
  const deletions = Math.max(0, removedMid.length - sharedInMiddle);

  const ctxBefore = oldLines.slice(Math.max(0, prefix - 3), prefix);
  const ctxAfter = newLines.slice(newEnd + 1, Math.min(newLines.length, newEnd + 4));
  const hunkStartOld = Math.max(1, prefix - ctxBefore.length + 1);
  const hunkStartNew = Math.max(1, prefix - ctxBefore.length + 1);

  const outLines = [
    `--- a/${cleanRel}`,
    `+++ b/${cleanRel}`,
    `@@ -${hunkStartOld},${ctxBefore.length + removedMid.length + ctxAfter.length} +${hunkStartNew},${ctxBefore.length + addedMid.length + ctxAfter.length} @@`,
    ...ctxBefore.map((l) => ` ${l}`),
    ...removedMid.slice(0, 300).map((l) => `-${l}`),
    ...addedMid.slice(0, 300).map((l) => `+${l}`),
    ...ctxAfter.map((l) => ` ${l}`),
  ];

  return {
    additions,
    deletions,
    diff: outLines.join('\n').slice(0, MAX_DIFF_CHARS),
  };
}

export class ChangeTracker extends EventEmitter {
  constructor() {
    super();
    /**
     * @type {Map<string, {
     *   absPath: string,
     *   path: string,
     *   workspace: string,
     *   existedBefore: boolean,
     *   originalBuffer: Buffer | null,
     *   tooLarge: boolean,
     *   status: 'NEW' | 'MOD' | 'DEL',
     *   additions: number,
     *   deletions: number,
     *   conversationId: string,
     *   updatedAt: number,
     *   staged: boolean
     * }>}
     */
    this.pending = new Map();
    /** @type {Map<string, Set<ReturnType<typeof setTimeout>>>} */
    this._finalizeTimers = new Map();
  }

  clearTimers() {
    for (const set of this._finalizeTimers.values()) {
      for (const t of set) clearTimeout(t);
    }
    this._finalizeTimers.clear();
  }

  _clearTimersFor(absPath) {
    const set = this._finalizeTimers.get(absPath);
    if (!set) return;
    for (const t of set) clearTimeout(t);
    this._finalizeTimers.delete(absPath);
  }

  _scheduleAutoFinalize(absPath, hookPayload, workspaceRoot) {
    this._clearTimersFor(absPath);
    const timers = new Set();
    this._finalizeTimers.set(absPath, timers);

    for (const delayMs of [200, 750, 2200]) {
      const timer = setTimeout(() => {
        timers.delete(timer);
        if (timers.size === 0) this._finalizeTimers.delete(absPath);
        const entry = this.pending.get(absPath);
        if (!entry) return;
        const isFinalAttempt = delayMs === 2200;
        this._syncEntryFromDisk(entry, { dropIfUnchanged: isFinalAttempt });
      }, delayMs);
      timer.unref?.();
      timers.add(timer);
    }
  }

  /**
   * Classifies a `PreToolUse` / `PostToolUse` payload for `write_file` / `edit_file`.
   * Returns:
   *  - `{ kind: 'not_file' }` for other tools
   *  - `{ kind: 'artifact', absPath }` for internal session brain artifacts
   *  - `{ kind: 'workspace', absPath, relPath, workspaceRoot }` for files inside active workspace
   *  - `{ kind: 'external', absPath }` for paths outside workspace (must ask via ApprovalGate!)
   */
  classifyFileTool(hookPayload = {}, fallbackWorkspace = '') {
    const tc = hookPayload?.toolCall || {};
    const toolName = tc.name || '';
    if (toolName !== 'write_file' && toolName !== 'edit_file') {
      return { kind: 'not_file' };
    }

    const args = cleanArgsObject(tc.args);
    const rawTarget = String(args.Path || args.TargetFile || args.AbsolutePath || '').trim();
    if (!rawTarget) {
      return { kind: 'external', absPath: '' };
    }

    const cwd =
      hookPayload.cwd ||
      (Array.isArray(hookPayload.workspacePaths) && hookPayload.workspacePaths[0]) ||
      fallbackWorkspace ||
      process.cwd();

    const absPath = resolve(cwd, normalize(rawTarget));

    // 1. Check Antigravity brain/artifact directory
    const artifactDir = hookPayload.artifactDirectoryPath || '';
    if (
      (artifactDir && isInsideDir(absPath, artifactDir)) ||
      normalizeSlashes(absPath).includes('/.gemini/antigravity/brain/') ||
      normalizeSlashes(absPath).includes('/.gemini/antigravity-ide/brain/')
    ) {
      return { kind: 'artifact', absPath };
    }

    // 2. Check workspace roots
    const roots = [
      ...(Array.isArray(hookPayload.workspacePaths) ? hookPayload.workspacePaths : []),
      hookPayload.cwd,
      fallbackWorkspace,
    ].filter((r) => typeof r === 'string' && r.trim().length > 0);

    for (const root of roots) {
      const resolvedRoot = resolve(root);
      if (isInsideDir(absPath, resolvedRoot)) {
        const rel = normalizeSlashes(relative(resolvedRoot, absPath)) || normalizeSlashes(absPath);
        return {
          kind: 'workspace',
          absPath,
          relPath: rel,
          workspaceRoot: resolvedRoot,
        };
      }
    }

    return { kind: 'external', absPath };
  }

  /**
   * Captures the untouched pre-edit baseline of a workspace file during `PreToolUse`.
   * If the file is already pending review, preserves its original baseline so multiple
   * sequential edits accumulate into one clean net diff and revert cleanly.
   */
  captureBeforeWrite({ absPath, relPath, workspaceRoot, conversationId = 'global', hookPayload = null }) {
    if (!absPath) return;
    const existing = this.pending.get(absPath);
    if (existing) {
      existing.conversationId = conversationId || existing.conversationId;
      if (hookPayload) {
        this._scheduleAutoFinalize(absPath, hookPayload, workspaceRoot);
      }
      return;
    }

    let existedBefore = false;
    let originalBuffer = null;
    let tooLarge = false;

    if (existsSync(absPath)) {
      try {
        const st = statSync(absPath);
        if (st.isFile()) {
          existedBefore = true;
          if (st.size <= MAX_SNAPSHOT_BYTES) {
            originalBuffer = readFileSync(absPath);
          } else {
            tooLarge = true;
          }
        }
      } catch {}
    }

    this.pending.set(absPath, {
      absPath,
      path: normalizeSlashes(relPath),
      workspace: workspaceRoot,
      existedBefore,
      originalBuffer,
      tooLarge,
      status: existedBefore ? 'MOD' : 'NEW',
      additions: 0,
      deletions: 0,
      conversationId,
      updatedAt: Date.now(),
      staged: false, // becomes true once PostToolUse or disk watcher confirms modification
    });

    if (hookPayload) {
      this._scheduleAutoFinalize(absPath, hookPayload, workspaceRoot);
    }
  }

  /**
   * Finalizes diff stats after `write_file` / `edit_file` completes (`PostToolUse`).
   */
  recordAfterWrite(hookPayload = {}, fallbackWorkspace = '') {
    const check = this.classifyFileTool(hookPayload, fallbackWorkspace);
    if (check.kind !== 'workspace') return null;

    this._clearTimersFor(check.absPath);
    let entry = this.pending.get(check.absPath);
    if (!entry) {
      // Fallback if PostToolUse fired without prior PreToolUse capture
      this.captureBeforeWrite({
        absPath: check.absPath,
        relPath: check.relPath,
        workspaceRoot: check.workspaceRoot,
        conversationId: hookPayload.conversationId || 'global',
      });
      entry = this.pending.get(check.absPath);
    }
    if (!entry) return null;

    return this._syncEntryFromDisk(entry, { dropIfUnchanged: true });
  }

  _syncEntryFromDisk(entry, { dropIfUnchanged = true } = {}) {
    const existsNow = existsSync(entry.absPath);
    let currentBuffer = null;
    if (existsNow) {
      try {
        const st = statSync(entry.absPath);
        if (st.isFile() && st.size <= MAX_SNAPSHOT_BYTES) {
          currentBuffer = readFileSync(entry.absPath);
        }
      } catch {}
    }

    const unchangedNew = !entry.existedBefore && !existsNow;
    const unchangedMod =
      entry.existedBefore &&
      existsNow &&
      entry.originalBuffer &&
      currentBuffer &&
      Buffer.compare(entry.originalBuffer, currentBuffer) === 0;

    if (unchangedNew || unchangedMod) {
      if (dropIfUnchanged) {
        this._clearTimersFor(entry.absPath);
        const wasStaged = entry.staged;
        this.pending.delete(entry.absPath);
        if (wasStaged) this._emitUpdated();
      }
      return null;
    }

    const wasStaged = entry.staged;
    const prevStatus = entry.status;
    const prevAdd = entry.additions;
    const prevDel = entry.deletions;

    entry.status = !entry.existedBefore ? 'NEW' : !existsNow ? 'DEL' : 'MOD';
    entry.updatedAt = Date.now();
    entry.staged = true;

    if (!entry.tooLarge) {
      const beforeText = entry.originalBuffer ? entry.originalBuffer.toString('utf-8') : '';
      const afterText = currentBuffer ? currentBuffer.toString('utf-8') : '';
      const stats = computeUnifiedTextDiff(
        entry.path,
        beforeText,
        afterText,
        entry.existedBefore,
        existsNow,
      );
      entry.additions = stats.additions;
      entry.deletions = stats.deletions;
    }

    if (
      !wasStaged ||
      entry.status !== prevStatus ||
      entry.additions !== prevAdd ||
      entry.deletions !== prevDel
    ) {
      this._emitUpdated();
    }
    return this._toPublicItem(entry);
  }

  listPending() {
    const items = [];
    for (const entry of this.pending.values()) {
      if (!entry.staged) continue;
      items.push(this._toPublicItem(entry));
    }
    return items.sort((a, b) => b.updatedAt - a.updatedAt);
  }

  getPendingDiff(targetPath = '') {
    const entry = this._findEntry(targetPath);
    if (!entry) {
      return { ok: false, path: String(targetPath || ''), diff: '(Файл уже сохранён или не найден)' };
    }
    if (entry.tooLarge) {
      return { ok: true, path: entry.path, diff: '(Файл превышает 2 МБ — бинарный или крупный файл)' };
    }

    const existsNow = existsSync(entry.absPath);
    let afterText = '';
    if (existsNow) {
      try {
        afterText = readFileSync(entry.absPath, 'utf-8');
      } catch {}
    }
    const beforeText = entry.originalBuffer ? entry.originalBuffer.toString('utf-8') : '';
    const { diff } = computeUnifiedTextDiff(
      entry.path,
      beforeText,
      afterText,
      entry.existedBefore,
      existsNow,
    );
    return { ok: true, path: entry.path, status: entry.status, diff };
  }

  /**
   * Accepts ("Сохранить всё" / "Сохранить") pending changes, clearing their review entries
   * while keeping all modified/created files intact on disk.
   * @param {{ paths?: string[] }} [opts]
   */
  saveChanges(opts = {}) {
    const filterPaths = Array.isArray(opts?.paths) && opts.paths.length > 0 ? opts.paths : null;
    let savedCount = 0;

    if (!filterPaths) {
      for (const [key, entry] of this.pending.entries()) {
        if (entry.staged) {
          this._clearTimersFor(key);
          this.pending.delete(key);
          savedCount++;
        }
      }
    } else {
      for (const p of filterPaths) {
        const entry = this._findEntry(p);
        if (entry) {
          this._clearTimersFor(entry.absPath);
          this.pending.delete(entry.absPath);
          savedCount++;
        }
      }
    }

    if (savedCount > 0) {
      this._emitUpdated();
    }
    return { ok: true, savedCount, files: this.listPending() };
  }

  /**
   * Reverts ("Откатить" / "Откатить всё") pending file changes back to their exact
   * pre-agent bytes (or removes newly created files).
   * @param {{ paths?: string[], all?: boolean }} [opts]
   */
  revertChanges(opts = {}) {
    const targets = [];
    if (opts?.all) {
      for (const entry of this.pending.values()) {
        if (entry.staged) targets.push(entry);
      }
    } else if (Array.isArray(opts?.paths)) {
      for (const p of opts.paths) {
        const entry = this._findEntry(p);
        if (entry) targets.push(entry);
      }
    }

    let revertedCount = 0;
    for (const entry of targets) {
      if (entry.tooLarge) continue;
      try {
        if (entry.existedBefore && entry.originalBuffer !== null) {
          mkdirSync(dirname(entry.absPath), { recursive: true });
          writeFileSync(entry.absPath, entry.originalBuffer);
        } else if (!entry.existedBefore && existsSync(entry.absPath)) {
          rmSync(entry.absPath, { force: true });
        }
        this._clearTimersFor(entry.absPath);
        this.pending.delete(entry.absPath);
        revertedCount++;
      } catch {}
    }

    if (revertedCount > 0) {
      this._emitUpdated();
    }
    return { ok: true, revertedCount, files: this.listPending() };
  }

  _findEntry(pathOrRel) {
    const needle = normalizeSlashes(pathOrRel).trim();
    if (!needle) return null;
    if (this.pending.has(pathOrRel)) return this.pending.get(pathOrRel);
    for (const entry of this.pending.values()) {
      if (entry.path === needle || normalizeSlashes(entry.absPath) === needle) {
        return entry;
      }
    }
    return null;
  }

  _toPublicItem(entry) {
    return {
      path: entry.path,
      workspace: entry.workspace,
      status: entry.status,
      additions: entry.additions,
      deletions: entry.deletions,
      conversationId: entry.conversationId,
      updatedAt: entry.updatedAt,
    };
  }

  _emitUpdated() {
    this.emit('changes_updated', this.listPending());
  }
}
