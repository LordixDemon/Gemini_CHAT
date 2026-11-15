import { build } from 'esbuild';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

await build({
  entryPoints: [join(root, 'packages/protocol/src/qr-source.mjs')],
  outfile: join(root, 'packages/protocol/src/qr-svg.mjs'),
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: 'es2022',
  banner: {
    js: '// AUTO-GENERATED self-contained ISO/IEC 18004 QR encoder (zero external dependencies)\n',
  },
});

console.log('[build:qr] Built packages/protocol/src/qr-svg.mjs');
