import assert from 'node:assert/strict';
import { Duplex } from 'node:stream';
import test from 'node:test';

import { WsPeer, upgradeToWebSocket } from '../packages/bridge-core/src/rfc6455-ws.mjs';

/**
 * Creates an in-memory bi-directional TCP socket pair for deterministic RFC 6455 unit testing.
 */
function createDuplexPair() {
  let sideA;
  let sideB;
  const writtenByServer = [];

  sideA = new Duplex({
    read() {},
    write(chunk, _enc, cb) {
      writtenByServer.push(Buffer.from(chunk));
      if (!sideB.destroyed) sideB.push(chunk);
      cb();
    },
    final(cb) {
      if (!sideB.destroyed) sideB.push(null);
      cb();
    },
  });

  sideB = new Duplex({
    read() {},
    write(chunk, _enc, cb) {
      if (!sideA.destroyed) sideA.push(chunk);
      cb();
    },
    final(cb) {
      if (!sideA.destroyed) sideA.push(null);
      cb();
    },
  });

  return { serverSocket: sideA, clientSocket: sideB, writtenByServer };
}

function encodeClientFrame(opcode, payload, { fin = true, masked = true } = {}) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf-8');
  const len = body.length;
  const maskBit = masked ? 0x80 : 0x00;
  let header;

  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0f);
    header[1] = maskBit | len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0f);
    header[1] = maskBit | 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0f);
    header[1] = maskBit | 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }

  if (!masked) {
    return Buffer.concat([header, body]);
  }

  const maskKey = Buffer.from([0x37, 0xfa, 0x21, 0x3d]);
  const maskedBody = Buffer.allocUnsafe(len);
  for (let i = 0; i < len; i++) {
    maskedBody[i] = body[i] ^ maskKey[i & 3];
  }
  return Buffer.concat([header, maskKey, maskedBody]);
}

function decodeServerFrame(buf) {
  const fin = (buf[0] & 0x80) !== 0;
  const opcode = buf[0] & 0x0f;
  let len = buf[1] & 0x7f;
  let offset = 2;
  if (len === 126) {
    len = buf.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    len = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }
  return { fin, opcode, payload: buf.subarray(offset, offset + len) };
}

test('upgradeToWebSocket rejects missing key with 400 and completes valid RFC 6455 handshake', async () => {
  const bad = createDuplexPair();
  const resNull = upgradeToWebSocket({ headers: {} }, bad.serverSocket, Buffer.alloc(0));
  assert.equal(resNull, null);
  assert.ok(Buffer.concat(bad.writtenByServer).toString('utf-8').includes('400 Bad Request'));

  const good = createDuplexPair();
  const initialHead = encodeClientFrame(0x1, '{"hello":"head"}');
  const received = [];
  const peer = upgradeToWebSocket(
    { headers: { 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==' } },
    good.serverSocket,
    Buffer.alloc(0),
    { role: 'test' },
  );
  assert.ok(peer instanceof WsPeer);
  const handshake = Buffer.concat(good.writtenByServer).toString('utf-8');
  assert.ok(handshake.includes('101 Switching Protocols'));
  assert.ok(handshake.includes('Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='));

  // Also verify head bytes delivered during upgrade are parsed immediately
  const withHead = createDuplexPair();
  const headPeer = upgradeToWebSocket(
    { headers: { 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==' } },
    withHead.serverSocket,
    initialHead,
  );
  assert.equal(headPeer.readyState, 1);

  peer.on('message', (m) => received.push(m));
  good.clientSocket.write(initialHead);
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(received, ['{"hello":"head"}']);
});

test('WsPeer handles 7-bit, 16-bit, and 64-bit frames, chunked TCP splits, fragmentation, and ping/pong', async () => {
  const { serverSocket, clientSocket, writtenByServer } = createDuplexPair();
  const peer = new WsPeer(serverSocket);

  const textMessages = [];
  const binaryMessages = [];
  let pongCount = 0;
  peer.on('message', (m) => textMessages.push(m));
  peer.on('binary', (b) => binaryMessages.push(b));
  peer.on('pong', () => {
    pongCount++;
  });

  // 1. Server outbound <126B, 16-bit (2000B), and 64-bit (70000B) frames
  assert.equal(peer.sendJson({ ok: true }), true);
  assert.equal(peer.sendText('A'.repeat(2000)), true);
  assert.equal(peer.sendText('B'.repeat(70000)), true);

  assert.equal(writtenByServer.length, 3);
  assert.equal(decodeServerFrame(writtenByServer[0]).payload.toString('utf-8'), '{"ok":true}');
  assert.equal(decodeServerFrame(writtenByServer[1]).payload.length, 2000);
  assert.equal(decodeServerFrame(writtenByServer[2]).payload.length, 70000);

  // 2. Client masked 16-bit frame split across tiny TCP chunks
  const mediumPayload = 'Привет-'.repeat(600); // > 4 KB UTF-8
  const mediumFrame = encodeClientFrame(0x1, mediumPayload);
  clientSocket.write(mediumFrame.subarray(0, 1));
  clientSocket.write(mediumFrame.subarray(1, 3));
  clientSocket.write(mediumFrame.subarray(3, 50));
  clientSocket.write(mediumFrame.subarray(50));
  await new Promise((r) => setImmediate(r));
  assert.equal(textMessages.at(-1), mediumPayload);

  // 3. Multi-frame fragmented text + interleaved ping frame
  writtenByServer.length = 0;
  clientSocket.write(encodeClientFrame(0x1, 'part-1:', { fin: false }));
  clientSocket.write(encodeClientFrame(0x9, 'hb', { fin: true })); // interleaved ping!
  clientSocket.write(encodeClientFrame(0x0, 'part-2:', { fin: false, masked: false }));
  clientSocket.write(encodeClientFrame(0x0, 'part-3', { fin: true }));
  await new Promise((r) => setImmediate(r));

  assert.equal(textMessages.at(-1), 'part-1:part-2:part-3');
  const pongFrame = decodeServerFrame(writtenByServer[0]);
  assert.equal(pongFrame.opcode, 0x0a);
  assert.equal(pongFrame.payload.toString('utf-8'), 'hb');

  // 4. Fragmented binary message + server ping -> client pong
  clientSocket.write(encodeClientFrame(0x2, Buffer.from([1, 2]), { fin: false }));
  clientSocket.write(encodeClientFrame(0x0, Buffer.from([3, 4]), { fin: true }));
  assert.equal(peer.ping(), true);
  clientSocket.write(encodeClientFrame(0x0a, Buffer.alloc(0)));
  await new Promise((r) => setImmediate(r));

  assert.equal(binaryMessages.length, 1);
  assert.deepEqual([...binaryMessages[0]], [1, 2, 3, 4]);
  assert.equal(pongCount, 1);

  // 5. Clean client close handshake (0x8)
  let closedInfo = null;
  peer.on('close', (info) => {
    closedInfo = info;
  });
  const closePayload = Buffer.alloc(5);
  closePayload.writeUInt16BE(1000, 0);
  closePayload.write('bye', 2, 'utf-8');
  clientSocket.write(encodeClientFrame(0x8, closePayload));
  await new Promise((r) => setImmediate(r));

  assert.deepEqual(closedInfo, { code: 1000, reason: 'bye' });
  assert.equal(peer.readyState, 3);
  assert.equal(peer.sendText('after-close'), false);
  assert.equal(peer.ping(), false);
});

test('WsPeer closes with 1002 on unexpected continuation frame and 1009 on oversized 64-bit header', async () => {
  // Unexpected continuation frame (opcode 0x0 with no active fragment)
  const pair1 = createDuplexPair();
  const peer1 = new WsPeer(pair1.serverSocket);
  pair1.clientSocket.write(encodeClientFrame(0x0, 'orphan', { fin: true }));
  await new Promise((r) => setImmediate(r));
  const close1 = decodeServerFrame(pair1.writtenByServer[0]);
  assert.equal(close1.opcode, 0x8);
  assert.equal(close1.payload.readUInt16BE(0), 1002);

  // Oversized 64-bit header (> 8 MiB MAX_FRAME_BYTES)
  const pair2 = createDuplexPair();
  const peer2 = new WsPeer(pair2.serverSocket);
  const hugeHeader = Buffer.alloc(10);
  hugeHeader[0] = 0x82; // FIN + binary
  hugeHeader[1] = 127;
  hugeHeader.writeBigUInt64BE(BigInt(16 * 1024 * 1024), 2);
  pair2.clientSocket.write(hugeHeader);
  await new Promise((r) => setImmediate(r));
  const close2 = decodeServerFrame(pair2.writtenByServer[0]);
  assert.equal(close2.opcode, 0x8);
  assert.equal(close2.payload.readUInt16BE(0), 1009);
  assert.equal(peer2.readyState, 2);
});

test('WsPeer survives abrupt ECONNRESET socket error without listener and emits error when listened', () => {
  // 1. Without 'error' listener (regression test for mobile lock-screen ECONNRESET!)
  const pair1 = createDuplexPair();
  const peer1 = new WsPeer(pair1.serverSocket);
  let closeEvent = null;
  peer1.on('close', (ev) => {
    closeEvent = ev;
  });

  assert.doesNotThrow(() => {
    pair1.serverSocket.emit('error', Object.assign(new Error('read ECONNRESET'), { code: 'ECONNRESET' }));
  });
  assert.equal(peer1.readyState, 3);
  assert.equal(closeEvent.code, 1011);

  // 2. With 'error' listener attached
  const pair2 = createDuplexPair();
  const peer2 = new WsPeer(pair2.serverSocket);
  let capturedErr = null;
  peer2.on('error', (err) => {
    capturedErr = err;
  });
  pair2.serverSocket.emit('error', new Error('custom socket fault'));
  assert.equal(capturedErr.message, 'custom socket fault');
});

