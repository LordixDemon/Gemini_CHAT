/**
 * Zero-dependency RFC 6455 WebSocket Server implementation over Node `node:http` & `node:crypto`.
 * Designed so `@agy-remote/bridge-core` runs cleanly inside Antigravity's bundled Node runtime,
 * VS Code's Extension Host, or standalone CLI without native addons or external npm packages.
 */
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_FRAME_BYTES = 8 * 1024 * 1024; // 8 MiB incoming client->server cap (server->client is unbounded 64-bit)

export class WsPeer extends EventEmitter {
  /**
   * @param {import('node:stream').Duplex} socket
   * @param {Record<string, any>} meta
   */
  constructor(socket, meta = {}) {
    super();
    this.socket = socket;
    this.meta = meta;
    this.readyState = 1; // OPEN
    this._buf = Buffer.alloc(0);
    this._fragments = [];
    this._fragmentOpcode = 0;
    this.lastPongAt = Date.now();
    this.lastActivityAt = Date.now();

    socket.setNoDelay?.(true);
    socket.setKeepAlive?.(true, 10_000);
    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('close', () => this._markClosed(1006, 'socket_closed'));
    socket.on('end', () => {
      try {
        socket.end();
      } catch {}
      const destroyTimer = setTimeout(() => {
        try {
          socket.destroy();
        } catch {}
      }, 150);
      destroyTimer.unref?.();
      this._markClosed(1000, 'socket_end');
    });
    socket.on('error', (err) => {
      if (this.listenerCount('error') > 0) {
        this.emit('error', err);
      }
      this._markClosed(1011, err.message);
    });
  }

  sendText(str) {
    if (this.readyState !== 1) return false;
    const payload = Buffer.from(String(str), 'utf-8');
    return this._writeFrame(0x1, payload);
  }

  sendJson(obj) {
    return this.sendText(JSON.stringify(obj));
  }

  ping() {
    if (this.readyState !== 1) return false;
    return this._writeFrame(0x9, Buffer.alloc(0));
  }

  close(code = 1000, reason = '') {
    if (this.readyState !== 1) return;
    this.readyState = 2; // CLOSING
    const reasonBuf = Buffer.from(String(reason).slice(0, 120), 'utf-8');
    const payload = Buffer.alloc(2 + reasonBuf.length);
    payload.writeUInt16BE(code, 0);
    reasonBuf.copy(payload, 2);
    this._writeFrame(0x8, payload);
    const closeTimer = setTimeout(() => {
      try {
        this.socket.destroy();
      } catch {}
      this._markClosed(code, reason);
    }, 150);
    closeTimer.unref?.();
  }

  _writeFrame(opcode, payload) {
    if (this.socket.destroyed) return false;
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.alloc(2);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = len;
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    try {
      this.socket.write(Buffer.concat([header, payload]));
      return true;
    } catch {
      return false;
    }
  }

  _onData(chunk) {
    this.lastActivityAt = Date.now();
    this._buf = this._buf.length ? Buffer.concat([this._buf, chunk]) : chunk;

    while (this._buf.length >= 2) {
      const b0 = this._buf[0];
      const b1 = this._buf[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let payloadLen = b1 & 0x7f;
      let offset = 2;

      if (payloadLen === 126) {
        if (this._buf.length < 4) return;
        payloadLen = this._buf.readUInt16BE(2);
        offset = 4;
      } else if (payloadLen === 127) {
        if (this._buf.length < 10) return;
        const bigLen = this._buf.readBigUInt64BE(2);
        if (bigLen > BigInt(MAX_FRAME_BYTES)) {
          this.close(1009, 'Frame too large');
          return;
        }
        payloadLen = Number(bigLen);
        offset = 10;
      }

      if (payloadLen > MAX_FRAME_BYTES) {
        this.close(1009, 'Frame too large');
        return;
      }

      const maskBytes = masked ? 4 : 0;
      const frameTotal = offset + maskBytes + payloadLen;
      if (this._buf.length < frameTotal) return;

      let payload = this._buf.subarray(offset + maskBytes, frameTotal);
      if (masked) {
        const mask = this._buf.subarray(offset, offset + 4);
        const unmasked = Buffer.allocUnsafe(payloadLen);
        for (let i = 0; i < payloadLen; i++) {
          unmasked[i] = payload[i] ^ mask[i & 3];
        }
        payload = unmasked;
      } else {
        payload = Buffer.from(payload);
      }

      this._buf = frameTotal >= this._buf.length ? Buffer.alloc(0) : this._buf.subarray(frameTotal);
      this._handleFrame(fin, opcode, payload);
    }
  }

  _handleFrame(fin, opcode, payload) {
    if (opcode === 0x8) {
      // Close frame
      const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1000;
      const reason = payload.length > 2 ? payload.subarray(2).toString('utf-8') : '';
      if (this.readyState === 1) {
        this.readyState = 2;
        this._writeFrame(0x8, payload.subarray(0, Math.min(payload.length, 125)));
      }
      try {
        this.socket.end();
      } catch {}
      const destroyTimer = setTimeout(() => {
        try {
          this.socket.destroy();
        } catch {}
      }, 150);
      destroyTimer.unref?.();
      this._markClosed(code, reason);
      return;
    }

    if (opcode === 0x9) {
      // Ping -> Pong
      this._writeFrame(0x0a, payload);
      return;
    }

    if (opcode === 0x0a) {
      // Pong
      this.lastPongAt = Date.now();
      this.emit('pong');
      return;
    }

    if (opcode === 0x0) {
      // Continuation frame
      if (this._fragmentOpcode === 0) {
        this.close(1002, 'Unexpected continuation frame');
        return;
      }
      this._fragments.push(payload);
      const total = this._fragments.reduce((acc, b) => acc + b.length, 0);
      if (total > MAX_FRAME_BYTES) {
        this.close(1009, 'Message too large');
        return;
      }
      if (fin) {
        const full = Buffer.concat(this._fragments);
        const origOpcode = this._fragmentOpcode;
        this._fragments = [];
        this._fragmentOpcode = 0;
        if (origOpcode === 0x1) {
          this.emit('message', full.toString('utf-8'));
        } else {
          this.emit('binary', full);
        }
      }
      return;
    }

    if (opcode === 0x1 || opcode === 0x2) {
      if (!fin) {
        this._fragmentOpcode = opcode;
        this._fragments = [payload];
        return;
      }
      if (opcode === 0x1) {
        this.emit('message', payload.toString('utf-8'));
      } else {
        this.emit('binary', payload);
      }
    }
  }

  _markClosed(code, reason) {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit('close', { code, reason });
  }
}

/**
 * Completes an HTTP -> RFC 6455 WebSocket upgrade and returns a `WsPeer`.
 */
export function upgradeToWebSocket(req, socket, head, meta = {}) {
  const key = req.headers['sec-websocket-key'];
  if (!key || typeof key !== 'string') {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
    socket.destroy();
    return null;
  }

  const accept = createHash('sha1').update(key.trim() + WS_GUID).digest('base64');
  const headers = [
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${accept}`,
    '\r\n',
  ];
  socket.write(headers.join('\r\n'));

  const peer = new WsPeer(socket, meta);
  if (head && head.length > 0) {
    peer._onData(head);
  }
  return peer;
}

