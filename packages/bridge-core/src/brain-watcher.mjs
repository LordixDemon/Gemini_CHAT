/**
 * Real-time Antigravity Brain & Conversation Transcript Watcher.
 * Discovers sessions across Antigravity 2.0, Antigravity IDE, and Antigravity CLI:
 *   ~/.gemini/<surface>/brain/<conversationId>/.system_generated/logs/transcript.jsonl
 *   ~/.gemini/<surface>/brain/<conversationId>/.system_generated/logs/transcript_full.jsonl
 * Hydrates middle-truncated steps from `transcript_full.jsonl`, parses remote `agentapi`
 * user messages, tracks live Markdown artifacts, and emits step + artifact deltas.
 */
import { EventEmitter } from 'node:events';
import {
  closeSync,
  existsSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  statSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import {
  cleanArgsObject,
  extractRemoteSystemPrompt,
  extractUserPrompt,
  summarizeToolCall,
} from '@agy-remote/protocol';

const CONV_ID_RE = /^[a-z0-9-]{8,64}$/i;
const SUBAGENT_ID_PATTERNS = [
  /"conversationId"\s*:\s*"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"/gi,
  /conversation:\/\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/gi,
];
const ARTIFACT_MAX_BYTES = 8 * 1024 * 1024; // 8 MiB for large plans & architecture docs
const WORKSPACE_ROOT_MARKERS = [
  '.git',
  'package.json',
  'pubspec.yaml',
  'Cargo.toml',
  'pyproject.toml',
  'go.mod',
  'CMakeLists.txt',
];
const ACTIVE_WS_RE = /Active Workspaces:\s*\r?\n-\s*([^\r\n]+)/;

function normalizePromptForDedup(text) {
  return String(text || '').replace(/\r\n/g, '\n').trim();
}

function findPrevVisibleStep(steps) {
  for (let k = steps.length - 1; k >= 0; k--) {
    if (steps[k].role !== 'tool_result') return steps[k];
  }
  return null;
}

function isStepTruncated(obj) {
  if (!obj || typeof obj !== 'object') return false;
  if (Array.isArray(obj.truncated_fields) && obj.truncated_fields.length > 0) {
    return true;
  }
  if (typeof obj.content === 'string' && obj.content.includes('<truncated ')) {
    return true;
  }
  if (typeof obj.thinking === 'string' && obj.thinking.includes('<truncated ')) {
    return true;
  }
  return false;
}

export class BrainWatcher extends EventEmitter {
  /**
   * @param {{ brainRoots?: string[], pollIntervalMs?: number }} [opts]
   */
  constructor(opts = {}) {
    super();
    this.customBrainRoots = opts.brainRoots || null;
    this.pollIntervalMs = opts.pollIntervalMs || 900;
    this._cache = new Map();
    this._wsRootCache = new Map();
    this._subagentIds = new Set();
    this._stoppedSessions = new Map(); // convId -> { stoppedAtMs: number, stepCount: number }
    this._timer = null;
    this._lastScanAt = 0;
  }

  /**
   * Explicitly marks `conversationId` (or `'*'` for all working sessions) as stopped (`idle`)
   * so stale/aborted transcripts never bounce back to `working` until a new user prompt arrives.
   */
  markSessionStopped(conversationId = '') {
    const now = Date.now();
    let changed = false;
    if (!conversationId || conversationId === '*') {
      for (const [id, entry] of this._cache.entries()) {
        this._stoppedSessions.set(id, { stoppedAtMs: now, stepCount: entry.steps.length });
        if (entry.summary.status === 'working') {
          entry.summary = { ...entry.summary, status: 'idle', lastActivity: 'Stopped' };
          changed = true;
        }
      }
      return changed;
    }
    if (!CONV_ID_RE.test(conversationId)) return false;
    const entry = this._cache.get(conversationId);
    this._stoppedSessions.set(conversationId, {
      stoppedAtMs: now,
      stepCount: entry ? entry.steps.length : -1,
    });
    if (entry && entry.summary.status === 'working') {
      entry.summary = { ...entry.summary, status: 'idle', lastActivity: 'Stopped' };
      changed = true;
    }
    return changed;
  }

  clearSessionStopped(conversationId = '') {
    if (!conversationId || conversationId === '*') {
      this._stoppedSessions.clear();
      return;
    }
    this._stoppedSessions.delete(conversationId);
  }

  _inferWorkspaceRoot(rawPath) {
    if (!rawPath || typeof rawPath !== 'string') return '';
    const norm = rawPath.replace(/\\/g, '/').replace(/\/+$/, '');
    const homeNorm = homedir().replace(/\\/g, '/').replace(/\/+$/, '');
    if (
      norm.length < 4 ||
      norm === homeNorm ||
      norm.startsWith(`${homeNorm}/.`) ||
      norm.startsWith(`${homeNorm}/Library/`) ||
      norm.includes('/.gemini/') ||
      norm.startsWith('/tmp/')
    ) {
      return '';
    }
    if (this._wsRootCache.has(norm)) {
      return this._wsRootCache.get(norm);
    }

    let cur = norm;
    try {
      if (existsSync(cur) && statSync(cur).isFile()) {
        cur = dirname(cur).replace(/\\/g, '/');
      }
    } catch {
      cur = dirname(cur).replace(/\\/g, '/');
    }

    let probe = cur;
    for (let depth = 0; depth < 8 && probe && probe !== '/' && probe !== homeNorm && !/^[A-Za-z]:$/.test(probe); depth++) {
      try {
        if (WORKSPACE_ROOT_MARKERS.some((m) => existsSync(join(probe, m)))) {
          this._wsRootCache.set(norm, probe);
          return probe;
        }
      } catch {}
      const parent = dirname(probe).replace(/\\/g, '/');
      if (parent === probe) break;
      probe = parent;
    }

    const parts = cur.split('/');
    const fallback = parts.length >= 4 ? parts.slice(0, Math.min(5, parts.length)).join('/') : cur;
    this._wsRootCache.set(norm, fallback);
    return fallback;
  }

  start() {
    if (this._timer) return;
    this.scanNow(false);
    this._timer = setInterval(() => this.scanNow(true), this.pollIntervalMs);
    this._timer.unref?.();
  }

  stop() {
    if (this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
  }

  discoverBrainRoots() {
    if (this.customBrainRoots) return this.customBrainRoots.filter((p) => existsSync(p));
    const geminiDir = join(homedir(), '.gemini');
    if (!existsSync(geminiDir)) return [];
    const roots = [];
    try {
      for (const entry of readdirSync(geminiDir)) {
        const candidate = join(geminiDir, entry, 'brain');
        if (existsSync(candidate)) roots.push(candidate);
      }
    } catch {}
    return roots;
  }

  /**
   * Scans all brain directories, updates modified transcripts/artifacts, and emits deltas if `emitEvents` is true.
   */
  scanNow(emitEvents = true) {
    const roots = this.discoverBrainRoots();
    let listChanged = false;
    const seenConvIds = new Set();

    for (const brainRoot of roots) {
      let convIds = [];
      try {
        convIds = readdirSync(brainRoot).filter((name) => CONV_ID_RE.test(name));
      } catch {
        continue;
      }

      for (const convId of convIds) {
        const convDir = join(brainRoot, convId);
        const logsDir = join(convDir, '.system_generated', 'logs');
        const transcriptFile = join(logsDir, 'transcript.jsonl');
        if (!existsSync(transcriptFile)) continue;
        seenConvIds.add(convId);

        let st;
        try {
          st = statSync(transcriptFile);
        } catch {
          continue;
        }

        const fullTranscriptFile = join(logsDir, 'transcript_full.jsonl');
        let fullMtimeMs = 0;
        let fullSize = 0;
        if (existsSync(fullTranscriptFile)) {
          try {
            const fst = statSync(fullTranscriptFile);
            fullMtimeMs = fst.mtimeMs;
            fullSize = fst.size;
          } catch {}
        }

        const artifacts = this._listArtifacts(convDir);
        const artifactsKey = artifacts
          .map((a) => `${a.fileName}:${a.sizeBytes}:${Math.trunc(a.updatedAtMs)}`)
          .join('|');

        const prev = this._cache.get(convId);
        if (
          prev &&
          prev.mtimeMs === st.mtimeMs &&
          prev.size === st.size &&
          prev.fullMtimeMs === fullMtimeMs &&
          prev.fullSize === fullSize &&
          prev.artifactsKey === artifactsKey
        ) {
          if (this._subagentIds.has(convId) && !prev.isSubagent) {
            prev.isSubagent = true;
            prev.summary = { ...prev.summary, isSubagent: true };
            listChanged = true;
            continue;
          }
          if (!prev.isSubagent && prev.summary.status === 'working') {
            const latestMtimeMs = Math.max(st.mtimeMs, fullMtimeMs || 0);
            const isStopped = this._stoppedSessions.has(convId);
            const isAgedOut = Date.now() - latestMtimeMs >= 90_000;
            if (isStopped || isAgedOut) {
              prev.summary = {
                ...prev.summary,
                status: 'idle',
                lastActivity: isStopped ? 'Stopped' : prev.summary.lastActivity,
              };
              listChanged = true;
              if (emitEvents) {
                this.emit('steps_delta', {
                  conversationId: convId,
                  summary: prev.summary,
                  artifacts: prev.artifacts,
                  steps: [],
                });
              }
            }
          }
          continue;
        }

        const prevVisibleCount = prev ? prev.visibleSteps.length : 0;
        const parsed = this._parseConversation(
          convId,
          convDir,
          transcriptFile,
          fullTranscriptFile,
          st,
          { fullMtimeMs, fullSize, artifacts, artifactsKey },
          prev,
        );
        if (!parsed) continue;

        this._cache.set(convId, parsed);
        if (!parsed.isSubagent || (prev && !prev.isSubagent)) {
          listChanged = true;
        }

        if (emitEvents && prev && !parsed.isSubagent) {
          const vLen = parsed.visibleSteps.length;
          const startSlice =
            vLen > 0 ? Math.max(0, Math.min(prevVisibleCount - 1, vLen - 1)) : 0;
          const deltaSteps = parsed.visibleSteps.slice(startSlice);
          this.emit('steps_delta', {
            conversationId: convId,
            summary: parsed.summary,
            artifacts: parsed.artifacts,
            steps: deltaSteps,
          });
        }
      }
    }

    // Reconcile any cached parent/child subagent relationships discovered later in the same scan pass
    for (const [cachedId, entry] of this._cache.entries()) {
      if (this._subagentIds.has(cachedId) && !entry.isSubagent && !entry.isUserRoot) {
        entry.isSubagent = true;
        entry.summary = { ...entry.summary, isSubagent: true };
        listChanged = true;
      }
    }

    for (const cachedId of [...this._cache.keys()]) {
      if (!seenConvIds.has(cachedId)) {
        const removed = this._cache.get(cachedId);
        this._cache.delete(cachedId);
        this._stoppedSessions.delete(cachedId);
        if (!removed?.isSubagent) {
          listChanged = true;
        }
      }
    }

    this._lastScanAt = Date.now();
    if (emitEvents && listChanged) {
      this.emit('sessions_updated', this.listSessions());
    }
  }

  listSessions(limit = 50) {
    if (this._cache.size === 0 || !this._timer || Date.now() - this._lastScanAt >= 500) {
      this.scanNow(false);
    }
    return [...this._cache.values()]
      .filter((entry) => !entry.isSubagent)
      .map((entry) => entry.summary)
      .sort((a, b) => b.updatedAtMs - a.updatedAtMs)
      .slice(0, limit);
  }

  getSessionDetail(conversationId, maxSteps = 250) {
    if (!CONV_ID_RE.test(String(conversationId || ''))) return null;
    this.scanNow(false);
    const entry = this._cache.get(conversationId);
    if (!entry) return null;
    const limit = Math.max(20, Math.min(2000, Number(maxSteps) || 250));
    const steps = entry.visibleSteps.slice(-limit);
    return {
      summary: entry.summary,
      artifacts: entry.artifacts,
      totalSteps: entry.steps.length,
      visibleStepCount: entry.visibleSteps.length,
      hasMoreSteps: entry.visibleSteps.length > steps.length,
      steps,
    };
  }

  getSessionWorkspaceHint(conversationId) {
    if (!CONV_ID_RE.test(String(conversationId || ''))) return '';
    const entry = this._cache.get(conversationId);
    return entry?.summary?.workspaceHint || '';
  }

  getArtifactContent(conversationId, fileName) {
    if (!CONV_ID_RE.test(String(conversationId || ''))) return null;
    const safeName = basename(String(fileName || ''));
    if (!safeName || safeName.startsWith('.') || safeName !== fileName) return null;
    this.scanNow(false);
    const entry = this._cache.get(conversationId);
    if (!entry) return null;
    const fullPath = join(entry.convDir, safeName);
    if (!existsSync(fullPath)) return null;
    try {
      const st = statSync(fullPath);
      if (!st.isFile() || st.size > ARTIFACT_MAX_BYTES) return null;
      return {
        fileName: safeName,
        content: readFileSync(fullPath, 'utf-8'),
        updatedAtMs: st.mtimeMs,
      };
    } catch {
      return null;
    }
  }

  /**
   * Hydrates chat-relevant steps (`USER_INPUT`, `PLANNER_RESPONSE`, `SYSTEM_MESSAGE`)
   * whose fields were middle-truncated in `transcript.jsonl` by scanning only the
   * matching JSONL lines in `transcript_full.jsonl` (avoiding parsing non-chat tool outputs).
   */
  _hydrateFromFullTranscript(entries, neededRawIndices, fullTranscriptFile) {
    if (neededRawIndices.size === 0 || !existsSync(fullTranscriptFile)) return;
    let buf;
    try {
      buf = readFileSync(fullTranscriptFile);
    } catch {
      return;
    }

    const byRawIdx = new Map();
    for (const e of entries) {
      if (neededRawIndices.has(e.rawIdx)) {
        byRawIdx.set(e.rawIdx, e);
      }
    }

    const unresolved = new Set(byRawIdx.keys());
    let pos = 0;
    let rawLineIdx = 0;
    const len = buf.length;

    while (pos < len && unresolved.size > 0) {
      let nl = buf.indexOf(10, pos); // '\n'
      if (nl === -1) nl = len;

      if (unresolved.has(rawLineIdx)) {
        const lineStr = buf.toString('utf-8', pos, nl).trim();
        if (lineStr) {
          try {
            const fullObj = JSON.parse(lineStr);
            const target = byRawIdx.get(rawLineIdx);
            if (target && fullObj && fullObj.step_index === target.obj.step_index) {
              this._mergeFullFields(target.obj, fullObj);
              unresolved.delete(rawLineIdx);
            }
          } catch {}
        }
      }

      pos = nl + 1;
      rawLineIdx++;
    }

    // Fallback: if line indices shifted between compact & full transcript, match by step_index + created_at
    if (unresolved.size > 0) {
      const wantedByStep = new Map();
      for (const idx of unresolved) {
        const entry = byRawIdx.get(idx);
        if (entry) {
          const key = `${entry.obj.step_index}|${entry.obj.created_at || ''}`;
          wantedByStep.set(key, entry);
        }
      }

      pos = 0;
      while (pos < len && wantedByStep.size > 0) {
        let nl = buf.indexOf(10, pos);
        if (nl === -1) nl = len;
        const lineStr = buf.toString('utf-8', pos, nl).trim();
        if (lineStr && (lineStr.includes('PLANNER_RESPONSE') || lineStr.includes('USER_INPUT'))) {
          try {
            const fullObj = JSON.parse(lineStr);
            const key = `${fullObj.step_index}|${fullObj.created_at || ''}`;
            const target = wantedByStep.get(key);
            if (target) {
              this._mergeFullFields(target.obj, fullObj);
              wantedByStep.delete(key);
            }
          } catch {}
        }
        pos = nl + 1;
      }
    }
  }

  _mergeFullFields(compactObj, fullObj) {
    if (typeof fullObj.content === 'string') {
      compactObj.content = fullObj.content;
    }
    if (typeof fullObj.thinking === 'string') {
      compactObj.thinking = fullObj.thinking;
    }
    if (Array.isArray(fullObj.tool_calls)) {
      compactObj.tool_calls = fullObj.tool_calls;
    }
  }

  _parseJsonlBuffer(buf, startRawLineIdx = 0) {
    const entries = [];
    const neededRawIndices = new Set();
    let rawIdx = startRawLineIdx;
    let pos = 0;
    let consumedBytes = 0;
    const len = buf.length;

    while (pos < len) {
      const nl = buf.indexOf(10, pos);
      const hasNewline = nl !== -1;
      const lineEnd = hasNewline ? nl : len;
      const lineStr = buf.toString('utf-8', pos, lineEnd).trim();

      if (!hasNewline) {
        if (!lineStr) {
          consumedBytes = len;
          rawIdx++;
          break;
        }
        try {
          const obj = JSON.parse(lineStr);
          entries.push({ rawIdx, obj });
          const t = obj.type || 'GENERIC';
          if (
            (t === 'PLANNER_RESPONSE' || t === 'USER_INPUT' || t === 'SYSTEM_MESSAGE') &&
            isStepTruncated(obj)
          ) {
            neededRawIndices.add(rawIdx);
          }
          consumedBytes = len;
          rawIdx++;
        } catch {
          // Trailing incomplete write without '\n': leave for the next poll tick
        }
        break;
      }

      if (lineStr) {
        try {
          const obj = JSON.parse(lineStr);
          entries.push({ rawIdx, obj });
          const t = obj.type || 'GENERIC';
          if (
            (t === 'PLANNER_RESPONSE' || t === 'USER_INPUT' || t === 'SYSTEM_MESSAGE') &&
            isStepTruncated(obj)
          ) {
            neededRawIndices.add(rawIdx);
          }
        } catch {
          // Skip malformed complete line
        }
      }
      consumedBytes = nl + 1;
      rawIdx++;
      pos = nl + 1;
    }

    return { entries, neededRawIndices, consumedBytes, nextRawLineCount: rawIdx };
  }

  _parseConversation(convId, convDir, transcriptFile, fullTranscriptFile, st, meta, prev = null) {
    const canReuseFullMeta =
      (meta.fullSize || 0) === (prev?.fullSize || 0) &&
      (meta.fullMtimeMs || 0) === (prev?.fullMtimeMs || 0);
    const canReuseParsed =
      Boolean(prev && Number.isFinite(prev.parsedByteOffset) && canReuseFullMeta) &&
      st.size === prev.parsedByteOffset;
    const canAppend =
      Boolean(prev && Number.isFinite(prev.parsedByteOffset) && prev.parsedByteOffset > 0 && canReuseFullMeta) &&
      st.size > prev.parsedByteOffset;

    let entries = [];
    const neededRawIndices = new Set();
    let parsedByteOffset = 0;
    let rawLineCount = 0;

    if (canReuseParsed) {
      parsedByteOffset = prev.parsedByteOffset;
      rawLineCount = prev.rawLineCount;
    } else if (canAppend) {
      const deltaLen = st.size - prev.parsedByteOffset;
      const deltaBuf = Buffer.allocUnsafe(deltaLen);
      let bytesRead = 0;
      let fd;
      try {
        fd = openSync(transcriptFile, 'r');
        while (bytesRead < deltaLen) {
          const n = readSync(fd, deltaBuf, bytesRead, deltaLen - bytesRead, prev.parsedByteOffset + bytesRead);
          if (n <= 0) break;
          bytesRead += n;
        }
      } catch {
        return null;
      } finally {
        if (fd !== undefined) {
          try {
            closeSync(fd);
          } catch {}
        }
      }
      const parsedDelta = this._parseJsonlBuffer(deltaBuf.subarray(0, bytesRead), prev.rawLineCount || 0);
      entries = parsedDelta.entries;
      for (const idx of parsedDelta.neededRawIndices) neededRawIndices.add(idx);
      parsedByteOffset = prev.parsedByteOffset + parsedDelta.consumedBytes;
      rawLineCount = parsedDelta.nextRawLineCount;
    } else {
      let fullBuf;
      try {
        fullBuf = readFileSync(transcriptFile);
      } catch {
        return null;
      }
      const parsedFull = this._parseJsonlBuffer(fullBuf, 0);
      entries = parsedFull.entries;
      for (const idx of parsedFull.neededRawIndices) neededRawIndices.add(idx);
      parsedByteOffset = parsedFull.consumedBytes;
      rawLineCount = parsedFull.nextRawLineCount;
    }

    if (neededRawIndices.size > 0) {
      this._hydrateFromFullTranscript(entries, neededRawIndices, fullTranscriptFile);
    }

    const convDirNorm = convDir.replace(/\\/g, '/').replace(/\/+$/, '');
    const continuing = canReuseParsed || canAppend;
    const steps = continuing ? [...prev.steps] : [];
    const visibleSteps = continuing ? [...prev.visibleSteps] : [];
    let title = continuing ? prev.title : '';
    let workspaceHint = continuing ? prev.workspaceHint : '';
    let lastActivity = continuing ? prev.lastActivity : '';
    let pendingSubagentOutputScan = continuing ? prev.pendingSubagentOutputScan : false;

    const firstObj = entries[0]?.obj;
    const isUserRoot = continuing
      ? prev.isUserRoot
      : Boolean(
          firstObj &&
            ((firstObj.type === 'USER_INPUT' &&
              !String(firstObj.content || '').includes('[Message] timestamp=')) ||
              Boolean(extractRemoteSystemPrompt(firstObj.content || ''))),
        );
    const isSubagentStart = continuing
      ? prev.isSubagentStart
      : Boolean(
          firstObj &&
            !isUserRoot &&
            ((firstObj.type === 'SYSTEM_MESSAGE' || firstObj.source === 'SYSTEM') ||
              Number(firstObj.step_index) > 0 ||
              (firstObj.type === 'USER_INPUT' &&
                String(firstObj.content || '').includes('[Message] timestamp='))),
        );
    if (isSubagentStart) {
      this._subagentIds.add(convId);
    }

    const pushStep = (stepObj) => {
      steps.push(stepObj);
      if (stepObj.role !== 'tool_result') {
        visibleSteps.push(stepObj);
      }
    };

    for (const { obj } of entries) {
      const type = obj.type || 'GENERIC';
      const seq = steps.length;
      const stepIndex = Number.isFinite(obj.step_index) ? obj.step_index : seq;
      const createdAt = obj.created_at || new Date(st.mtimeMs).toISOString();

      if (type === 'USER_INPUT' && !String(obj.content || '').includes('[Message] timestamp=')) {
        if (!workspaceHint && typeof obj.content === 'string') {
          const wsMatch = ACTIVE_WS_RE.exec(obj.content);
          if (wsMatch?.[1]) {
            workspaceHint = wsMatch[1].trim().replace(/\\/g, '/').replace(/\/+$/, '');
          }
        }
        const cleanPrompt = extractUserPrompt(obj.content || '');
        if (!title && cleanPrompt) {
          title = cleanPrompt.split('\n')[0].slice(0, 90);
        }
        const prevVisible = findPrevVisibleStep(steps);
        const curTs = Date.parse(createdAt) || 0;
        const prevTs = prevVisible ? Date.parse(prevVisible.createdAt || '') || 0 : 0;
        const isMirroredMobilePrompt = Boolean(
          prevVisible &&
            prevVisible.role === 'user' &&
            (prevVisible.source === 'mobile' || obj.source === 'SYSTEM_SDK') &&
            normalizePromptForDedup(prevVisible.content) === normalizePromptForDedup(cleanPrompt) &&
            Math.abs(curTs - prevTs) <= 120_000,
        );
        if (isMirroredMobilePrompt) {
          pushStep({
            seq,
            stepIndex,
            role: 'tool_result',
            type,
            status: obj.status || 'DONE',
            createdAt,
            content: cleanPrompt,
          });
        } else {
          const userStep = {
            seq,
            stepIndex,
            role: 'user',
            type,
            status: obj.status || 'DONE',
            createdAt,
            content: cleanPrompt,
          };
          if (obj.source === 'SYSTEM_SDK') {
            userStep.source = 'mobile';
          }
          pushStep(userStep);
          lastActivity = 'User prompt received';
        }
      } else if (type === 'SYSTEM_MESSAGE' || type === 'USER_INPUT') {
        const remotePrompt = extractRemoteSystemPrompt(obj.content || '');
        if (remotePrompt) {
          if (!title) {
            title = remotePrompt.split('\n')[0].slice(0, 90);
          }
          const prevVisible = findPrevVisibleStep(steps);
          const curTs = Date.parse(createdAt) || 0;
          const prevTs = prevVisible ? Date.parse(prevVisible.createdAt || '') || 0 : 0;
          const isDuplicateOfPrevUser = Boolean(
            prevVisible &&
              prevVisible.role === 'user' &&
              normalizePromptForDedup(prevVisible.content) === normalizePromptForDedup(remotePrompt) &&
              Math.abs(curTs - prevTs) <= 120_000,
          );
          if (isDuplicateOfPrevUser) {
            pushStep({
              seq,
              stepIndex,
              role: 'tool_result',
              type,
              status: obj.status || 'DONE',
              createdAt,
              content: remotePrompt,
            });
          } else {
            pushStep({
              seq,
              stepIndex,
              role: 'user',
              type: 'USER_INPUT',
              source: 'mobile',
              status: obj.status || 'DONE',
              createdAt,
              content: remotePrompt,
            });
            lastActivity = 'Mobile prompt received';
          }
        } else {
          const snippet = typeof obj.content === 'string' ? obj.content.slice(0, 1200) : '';
          pushStep({
            seq,
            stepIndex,
            role: 'tool_result',
            type,
            status: obj.status || 'DONE',
            createdAt,
            content: snippet,
          });
        }
      } else if (type === 'PLANNER_RESPONSE') {
        const rawTools = Array.isArray(obj.tool_calls) ? obj.tool_calls : [];
        pendingSubagentOutputScan = false;
        const toolCalls = rawTools.map((tc) => {
          const cleanArgs = cleanArgsObject(tc.args);
          if (tc.name === 'invoke_subagent') {
            pendingSubagentOutputScan = true;
          }
          const p =
            cleanArgs.Path ||
            cleanArgs.TargetFile ||
            cleanArgs.DirectoryPath ||
            cleanArgs.SearchPath ||
            '';
          const normPath = typeof p === 'string' ? p.replace(/\\/g, '/') : '';
          if (!workspaceHint && normPath.length > 3) {
            const inferred = this._inferWorkspaceRoot(normPath);
            if (inferred) workspaceHint = inferred;
          }

          let artifactFileName;
          let artifactSummary;
          if (
            (tc.name === 'write_file' || tc.name === 'edit_file') &&
            normPath.toLowerCase().endsWith('.md') &&
            (normPath.startsWith(`${convDirNorm}/`) || Boolean(cleanArgs.ArtifactMetadata))
          ) {
            const base = basename(normPath);
            if (base && !base.startsWith('.')) {
              artifactFileName = base;
              const rawMeta = cleanArgs.ArtifactMetadata;
              if (rawMeta && typeof rawMeta === 'object' && typeof rawMeta.Summary === 'string') {
                artifactSummary = rawMeta.Summary;
              } else if (typeof rawMeta === 'string') {
                try {
                  const parsedMeta = JSON.parse(rawMeta);
                  if (typeof parsedMeta?.Summary === 'string') {
                    artifactSummary = parsedMeta.Summary;
                  }
                } catch {}
              }
            }
          }

          const outTc = {
            name: tc.name || 'tool',
            summary: summarizeToolCall(tc),
            args: cleanArgs,
          };
          if (artifactFileName) outTc.artifactFileName = artifactFileName;
          if (artifactSummary) outTc.artifactSummary = artifactSummary;
          return outTc;
        });

        if (toolCalls.length > 0) {
          lastActivity = toolCalls[toolCalls.length - 1].summary;
        } else if (obj.content) {
          lastActivity = 'Replied';
        }

        pushStep({
          seq,
          stepIndex,
          role: 'assistant',
          type,
          status: obj.status || 'DONE',
          createdAt,
          thinking: typeof obj.thinking === 'string' ? obj.thinking.trim() : '',
          content: typeof obj.content === 'string' ? obj.content.trim() : '',
          toolCalls,
          tokens: {
            input: obj.input_tokens || 0,
            output: obj.output_tokens || 0,
          },
        });
      } else {
        // Tool execution output / system event
        if (pendingSubagentOutputScan && typeof obj.content === 'string') {
          for (const re of SUBAGENT_ID_PATTERNS) {
            re.lastIndex = 0;
            let match;
            while ((match = re.exec(obj.content)) !== null) {
              if (match[1] && match[1] !== convId) {
                this._subagentIds.add(match[1]);
              }
            }
          }
        }
        const snippet = typeof obj.content === 'string' ? obj.content.slice(0, 1200) : '';
        pushStep({
          seq,
          stepIndex,
          role: 'tool_result',
          type,
          status: obj.status || 'DONE',
          createdAt,
          content: snippet,
        });
      }
    }

    // Determine live conversation run status from newest steps & mtime recency
    const latestMtimeMs = Math.max(st.mtimeMs, meta.fullMtimeMs || 0);
    const lastStep = steps[steps.length - 1];
    const stoppedInfo = this._stoppedSessions.get(convId);
    if (stoppedInfo !== undefined && lastStep?.role === 'user') {
      const stepTs = Date.parse(lastStep.createdAt || '') || latestMtimeMs;
      const isNewerUserStep =
        stoppedInfo.stepCount >= 0
          ? steps.length > stoppedInfo.stepCount
          : stepTs > stoppedInfo.stoppedAtMs;
      if (isNewerUserStep) {
        this._stoppedSessions.delete(convId);
      }
    }

    let status = 'idle';
    if (lastStep) {
      if (lastStep.status === 'ERROR') {
        status = 'error';
      } else if (!this._stoppedSessions.has(convId)) {
        const ageMs = Date.now() - latestMtimeMs;
        const endedWithFinalReply =
          lastStep.role === 'assistant' && (!lastStep.toolCalls || lastStep.toolCalls.length === 0);
        const isOrphanBgTaskNotice =
          lastStep.role === 'tool_result' &&
          lastStep.type === 'SYSTEM_MESSAGE' &&
          typeof lastStep.content === 'string' &&
          lastStep.content.includes('finished with result:');
        if (!endedWithFinalReply && !isOrphanBgTaskNotice && ageMs < 90_000) {
          status = 'working';
        }
      }
    }

    const artifacts = meta.artifacts || this._listArtifacts(convDir);
    const surface = basename(join(convDir, '..', '..')); // e.g. antigravity, antigravity-ide

    const isSubagent = !isUserRoot && (isSubagentStart || this._subagentIds.has(convId));

    const summary = {
      id: convId,
      title: title || `Session ${convId.slice(0, 8)}`,
      surface,
      status,
      stepCount: steps.length,
      lastActivity: lastActivity || 'Idle',
      workspaceHint,
      workspaceName: workspaceHint ? basename(workspaceHint) : '',
      artifactCount: artifacts.length,
      updatedAtMs: latestMtimeMs,
      updatedAt: new Date(latestMtimeMs).toISOString(),
      isSubagent,
    };

    return {
      convDir,
      isUserRoot,
      isSubagent,
      isSubagentStart,
      mtimeMs: st.mtimeMs,
      size: st.size,
      parsedByteOffset,
      rawLineCount,
      title,
      workspaceHint,
      lastActivity,
      pendingSubagentOutputScan,
      fullMtimeMs: meta.fullMtimeMs || 0,
      fullSize: meta.fullSize || 0,
      artifactsKey: meta.artifactsKey || '',
      steps,
      visibleSteps,
      artifacts,
      summary,
    };
  }

  _listArtifacts(convDir) {
    const out = [];
    try {
      for (const name of readdirSync(convDir)) {
        if (name.startsWith('.') || !name.endsWith('.md')) continue;
        const full = join(convDir, name);
        const st = statSync(full);
        if (st.isFile()) {
          out.push({
            fileName: name,
            sizeBytes: st.size,
            updatedAtMs: st.mtimeMs,
          });
        }
      }
    } catch {}
    return out.sort((a, b) => b.updatedAtMs - a.updatedAtMs);
  }
}
