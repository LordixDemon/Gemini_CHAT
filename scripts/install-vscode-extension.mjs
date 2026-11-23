/**
 * Packages `apps/vscode-extension` into a standard VSIX 2.0 archive (`.vsix`)
 * with zero external dependencies and installs it via `--install-extension`
 * into all detected VS Code / Antigravity IDE installations so it is registered
 * in `extensions.json` and persists across restarts.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, extname, join, posix, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c >>> 0;
  }
  return table;
})();

export function crc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    crc = CRC_TABLE[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * Builds a deterministic PKZIP 2.0 archive buffer from `Array<{ path: string, data: Buffer }>`.
 */
export function buildZipBuffer(entries) {
  const localChunks = [];
  const centralChunks = [];
  let offset = 0;

  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.path.replace(/\\/g, '/'), 'utf-8');
    const raw = Buffer.isBuffer(entry.data) ? entry.data : Buffer.from(entry.data, 'utf-8');
    const compressed = deflateRawSync(raw, { level: 9 });
    const useDeflate = compressed.length < raw.length;
    const payload = useDeflate ? compressed : raw;
    const method = useDeflate ? 8 : 0;
    const checksum = crc32(raw);

    // Local File Header (30 bytes + filename)
    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0); // signature
    localHeader.writeUInt16LE(20, 4); // version needed (2.0)
    localHeader.writeUInt16LE(0x0800, 6); // UTF-8 filename flag
    localHeader.writeUInt16LE(method, 8);
    localHeader.writeUInt16LE(0, 10); // mod time
    localHeader.writeUInt16LE(0x5821, 12); // mod date (2024-01-01)
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(payload.length, 18);
    localHeader.writeUInt32LE(raw.length, 22);
    localHeader.writeUInt16LE(nameBuf.length, 26);
    localHeader.writeUInt16LE(0, 28);

    localChunks.push(localHeader, nameBuf, payload);

    // Central Directory Header (46 bytes + filename)
    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0); // signature
    centralHeader.writeUInt16LE(20, 4); // version made by
    centralHeader.writeUInt16LE(20, 6); // version needed
    centralHeader.writeUInt16LE(0x0800, 8); // UTF-8 flag
    centralHeader.writeUInt16LE(method, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(0x5821, 14);
    centralHeader.writeUInt32LE(checksum, 16);
    centralHeader.writeUInt32LE(payload.length, 20);
    centralHeader.writeUInt32LE(raw.length, 24);
    centralHeader.writeUInt16LE(nameBuf.length, 28);
    centralHeader.writeUInt16LE(0, 30); // extra len
    centralHeader.writeUInt16LE(0, 32); // comment len
    centralHeader.writeUInt16LE(0, 34); // disk start
    centralHeader.writeUInt16LE(0, 36); // internal attrs
    centralHeader.writeUInt32LE(0, 38); // external attrs
    centralHeader.writeUInt32LE(offset, 42);

    centralChunks.push(centralHeader, nameBuf);
    offset += localHeader.length + nameBuf.length + payload.length;
  }

  const centralSize = centralChunks.reduce((sum, b) => sum + b.length, 0);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0); // EOCD signature
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralSize, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([...localChunks, ...centralChunks, eocd]);
}

function escapeXml(str) {
  return String(str ?? '').replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&apos;';
    }
  });
}

function collectFilesRecursive(baseDir, subDir = '') {
  const fullDir = subDir ? join(baseDir, subDir) : baseDir;
  if (!existsSync(fullDir)) return [];
  const results = [];
  for (const item of readdirSync(fullDir)) {
    const abs = join(fullDir, item);
    const st = statSync(abs);
    if (st.isDirectory()) {
      results.push(...collectFilesRecursive(baseDir, join(subDir, item)));
    } else if (st.isFile()) {
      const rel = relative(baseDir, abs).split('\\').join('/');
      results.push({ rel, abs });
    }
  }
  return results;
}

export function buildVsixPackage(extDir) {
  const pkg = JSON.parse(readFileSync(join(extDir, 'package.json'), 'utf-8'));
  const distEntry = join(extDir, 'dist', 'extension.js');
  if (!existsSync(distEntry)) {
    throw new Error(`Compiled extension entry missing at ${distEntry}. Run "npm run build:vscode" first.`);
  }

  const files = [
    { rel: 'package.json', abs: join(extDir, 'package.json') },
    ...(existsSync(join(extDir, 'README.md')) ? [{ rel: 'README.md', abs: join(extDir, 'README.md') }] : []),
    ...collectFilesRecursive(extDir, 'media'),
    ...collectFilesRecursive(extDir, 'dist').filter((f) => !f.rel.endsWith('.vsix')),
  ];

  const extTypes = new Map([
    ['.json', 'application/json'],
    ['.js', 'application/javascript'],
    ['.css', 'text/css'],
    ['.html', 'text/html'],
    ['.svg', 'image/svg+xml'],
    ['.md', 'text/markdown'],
    ['.vsixmanifest', 'text/xml'],
  ]);

  for (const f of files) {
    const ext = extname(f.rel).toLowerCase();
    if (ext && !extTypes.has(ext)) {
      extTypes.set(ext, 'application/octet-stream');
    }
  }

  const contentTypesXml = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    ...[...extTypes.entries()].map(
      ([ext, mime]) => `  <Default Extension="${escapeXml(ext.slice(1))}" ContentType="${escapeXml(mime)}" />`,
    ),
    '</Types>',
    '',
  ].join('\n');

  const categories = Array.isArray(pkg.categories) ? pkg.categories.join(',') : 'Other';
  const engine = pkg.engines?.vscode || '^1.85.0';
  const hasReadme = files.some((f) => f.rel === 'README.md');

  const vsixManifestXml = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">',
    '  <Metadata>',
    `    <Identity Language="en-US" Id="${escapeXml(pkg.name)}" Version="${escapeXml(pkg.version)}" Publisher="${escapeXml(pkg.publisher)}" />`,
    `    <DisplayName>${escapeXml(pkg.displayName || pkg.name)}</DisplayName>`,
    `    <Description xml:space="preserve">${escapeXml(pkg.description || '')}</Description>`,
    `    <Categories>${escapeXml(categories)}</Categories>`,
    '    <GalleryFlags>Public</GalleryFlags>',
    '    <Properties>',
    `      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="${escapeXml(engine)}" />`,
    '      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />',
    '      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />',
    '      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui,workspace" />',
    '      <Property Id="Microsoft.VisualStudio.Services.GitHubFlavoredMarkdown" Value="true" />',
    '    </Properties>',
    '  </Metadata>',
    '  <Installation>',
    '    <InstallationTarget Id="Microsoft.VisualStudio.Code" />',
    '  </Installation>',
    '  <Dependencies />',
    '  <Assets>',
    '    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />',
    ...(hasReadme
      ? ['    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true" />']
      : []),
    '  </Assets>',
    '</PackageManifest>',
    '',
  ].join('\n');

  const zipEntries = [
    { path: '[Content_Types].xml', data: Buffer.from(contentTypesXml, 'utf-8') },
    { path: 'extension.vsixmanifest', data: Buffer.from(vsixManifestXml, 'utf-8') },
    ...files.map((f) => ({
      path: posix.join('extension', f.rel),
      data: readFileSync(f.abs),
    })),
  ];

  const outDir = join(extDir, 'dist');
  mkdirSync(outDir, { recursive: true });
  const vsixPath = join(outDir, `${pkg.name}-${pkg.version}.vsix`);
  writeFileSync(vsixPath, buildZipBuffer(zipEntries));
  return { vsixPath, id: `${pkg.publisher}.${pkg.name}`, version: pkg.version, entryCount: zipEntries.length };
}

export function discoverIdeCliBinaries() {
  const candidates = [];
  if (process.platform === 'darwin') {
    candidates.push(
      { label: 'Antigravity IDE', bin: '/Applications/Antigravity IDE.app/Contents/Resources/app/bin/antigravity-ide' },
      { label: 'Antigravity IDE (User)', bin: join(homedir(), 'Applications/Antigravity IDE.app/Contents/Resources/app/bin/antigravity-ide') },
      { label: 'Visual Studio Code', bin: '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' },
      { label: 'Visual Studio Code (User)', bin: join(homedir(), 'Applications/Visual Studio Code.app/Contents/Resources/app/bin/code') },
    );
  } else if (process.platform === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || join(homedir(), 'AppData', 'Local');
    candidates.push(
      { label: 'Antigravity IDE', bin: join(localAppData, 'Programs', 'Antigravity IDE', 'bin', 'antigravity-ide.cmd') },
      { label: 'Visual Studio Code', bin: join(localAppData, 'Programs', 'Microsoft VS Code', 'bin', 'code.cmd') },
    );
  } else {
    candidates.push(
      { label: 'Antigravity IDE', bin: '/usr/bin/antigravity-ide' },
      { label: 'Visual Studio Code', bin: '/usr/bin/code' },
    );
  }

  const seenReal = new Set();
  const found = [];
  for (const c of candidates) {
    if (!existsSync(c.bin)) continue;
    let real = c.bin;
    try {
      real = realpathSync(c.bin);
    } catch {}
    if (seenReal.has(real)) continue;
    seenReal.add(real);
    found.push(c);
  }
  return found;
}

const isDirectRun =
  process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1]);

if (isDirectRun) {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  const extDir = join(root, 'apps', 'vscode-extension');
  const built = buildVsixPackage(extDir);
  console.log(`[vsix] Packaged ${built.id}@${built.version} (${built.entryCount} files) -> ${built.vsixPath}`);

  if (!process.argv.includes('--package-only')) {
    const clis = discoverIdeCliBinaries();
    if (clis.length === 0) {
      console.log('[vsix] No local IDE CLI binaries detected; VSIX is ready for manual --install-extension.');
    }
    for (const ide of clis) {
      try {
        const out = execFileSync(ide.bin, ['--install-extension', built.vsixPath, '--force'], {
          encoding: 'utf-8',
          timeout: 30000,
        });
        console.log(`[vsix] Installed into ${ide.label}: ${out.trim().split('\n').pop()}`);
      } catch (err) {
        console.error(`[vsix] Warning installing into ${ide.label}: ${err.message}`);
      }
    }
  }
}
