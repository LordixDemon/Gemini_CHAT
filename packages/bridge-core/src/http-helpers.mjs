/**
 * Reusable HTTP utility helpers for `@agy-remote/bridge-core`:
 * CORS headers, JSON body parsing with size limits, Bearer token extraction,
 * and path-traversal-safe static PWA asset serving.
 */
import { existsSync, readFileSync, statSync } from 'node:fs';
import { isAbsolute, relative, resolve } from 'node:path';

export const DEFAULT_MAX_BODY_BYTES = 2 * 1024 * 1024; // 2 MiB

export function applyCorsHeaders(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Bridge-Secret');
}

export function sendJson(res, status, data) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(data));
}

export function extractBearerToken(req, url) {
  const authHeader = req?.headers?.authorization || '';
  if (typeof authHeader === 'string' && authHeader.startsWith('Bearer ')) {
    return authHeader.slice(7).trim();
  }
  return url?.searchParams?.get('token') || '';
}

export function readJsonBody(req, maxBytes = DEFAULT_MAX_BODY_BYTES) {
  return new Promise((resolvePromise, rejectPromise) => {
    let raw = '';
    let settled = false;

    const fail = (err) => {
      if (settled) return;
      settled = true;
      rejectPromise(err);
    };

    req.on('data', (chunk) => {
      if (settled) return;
      raw += chunk.toString('utf-8');
      if (Buffer.byteLength(raw, 'utf-8') > maxBytes) {
        fail(new Error('Payload too large'));
        req.destroy?.();
      }
    });

    req.on('end', () => {
      if (settled) return;
      settled = true;
      if (!raw.trim()) {
        resolvePromise({});
        return;
      }
      try {
        const parsed = JSON.parse(raw);
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
          rejectPromise(new Error('JSON body must be an object'));
          return;
        }
        resolvePromise(parsed);
      } catch {
        rejectPromise(new Error('Invalid JSON body'));
      }
    });

    req.on('error', fail);
  });
}

export function serveStaticAsset(res, rootDir, fileName, contentType) {
  const resolvedRoot = resolve(rootDir);
  const fullTarget = resolve(resolvedRoot, String(fileName || ''));
  const rel = relative(resolvedRoot, fullTarget);

  if (!rel || rel.startsWith('..') || isAbsolute(rel)) {
    return sendJson(res, 403, { ok: false, error: 'Forbidden asset path' });
  }

  if (!existsSync(fullTarget) || !statSync(fullTarget).isFile()) {
    return sendJson(res, 404, { ok: false, error: `Missing asset ${fileName}` });
  }

  const content = readFileSync(fullTarget);
  res.writeHead(200, {
    'Content-Type': contentType,
    'Cache-Control': 'no-cache',
  });
  res.end(content);
}

