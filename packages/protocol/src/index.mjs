/**
 * Antigravity Remote Protocol (ARP v1)
 * Shared constants, message envelope builders, pairing payload codecs,
 * and transcript/tool-call normalizers used across Desktop Bridge,
 * Antigravity Sidecar, VS Code Extension, and Cloudflare Edge Relay.
 */

export const PROTOCOL_VERSION = 'arp.v1';
export const DEFAULT_BRIDGE_PORT = 7443;

/**
 * Approval policy modes for `PreToolUse` hook interception:
 * - `observe`: Never block tools; stream activity to mobile only.
 * - `ask-mobile`: Forward sensitive tools (`run_command`, `write_file`, `edit_file`) to connected mobile devices for Approve/Deny. Falls back to `"ask"` if no mobile device is online or on timeout.
 * - `auto-safe`: Auto-approve read-only / safe commands (`git status`, `git diff`, `npm test`, `flutter analyze`), ask mobile for mutating commands.
 */
export const APPROVAL_MODES = ['observe', 'ask-mobile', 'auto-safe'];

export const SAFE_COMMAND_PATTERNS = [
  /^\s*git\s+(status|diff|log|branch|show)\b/i,
  /^\s*(npm|pnpm|yarn)\s+(test|run\s+lint|run\s+typecheck)\b/i,
  /^\s*flutter\s+(analyze|test|--version|doctor)\b/i,
  /^\s*node\s+--test\b/i,
];

const SHELL_CHAIN_OR_SUBSHELL_RE = /[\r\n;&|`$<>()]/;

export function isSafeCommand(cmd = '') {
  const raw = String(cmd ?? '');
  if (SHELL_CHAIN_OR_SUBSHELL_RE.test(raw)) return false;
  const trimmed = raw.trim();
  if (!trimmed) return false;
  return SAFE_COMMAND_PATTERNS.some((re) => re.test(trimmed));
}

/**
 * Creates a standardized ARP v1 WebSocket envelope.
 * @param {string} type
 * @param {Record<string, any>} payload
 * @param {string} [reqId]
 */
export function createEnvelope(type, payload = {}, reqId = undefined) {
  const msg = {
    v: PROTOCOL_VERSION,
    type,
    ts: Date.now(),
    payload: payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {},
  };
  if (reqId) msg.reqId = reqId;
  return msg;
}

export function parseEnvelope(raw) {
  if (raw === null || raw === undefined) return null;
  try {
    const text = typeof raw === 'string' ? raw : Buffer.from(raw).toString('utf-8');
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    if (typeof parsed.type !== 'string' || !parsed.type.trim()) return null;
    const payload =
      parsed.payload && typeof parsed.payload === 'object' && !Array.isArray(parsed.payload)
        ? parsed.payload
        : {};
    return {
      v: typeof parsed.v === 'string' && parsed.v ? parsed.v : PROTOCOL_VERSION,
      type: parsed.type,
      ts: Number(parsed.ts) || Date.now(),
      reqId: typeof parsed.reqId === 'string' && parsed.reqId ? parsed.reqId : undefined,
      payload,
    };
  } catch {
    return null;
  }
}

/**
 * Builds the universal Pairing URL encoded into the QR code.
 * Scanning with the native iOS/Android camera opens the built-in PWA immediately;
 * scanning with the Flutter app extracts host, port, token, and optional Cloudflare Edge info.
 *
 * @param {{
 *   baseUrl: string,
 *   token: string,
 *   pin?: string,
 *   machineId: string,
 *   machineName: string,
 *   cloudflareUrl?: string,
 *   sessionId?: string
 * }} opts
 */
export function buildPairingUrl(opts) {
  const base = String(opts?.baseUrl || '').replace(/\/+$/, '');
  const url = new URL(`${base}/pair`);
  url.searchParams.set('t', String(opts?.token || ''));
  url.searchParams.set('m', String(opts?.machineId || ''));
  url.searchParams.set('n', String(opts?.machineName || ''));
  if (opts?.cloudflareUrl) {
    url.searchParams.set('cf', String(opts.cloudflareUrl).replace(/\/+$/, ''));
  }
  if (opts?.sessionId) {
    url.searchParams.set('s', String(opts.sessionId));
  }
  return url.toString();
}

/**
 * Parses a scanned QR Pairing URL or raw JSON payload.
 * Rejects non-HTTP(S) schemes.
 * @param {string} input
 */
export function parsePairingInput(input) {
  const raw = String(input || '').trim();
  if (!raw) return null;

  if (raw.startsWith('{')) {
    try {
      const obj = JSON.parse(raw);
      if (!obj || typeof obj !== 'object' || typeof obj.baseUrl !== 'string') return null;
      const base = new URL(obj.baseUrl);
      if (base.protocol !== 'http:' && base.protocol !== 'https:') return null;
      return {
        baseUrl: `${base.protocol}//${base.host}`,
        token: String(obj.token || ''),
        machineId: String(obj.machineId || ''),
        machineName: String(obj.machineName || base.hostname),
        cloudflareUrl: String(obj.cloudflareUrl || '').replace(/\/+$/, ''),
        sessionId: String(obj.sessionId || obj.machineId || ''),
      };
    } catch {
      return null;
    }
  }

  try {
    const u = new URL(raw);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    const origin = `${u.protocol}//${u.host}`;
    return {
      baseUrl: origin,
      token: u.searchParams.get('t') || '',
      machineId: u.searchParams.get('m') || '',
      machineName: u.searchParams.get('n') || u.hostname,
      cloudflareUrl: (u.searchParams.get('cf') || '').replace(/\/+$/, ''),
      sessionId: u.searchParams.get('s') || '',
    };
  } catch {
    return null;
  }
}

/**
 * Unquotes string values in Antigravity `transcript.jsonl` tool_calls args
 * (where string args are serialized as JSON-quoted strings like `"\"path\""`).
 */
export function unquoteArg(val) {
  if (typeof val !== 'string') return val;
  const s = val.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    try {
      return JSON.parse(s);
    } catch {
      return s.slice(1, -1);
    }
  }
  return val;
}

export function cleanArgsObject(args) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) return {};
  const out = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = unquoteArg(v);
  }
  return out;
}

/**
 * Extracts clean user message text from Antigravity `<USER_REQUEST>...</USER_REQUEST>` blocks.
 */
export function extractUserPrompt(rawContent = '') {
  const text = String(rawContent || '');
  const match = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i.exec(text);
  if (match) return match[1].trim();
  return text
    .replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/gi, '')
    .replace(/<USER_SETTINGS_CHANGE>[\s\S]*?<\/USER_SETTINGS_CHANGE>/gi, '')
    .replace(/<SYSTEM_MESSAGE>[\s\S]*?<\/SYSTEM_MESSAGE>/gi, '')
    .trim();
}

const UUID_PREFIX_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-/i;

/**
 * Extracts user prompts injected via `agentapi send-message` into Antigravity conversations,
 * which Antigravity records as `SYSTEM_MESSAGE` steps (`[Message] timestamp=... sender=system ... content=...`),
 * while ignoring internal background task / subagent notifications (`sender=<uuid>/task-N` or `Task id "..."`).
 * @param {string} [rawContent]
 * @returns {string | null}
 */
export function extractRemoteSystemPrompt(rawContent = '') {
  const text = String(rawContent || '');
  const msgMatch =
    /(?:^|\n)\s*\[Message\]\s+timestamp=\S+\s+sender=(\S+)(?:\s+(?!content=)\w+=\S+)*\s+content=([\s\S]*?)(?:<\/SYSTEM_MESSAGE>|$)/i.exec(
      text,
    );
  if (!msgMatch) return null;

  const sender = msgMatch[1].trim();
  const body = msgMatch[2].trim();
  if (!body) return null;

  // Ignore background task completions & subagent messages
  if (
    sender.includes('/task-') ||
    UUID_PREFIX_RE.test(sender) ||
    /^Task id\s+"[^"]+"/i.test(body)
  ) {
    return null;
  }

  return body;
}

/**
 * Produces a concise human-readable summary of a tool call for mobile step cards.
 */
export function summarizeToolCall(tc) {
  if (!tc || typeof tc.name !== 'string' || !tc.name.trim()) return 'Tool call';
  const args = cleanArgsObject(tc.args);
  if (args.toolSummary) return String(args.toolSummary);
  const file = args.Path || args.TargetFile || args.AbsolutePath || '';
  const shortFile = file ? String(file).split(/[\\/]/).pop() : '';
  switch (tc.name) {
    case 'run_command':
      return args.CommandLine ? `$ ${String(args.CommandLine).slice(0, 72)}` : 'Run command';
    case 'read_file':
      return shortFile ? `Read ${shortFile}` : 'Read file';
    case 'write_file':
      return shortFile ? `Create ${shortFile}` : 'Write file';
    case 'edit_file':
      return shortFile ? `Edit ${shortFile}` : 'Edit file';
    case 'search_web':
      return args.query ? `Web: ${String(args.query).slice(0, 60)}` : 'Search web';
    case 'ask_question':
      return 'Ask user question';
    default:
      return shortFile ? `${tc.name} (${shortFile})` : tc.name;
  }
}
