import { build } from 'esbuild';
import { cpSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const extDir = join(root, 'apps/vscode-extension');
const distDir = join(extDir, 'dist');

mkdirSync(distDir, { recursive: true });

await build({
  entryPoints: [join(extDir, 'src/extension.ts')],
  outfile: join(distDir, 'extension.js'),
  bundle: true,
  format: 'cjs',
  platform: 'node',
  target: 'node20',
  external: ['vscode'],
  logOverride: { 'empty-import-meta': 'silent' },
});

cpSync(
  join(root, 'packages/bridge-core/src/web-client'),
  join(distDir, 'web-client'),
  { recursive: true, force: true },
);

console.log('[build:vscode] Built apps/vscode-extension/dist/extension.js');
