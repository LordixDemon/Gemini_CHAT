/**
 * Antigravity Remote Control — Sidecar Backend (`control-pane`).
 * Uses `sidecar_sdk` (`SidecarApp`) when launched by Antigravity 2.0 / IDE,
 * with a clean standalone HTTP fallback for local testing.
 */
import { existsSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load bundled zero-dep BridgeCore when installed in ~/.gemini/config/plugins,
// or workspace source during monorepo development.
const bridgeModulePath = existsSync(join(__dirname, 'bridge-bundle.mjs'))
  ? './bridge-bundle.mjs'
  : '../../../../packages/bridge-core/src/index.mjs';

const { startOrAttachBridge } = await import(bridgeModulePath);

const bridgeOpts = {
  webClientDir: existsSync(join(__dirname, 'web-client')) ? join(__dirname, 'web-client') : undefined,
};

let bridgeHandle = await startOrAttachBridge(bridgeOpts);

// Keep this Antigravity window's LS registered across Bridge restarts and auto-revive if Bridge exited
let heartbeatBusy = false;
const heartbeatTimer = setInterval(async () => {
  if (heartbeatBusy) return;
  heartbeatBusy = true;
  try {
    await bridgeHandle.client.registerSelfHost();
  } catch {
    try {
      bridgeHandle = await startOrAttachBridge(bridgeOpts);
    } catch {}
  } finally {
    heartbeatBusy = false;
  }
}, 4000);
heartbeatTimer.unref?.();

async function dispatchAction(body = {}) {
  const client = bridgeHandle.client;
  switch (body.action) {
    case 'rotatePin':
      return client.rotatePin();
    case 'revokeDevice':
      return client.revokeDevice(body.deviceId);
    case 'updateSettings':
      return client.updateSettings(body.settings || {});
    case 'decideApproval':
      return client.decideApproval(body);
    case 'saveChanges':
      return client.saveChanges(body.paths);
    case 'revertChanges':
      return client.revertChanges({ paths: body.paths, all: Boolean(body.all) });
    default:
      return client.getControlStatus();
  }
}

let sidecarSdk = null;
try {
  sidecarSdk = await import('sidecar_sdk');
} catch {
  sidecarSdk = null;
}

if (sidecarSdk?.SidecarApp) {
  const { SidecarApp, Response } = sidecarSdk;
  const app = new SidecarApp();

  app.page('/', () => readFileSync(join(__dirname, 'index.html'), 'utf-8'));
  app.api(
    '/styles.css',
    () => new Response(readFileSync(join(__dirname, 'styles.css'), 'utf-8'), { contentType: 'text/css' }),
    'GET',
  );
  app.api(
    '/pane.js',
    () => new Response(readFileSync(join(__dirname, 'pane.js'), 'utf-8'), { contentType: 'application/javascript' }),
    'GET',
  );
  app.api('/api/status', async () => bridgeHandle.client.getControlStatus(), 'GET');
  app.api('/api/action', async (data) => dispatchAction(data), 'POST');

  app.run();
} else {
  // Standalone fallback if run outside Antigravity LS
  const uiPort = Number(process.env.ANTIGRAVITY_SIDECAR_WEB_PORT || 7444);
  const srv = createServer(async (req, res) => {
    const u = new URL(req.url || '/', 'http://127.0.0.1');
    if (req.method === 'GET' && u.pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(readFileSync(join(__dirname, 'index.html'), 'utf-8'));
      return;
    }
    if (req.method === 'GET' && u.pathname === '/preload.js') {
      res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8' });
      res.end('/* standalone fallback */');
      return;
    }
    if (req.method === 'GET' && u.pathname === '/styles.css') {
      res.writeHead(200, { 'Content-Type': 'text/css; charset=utf-8' });
      res.end(readFileSync(join(__dirname, 'styles.css'), 'utf-8'));
      return;
    }
    if (req.method === 'GET' && u.pathname === '/pane.js') {
      res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8' });
      res.end(readFileSync(join(__dirname, 'pane.js'), 'utf-8'));
      return;
    }
    if (req.method === 'GET' && u.pathname === '/api/status') {
      const st = await bridgeHandle.client.getControlStatus();
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(st));
      return;
    }
    if (req.method === 'POST' && u.pathname === '/api/action') {
      let raw = '';
      req.on('data', (c) => (raw += c));
      req.on('end', async () => {
        const out = await dispatchAction(raw ? JSON.parse(raw) : {});
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(out));
      });
      return;
    }
    res.writeHead(404).end('Not found');
  });
  srv.listen(uiPort, '127.0.0.1', () => {
    console.log(`[control-pane] Standalone UI listening on http://127.0.0.1:${uiPort}`);
  });
}

