#!/usr/bin/env node
/**
 * `agy-bridge` — Claude Code `/rc` style terminal Remote Control launcher for Google Antigravity!
 * Prints a scannable QR code + 6-digit PIN directly in the terminal and hosts/attaches to BridgeServer.
 */
import { startOrAttachBridge } from '../src/index.mjs';

const portArg = process.argv.find((a) => a.startsWith('--port='));
const port = portArg ? Number(portArg.split('=')[1]) : undefined;

const handle = await startOrAttachBridge({ port, defaultWorkspace: process.cwd() });
const st = handle.initialStatus;

console.log('\n============================================================');
console.log(`  ANTIGRAVITY REMOTE CONTROL (${handle.mode.toUpperCase()})`);
console.log('============================================================');
console.log(`  Machine       : ${st.machineName} (${st.machineId})`);
console.log(`  LAN URL       : ${st.lanBaseUrl}`);
console.log(`  6-Digit PIN   : ${st.pairing.formattedPin}`);
console.log(`  Approval Gate : ${st.settings.approvalMode}`);
console.log(`  Sessions Found: ${st.sessions.length} in ~/.gemini/*/brain`);
console.log('------------------------------------------------------------');
console.log('  Scan with Flutter App OR Mobile Camera (instant PWA):\n');
console.log(st.pairing.qrTerminal);
console.log(`\n  Pairing Link  : ${st.pairing.pairingUrl}`);
console.log('============================================================\n');

if (handle.server) {
  const shutdown = async () => {
    console.log('\n[agy-bridge] Shutting down BridgeServer...');
    await handle.server.stop();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
} else {
  console.log('[agy-bridge] Attached to already running local Bridge daemon.');
}

