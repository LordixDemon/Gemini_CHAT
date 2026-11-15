/**
 * Bundles `@agy-remote/bridge-core` + `@agy-remote/protocol` into a single
 * zero-dependency ESM file for `apps/agy-plugin/sidecars/control-pane/bridge-bundle.mjs`
 * and optionally installs the complete plugin into `~/.gemini/config/plugins/antigravity-remote`.
 */
import { build } from 'esbuild';
import { cpSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pluginSrc = join(root, 'apps/agy-plugin');
const sidecarDir = join(pluginSrc, 'sidecars/control-pane');
const webClientSrc = join(root, 'packages/bridge-core/src/web-client');

await build({
  entryPoints: [join(root, 'packages/bridge-core/src/index.mjs')],
  outfile: join(sidecarDir, 'bridge-bundle.mjs'),
  bundle: true,
  format: 'esm',
  platform: 'node',
  target: 'node20',
});

cpSync(webClientSrc, join(sidecarDir, 'web-client'), { recursive: true, force: true });
console.log('[plugin] Bundled bridge-bundle.mjs + web-client into apps/agy-plugin');

if (!process.argv.includes('--local-only')) {
  const targetDir = join(homedir(), '.gemini', 'config', 'plugins', 'antigravity-remote');
  mkdirSync(targetDir, { recursive: true });
  cpSync(pluginSrc, targetDir, { recursive: true, force: true });
  console.log(`[plugin] Installed Antigravity plugin -> ${targetDir}`);
}

