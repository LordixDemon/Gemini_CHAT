/**
 * Workspace Git Status, Unified Diff, Mobile File Uploads, and Bounded Shell Runner.
 *
 * Extracted from `AgentDriver` to keep workspace file/process operations isolated
 * from Language Server / ACP routing.
 */
import { execFile, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { basename, extname, isAbsolute, join, normalize, relative, resolve } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export const MAX_DIFF_BYTES = 96 * 1024;
export const MAX_CMD_OUTPUT = 64 * 1024;
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024; // 20 MiB max mobile upload
const IMAGE_EXT_RE = /^\.(png|jpe?g|webp|gif|heic|heif|bmp|svg)$/i;

export class WorkspaceOps {
  #activeCommandProcs = new Set();

  /**
   * @param {{ getDefaultWorkspace: () => string }} opts
   */
  constructor(opts) {
    this.getDefaultWorkspace = opts.getDefaultWorkspace;
  }

  resolveWorkspace(wsPath) {
    const fallback = this.getDefaultWorkspace();
    const target = normalize(wsPath || fallback);
    return existsSync(target) ? resolve(target) : fallback;
  }

  _terminateProc(proc) {
    if (!proc) return;
    const isPosix = process.platform !== 'win32';
    const sendSignal = (sig) => {
      if (isPosix && Number.isInteger(proc.pid) && proc.pid > 0) {
        try {
          process.kill(-proc.pid, sig);
          return true;
        } catch {}
      }
      try {
        proc.kill(sig);
        return true;
      } catch {
        return false;
      }
    };
    sendSignal('SIGTERM');
    const forceTimer = setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        sendSignal('SIGKILL');
      }
    }, 2000);
    forceTimer.unref?.();
  }

  killActiveCommands() {
    let killed = 0;
    for (const proc of [...this.#activeCommandProcs]) {
      this._terminateProc(proc);
      killed += 1;
    }
    return killed;
  }

  clearActiveCommands() {
    this.killActiveCommands();
    this.#activeCommandProcs.clear();
  }

  /**
   * Saves a mobile photo or file upload into `<workspace>/.antigravity-uploads/`.
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

    const cwd = this.resolveWorkspace(workspacePath);
    const uploadsDir = join(cwd, '.antigravity-uploads');
    mkdirSync(uploadsDir, { recursive: true });

    const rawBase = basename(String(fileName || 'attachment.bin').replace(/\\/g, '/'));
    const safeName =
      rawBase
        .replace(/[^a-zA-Z0-9._-]+/g, '_')
        .replace(/^_+/, '')
        .slice(0, 120) || 'attachment.bin';
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
   * Inspects workspace Git branch & modified/untracked files for mobile code review.
   */
  async getWorkspaceStatus(workspacePath) {
    const cwd = this.resolveWorkspace(workspacePath);
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
  async getFileDiff(filePath, workspacePath) {
    const cwd = this.resolveWorkspace(workspacePath);
    const fullTarget = resolve(cwd, String(filePath || ''));
    const rel = relative(cwd, fullTarget);
    if (!rel || rel.startsWith('..') || isAbsolute(rel)) {
      throw new Error('File path outside workspace is not allowed');
    }
    if (existsSync(fullTarget)) {
      const realCwd = realpathSync(cwd);
      const realTarget = realpathSync(fullTarget);
      const realRel = relative(realCwd, realTarget);
      if (!realRel || realRel.startsWith('..') || isAbsolute(realRel)) {
        throw new Error('File path outside workspace is not allowed');
      }
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
  runQuickCommand(command, workspacePath, timeoutMs = 25000) {
    const cwd = this.resolveWorkspace(workspacePath);
    const cmdStr = String(command || '').trim();
    if (!cmdStr) return Promise.reject(new Error('Empty command'));

    const isWin = process.platform === 'win32';
    const shell = isWin ? 'powershell.exe' : '/bin/sh';
    const args = isWin ? ['-NoProfile', '-Command', cmdStr] : ['-c', cmdStr];

    return new Promise((resolvePromise) => {
      const startedAt = Date.now();
      const proc = spawn(shell, args, {
        cwd,
        detached: process.platform !== 'win32',
        windowsHide: true,
      });
      this.#activeCommandProcs.add(proc);
      let output = '';
      let truncated = false;
      let killedByTimeout = false;

      const timer = setTimeout(() => {
        killedByTimeout = true;
        this._terminateProc(proc);
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
}
