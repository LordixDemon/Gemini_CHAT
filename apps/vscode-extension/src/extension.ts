import * as path from 'node:path';
import * as vscode from 'vscode';
import { BridgeControlStatus, BridgeHandle } from './bridge-types.js';
import { RemoteWebviewManager } from './panel.js';
import { computeStatusBarViewModel } from './status-format.js';

// Bundled by esbuild from `@agy-remote/bridge-core`
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore
import { startOrAttachBridge } from '@agy-remote/bridge-core';

let bridgeHandle: BridgeHandle | undefined;
let statusBarItem: vscode.StatusBarItem | undefined;
let webviewManager: RemoteWebviewManager | undefined;
let lastAcceptedTaskAt = 0;
let lastHandledStopAt = 0;

async function cancelActiveAgentInIde(): Promise<void> {
  const cancelCommands = [
    'antigravity.dynamic.interruptAgent',
    'antigravity.cancelAgent',
    'antigravity.stopAgent',
    'workbench.action.chat.cancel',
  ];
  for (const cmd of cancelCommands) {
    try {
      await vscode.commands.executeCommand(cmd);
    } catch {
      // Command may not exist in all IDE variants; ignore safely
    }
  }
}

async function autoAcceptAndSaveAllOnLaptop(): Promise<void> {
  try {
    await vscode.commands.executeCommand('antigravity.acceptAllChanges');
  } catch {
    // Command only registered inside Antigravity IDE; safe no-op in plain VS Code
  }
  try {
    await vscode.workspace.saveAll(false);
  } catch {
    // Ignore read-only / untitled buffer errors
  }
}

function handleBridgeStatus(st: BridgeControlStatus): void {
  updateStatusBar(st);
  const completedAt = st.lastTaskCompletedAt || 0;
  if (completedAt > lastAcceptedTaskAt) {
    lastAcceptedTaskAt = completedAt;
    void autoAcceptAndSaveAllOnLaptop();
  }
  const stoppedAt = st.lastStopRequestedAt || 0;
  if (stoppedAt > lastHandledStopAt) {
    lastHandledStopAt = stoppedAt;
    void cancelActiveAgentInIde();
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const cfg = vscode.workspace.getConfiguration('antigravityRemote');
  const port = cfg.get<number>('port', 7443);
  const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || process.cwd();
  const webClientDir = path.join(context.extensionPath, 'dist', 'web-client');

  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBarItem.command = 'antigravityRemote.openPanel';
  statusBarItem.text = '$(broadcast) AGY Remote…';
  statusBarItem.tooltip = 'Open Antigravity Remote Control & Mobile QR';
  statusBarItem.show();
  context.subscriptions.push(statusBarItem);

  webviewManager = new RemoteWebviewManager(
    () => bridgeHandle,
    (st) => handleBridgeStatus(st),
  );
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(RemoteWebviewManager.viewType, webviewManager),
    { dispose: () => webviewManager?.dispose() },
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('antigravityRemote.openPanel', () => {
      webviewManager?.openStandalonePanel();
    }),
    vscode.commands.registerCommand('antigravityRemote.rotatePin', async () => {
      if (!bridgeHandle) return;
      const st = await bridgeHandle.client.rotatePin();
      updateStatusBar(st);
      await webviewManager?.refreshAll(st);
      void vscode.window.showInformationMessage(`New Antigravity PIN: ${st.pairing.formattedPin}`);
    }),
    vscode.commands.registerCommand('antigravityRemote.setApprovalMode', async () => {
      if (!bridgeHandle) return;
      const picked = await vscode.window.showQuickPick(
        [
          { label: 'ask-mobile', description: 'Prompt connected phone on run_command / write_file / edit_file' },
          { label: 'auto-safe', description: 'Auto-approve safe tests/git; ask phone for writes' },
          { label: 'observe', description: 'Monitor & chat only; never hold PreToolUse hook' },
        ],
        { placeHolder: 'Select Mobile Tool Approval Mode' },
      );
      if (picked) {
        const st = await bridgeHandle.client.updateSettings({ approvalMode: picked.label });
        updateStatusBar(st);
        await webviewManager?.refreshAll(st);
      }
    }),
    vscode.commands.registerCommand('antigravityRemote.configureCloudflare', async () => {
      if (!bridgeHandle) return;
      const edgeUrl = await vscode.window.showInputBox({
        prompt: 'Enter Cloudflare Worker Relay URL (leave blank to disable)',
        placeHolder: 'https://agy-remote.your-domain.workers.dev',
      });
      if (edgeUrl === undefined) return;
      const mode = edgeUrl.trim() ? 'edge-worker' : 'disabled';
      const st = await bridgeHandle.client.updateSettings({
        cloudflareMode: mode,
        cloudflareEdgeUrl: edgeUrl.trim(),
      });
      updateStatusBar(st);
      await webviewManager?.refreshAll(st);
    }),
  );

  try {
    bridgeHandle = (await startOrAttachBridge({
      port,
      defaultWorkspace: workspaceRoot,
      webClientDir,
    })) as BridgeHandle;

    lastAcceptedTaskAt = bridgeHandle.initialStatus.lastTaskCompletedAt || 0;
    lastHandledStopAt = bridgeHandle.initialStatus.lastStopRequestedAt || 0;
    updateStatusBar(bridgeHandle.initialStatus);
    webviewManager.startPolling();

    if (bridgeHandle.server) {
      bridgeHandle.server.on('status_changed', (st: BridgeControlStatus) => {
        handleBridgeStatus(st);
        void webviewManager?.refreshAll(st);
      });
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    statusBarItem.text = '$(error) AGY Remote Offline';
    void vscode.window.showErrorMessage(`Failed to start Antigravity Remote Bridge: ${msg}`);
  }
}

function updateStatusBar(st: BridgeControlStatus): void {
  if (!statusBarItem) return;
  const vm = computeStatusBarViewModel(st);
  statusBarItem.text = vm.text;
  statusBarItem.backgroundColor = vm.isWarning
    ? new vscode.ThemeColor('statusBarItem.warningBackground')
    : undefined;
}

export async function deactivate(): Promise<void> {
  webviewManager?.dispose();
  if (bridgeHandle?.server) {
    await bridgeHandle.server.stop();
  }
}

