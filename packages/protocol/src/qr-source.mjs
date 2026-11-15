/**
 * Source entry bundled by esbuild into `./qr-svg.mjs` so that
 * `@agy-remote/protocol/qr` has zero runtime npm dependencies (works inside
 * Antigravity's bundled Node runtime without node_modules).
 */
import QRCodeCore from 'qrcode/lib/core/qrcode.js';

/**
 * Generates an ISO/IEC 18004 compliant QR matrix (boolean 2D grid).
 * @param {string} text
 * @param {'L'|'M'|'Q'|'H'} [errorCorrectionLevel='M']
 */
export function createQrMatrix(text, errorCorrectionLevel = 'M') {
  const qr = QRCodeCore.create(String(text || ''), { errorCorrectionLevel });
  const size = qr.modules.size;
  const data = qr.modules.data;
  const rows = [];
  for (let r = 0; r < size; r++) {
    const row = new Array(size);
    for (let c = 0; c < size; c++) {
      row[c] = Boolean(data[r * size + c]);
    }
    rows.push(row);
  }
  return { size, rows };
}

/**
 * Renders a crisp, compact `<svg>` path QR code using run-length horizontal segments.
 * @param {string} text
 * @param {{ margin?: number, dark?: string, light?: string, ecl?: 'L'|'M'|'Q'|'H', sizePx?: number }} [opts]
 */
export function renderQrSvg(text, opts = {}) {
  const margin = opts.margin ?? 2;
  const dark = opts.dark || '#F8FAFC';
  const light = opts.light || '#090D14';
  const sizePx = opts.sizePx || 200;
  const { size, rows } = createQrMatrix(text, opts.ecl || 'M');
  const total = size + margin * 2;

  let pathData = '';
  for (let r = 0; r < size; r++) {
    let c = 0;
    while (c < size) {
      if (!rows[r][c]) {
        c++;
        continue;
      }
      let len = 1;
      while (c + len < size && rows[r][c + len]) len++;
      pathData += `M${c + margin} ${r + margin}h${len}v1h-${len}z`;
      c += len;
    }
  }

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${total}" width="${sizePx}" height="${sizePx}" shape-rendering="crispEdges" role="img" aria-label="Pairing QR Code">`,
    light !== 'transparent' ? `<rect width="${total}" height="${total}" rx="2" fill="${light}"/>` : '',
    `<path d="${pathData}" fill="${dark}"/>`,
    `</svg>`,
  ].join('');
}

/**
 * Renders a compact Unicode half-block QR code for CLI terminals (`agy-bridge`).
 * @param {string} text
 */
export function renderQrTerminal(text) {
  const { size, rows } = createQrMatrix(text, 'L');
  const pad = 2;
  const total = size + pad * 2;
  const darkAt = (r, c) => {
    const mr = r - pad;
    const mc = c - pad;
    if (mr < 0 || mc < 0 || mr >= size || mc >= size) return false;
    return rows[mr][mc];
  };

  const lines = [];
  for (let r = 0; r < total; r += 2) {
    let line = '  ';
    for (let c = 0; c < total; c++) {
      const top = !darkAt(r, c);     // quiet zone = light (true)
      const bot = r + 1 < total ? !darkAt(r + 1, c) : true;
      if (top && bot) line += '█';
      else if (top && !bot) line += '▀';
      else if (!top && bot) line += '▄';
      else line += ' ';
    }
    lines.push(line);
  }
  return lines.join('\n');
}

