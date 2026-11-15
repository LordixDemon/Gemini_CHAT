import * as vscode from 'vscode';
import { BridgeControlStatus, BridgeHandle } from './bridge-types.js';

export class RemoteWebviewManager implements vscode.WebviewViewProvider {
  public static readonly viewType = 'antigravityRemote.sidebarView';

  private sidebarView?: vscode.WebviewView;
  private standalonePanel?: vscode.WebviewPanel;
  private pollTimer?: NodeJS.Timeout;

  constructor(
    private readonly getBridge: () => BridgeHandle | undefined,
    private readonly onStatus?: (status: BridgeControlStatus) => void,
  ) {}

  public startPolling(): void {
    if (this.pollTimer) return;
    this.pollTimer = setInterval(() => {
      void this.refreshAll();
    }, 1500);
  }

  public dispose(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
    this.standalonePanel?.dispose();
  }

  public resolveWebviewView(webviewView: vscode.WebviewView): void {
    this.sidebarView = webviewView;
    webviewView.webview.options = { enableScripts: true };
    webviewView.webview.html = this.buildHtml();
    this.bindMessages(webviewView.webview);
    webviewView.onDidDispose(() => {
      this.sidebarView = undefined;
    });
    void this.refreshAll();
  }

  public openStandalonePanel(): void {
    if (this.standalonePanel) {
      this.standalonePanel.reveal(vscode.ViewColumn.Beside);
      void this.refreshAll();
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      'antigravityRemotePanel',
      'Antigravity Remote Control',
      vscode.ViewColumn.Beside,
      { enableScripts: true, retainContextWhenHidden: true },
    );
    this.standalonePanel = panel;
    panel.webview.html = this.buildHtml();
    this.bindMessages(panel.webview);
    panel.onDidDispose(() => {
      this.standalonePanel = undefined;
    });
    void this.refreshAll();
  }

  public async refreshAll(providedStatus?: BridgeControlStatus): Promise<void> {
    const handle = this.getBridge();
    if (!handle) return;
    try {
      const status = providedStatus || (await handle.client.getControlStatus());
      this.onStatus?.(status);
      const msg = { type: 'status', status };
      this.sidebarView?.webview.postMessage(msg);
      this.standalonePanel?.webview.postMessage(msg);
    } catch {
      // Ignore transient refresh failure
    }
  }

  private bindMessages(webview: vscode.Webview): void {
    webview.onDidReceiveMessage(async (msg: Record<string, unknown>) => {
      const handle = this.getBridge();
      if (!handle) return;
      try {
        switch (msg.action) {
          case 'ready': {
            await this.refreshAll();
            break;
          }
          case 'rotatePin': {
            const st = await handle.client.rotatePin();
            await this.refreshAll(st);
            break;
          }
          case 'revokeDevice': {
            const st = await handle.client.revokeDevice(String(msg.deviceId || ''));
            await this.refreshAll(st);
            break;
          }
          case 'updateSettings': {
            const st = await handle.client.updateSettings(
              (msg.settings as Record<string, unknown>) || {},
            );
            await this.refreshAll(st);
            break;
          }
          case 'decideApproval': {
            await handle.client.decideApproval(msg);
            await this.refreshAll();
            break;
          }
          case 'saveChanges': {
            const st = await handle.client.saveChanges(
              Array.isArray(msg.paths) ? (msg.paths as string[]) : undefined,
            );
            await this.refreshAll(st);
            break;
          }
          case 'revertChanges': {
            const st = await handle.client.revertChanges({
              paths: Array.isArray(msg.paths) ? (msg.paths as string[]) : undefined,
              all: Boolean(msg.all),
            });
            await this.refreshAll(st);
            break;
          }
          case 'copyUrl': {
            await vscode.env.clipboard.writeText(String(msg.url || ''));
            void vscode.window.showInformationMessage('Pairing URL copied to clipboard.');
            break;
          }
        }
      } catch (err) {
        const errMsg = err instanceof Error ? err.message : String(err);
        void vscode.window.showErrorMessage(`Antigravity Remote: ${errMsg}`);
      }
    });
  }

  private buildHtml(): string {
    return `<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --bg: var(--vscode-sideBar-background, #090D14);
      --card: var(--vscode-editorWidget-background, #101622);
      --border: var(--vscode-panel-border, #222F46);
      --fg: var(--vscode-foreground, #F1F5F9);
      --muted: var(--vscode-descriptionForeground, #94A3B8);
      --accent: #38BDF8;
      --live: #10B981;
      --warn: #F59E0B;
      --danger: #EF4444;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 12px;
      background: var(--bg); color: var(--fg);
      font-family: var(--vscode-font-family, sans-serif);
      font-size: 12.5px;
    }
    .stack { display: flex; flex-direction: column; gap: 10px; }
    .card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 11px;
    }
    .row-between { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
    .qr-box {
      width: 156px; height: 156px; margin: 8px auto;
      border-radius: 8px; overflow: hidden;
      border: 1px solid var(--border); background: #090D14;
    }
    .qr-box svg { width: 100%; height: 100%; display: block; }
    .pin {
      font-family: var(--vscode-editor-font-family, monospace);
      font-size: 20px; font-weight: 700; color: var(--accent);
      letter-spacing: 0.1em; text-align: center; margin: 4px 0;
    }
    .muted { color: var(--muted); font-size: 11px; }
    input, select {
      width: 100%; padding: 6px 8px;
      background: var(--vscode-input-background, #090D14);
      color: var(--vscode-input-foreground, #F1F5F9);
      border: 1px solid var(--border); border-radius: 5px;
      font-size: 12px;
    }
    button {
      background: var(--accent); color: #051320;
      border: none; border-radius: 5px;
      padding: 6px 10px; font-weight: 600; font-size: 11.5px;
      cursor: pointer;
    }
    button.ghost {
      background: transparent; color: var(--fg);
      border: 1px solid var(--border);
    }
    button.active {
      border-color: var(--accent);
      background: rgba(56, 189, 248, 0.16);
      color: var(--accent);
    }
    .modes { display: grid; grid-template-columns: repeat(3, 1fr); gap: 5px; margin-top: 6px; }
    .pill {
      padding: 2px 7px; border-radius: 99px; font-size: 11px;
      background: rgba(16, 185, 129, 0.16); color: var(--live);
    }
    .hidden { display: none !important; }
    .warn-card { border-color: var(--warn); }
    .danger-btn { background: rgba(239, 68, 68, 0.16); color: #FCA5A5; border: 1px solid var(--danger); }
  </style>
</head>
<body>
  <div class="stack">
    <div id="pendingCard" class="card warn-card hidden">
      <div class="row-between" style="margin-bottom:6px">
        <div style="display:flex;align-items:center;gap:6px">
          <strong style="color:var(--warn)">Ожидает подтверждения</strong>
          <span id="pendingBadge" class="pill" style="color:var(--warn);background:rgba(245,158,11,0.16)">0</span>
        </div>
        <button id="btnAllowAll" class="hidden">Разрешить всё</button>
      </div>
      <div id="pendingList" class="stack"></div>
    </div>

    <div id="changesCard" class="card hidden" style="border-color:rgba(16,185,129,0.5)">
      <div class="row-between" style="margin-bottom:6px">
        <div style="display:flex;align-items:center;gap:6px">
          <strong style="color:var(--live)">Изменённые файлы</strong>
          <span id="changesBadge" class="pill">0</span>
        </div>
        <div style="display:flex;gap:4px">
          <button id="btnRevertAll" class="danger-btn">Откатить</button>
          <button id="btnSaveAll" style="background:var(--live);color:#041A12">Сохранить всё</button>
        </div>
      </div>
      <div id="changesList" class="stack"></div>
    </div>

    <div class="card">
      <div class="row-between">
        <strong id="hostName">Antigravity Remote</strong>
        <span id="onlineBadge" class="pill">0 online</span>
      </div>
      <div id="qrBox" class="qr-box"></div>
      <div id="pinCode" class="pin">--- ---</div>
      <div class="row-between" style="margin-top:6px">
        <button class="ghost" id="btnRotate" style="flex:1">Новый PIN</button>
        <button class="ghost" id="btnCopy" style="flex:1">Копировать URL</button>
      </div>
      <div style="margin-top:8px">
        <div class="muted" style="margin-bottom:3px">LAN интерфейс</div>
        <select id="lanSelect"></select>
      </div>
    </div>

    <div class="card">
      <strong>Проверка тулов (PreToolUse)</strong>
      <div class="modes">
        <button class="ghost mode" data-m="ask-mobile">Ask Phone</button>
        <button class="ghost mode" data-m="auto-safe">Auto-Safe</button>
        <button class="ghost mode" data-m="observe">Observe</button>
      </div>
    </div>

    <div class="card stack">
      <div class="row-between">
        <strong>Cloudflare Сессии</strong>
        <span id="cfState" class="muted">LAN Only</span>
      </div>
      <select id="cfMode">
        <option value="disabled">Отключено (LAN)</option>
        <option value="edge-worker">Workers + Durable Objects</option>
        <option value="cloudflared">cloudflared Quick Tunnel</option>
      </select>
      <input id="cfUrl" type="url" placeholder="https://agy-remote.workers.dev">
      <input id="cfSecret" type="password" placeholder="Host Secret">
      <button id="btnSaveCf">Применить Cloudflare</button>
    </div>

    <div class="card">
      <strong>Устройства</strong>
      <div id="devList" class="stack" style="margin-top:6px"></div>
    </div>
  </div>

  <script>
    const vscode = acquireVsCodeApi();
    let currentUrl = '';
    let cfTouched = false;

    function esc(s) {
      return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    }

    window.addEventListener('message', (ev) => {
      const msg = ev.data;
      if (msg?.type === 'status' && msg.status) render(msg.status);
    });

    function render(st) {
      document.getElementById('hostName').textContent = st.machineName + ' :' + st.port;
      document.getElementById('onlineBadge').textContent = st.connectedClients.total + ' online';
      document.getElementById('pinCode').textContent = st.pairing.formattedPin;
      if (st.pairing.pairingUrl !== currentUrl) {
        currentUrl = st.pairing.pairingUrl;
        document.getElementById('qrBox').innerHTML = st.pairing.qrSvg;
      }

      const sel = document.getElementById('lanSelect');
      sel.innerHTML = (st.lanInterfaces || []).map((i) =>
        '<option value="' + esc(i.address) + '" ' + (i.address === st.lanIp ? 'selected' : '') + '>' + esc(i.address) + ' (' + esc(i.interface) + ')</option>'
      ).join('');

      document.querySelectorAll('.mode').forEach((b) => {
        b.classList.toggle('active', b.dataset.m === st.settings.approvalMode);
      });

      document.getElementById('cfState').textContent = st.cloudflare.status === 'connected' ? 'CF Connected' : 'LAN Only';
      if (!cfTouched) {
        document.getElementById('cfMode').value = st.settings.cloudflareMode || 'disabled';
        document.getElementById('cfUrl').value = st.settings.cloudflareEdgeUrl || '';
        document.getElementById('cfSecret').value = st.settings.cloudflareEdgeSecret || '';
      }

      const pending = st.pendingApprovals || [];
      const pCard = document.getElementById('pendingCard');
      if (pending.length > 0) {
        pCard.classList.remove('hidden');
        document.getElementById('pendingBadge').textContent = String(pending.length);
        const allowAllBtn = document.getElementById('btnAllowAll');
        allowAllBtn.classList.toggle('hidden', pending.length <= 1);
        allowAllBtn.textContent = 'Разрешить всё (' + pending.length + ')';
        const pList = document.getElementById('pendingList');
        pList.innerHTML = pending.map((a) =>
          '<div class="row-between"><div><strong>' + esc(a.toolName) + '</strong><div class="muted">' + esc(a.summary) + '</div></div>' +
          '<div style="display:flex;gap:4px"><button class="danger-btn" data-apr="' + esc(a.id) + '" data-dec="deny">Deny</button>' +
          '<button data-apr="' + esc(a.id) + '" data-dec="allow">Allow</button></div></div>'
        ).join('');
        pList.querySelectorAll('button[data-apr]').forEach((b) => {
          b.onclick = () => vscode.postMessage({ action: 'decideApproval', id: b.dataset.apr, decision: b.dataset.dec });
        });
      } else {
        pCard.classList.add('hidden');
      }

      const changes = st.pendingChanges || [];
      const cCard = document.getElementById('changesCard');
      if (changes.length > 0) {
        cCard.classList.remove('hidden');
        document.getElementById('changesBadge').textContent = String(changes.length);
        const cList = document.getElementById('changesList');
        cList.innerHTML = changes.map((f) =>
          '<div class="row-between"><div style="min-width:0;flex:1"><strong style="display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(f.path) + '</strong>' +
          '<div class="muted">' + esc(f.status) + ' • +' + Number(f.additions || 0) + ' -' + Number(f.deletions || 0) + '</div></div>' +
          '<div style="display:flex;gap:4px"><button class="danger-btn" data-revf="' + esc(f.path) + '">Откатить</button>' +
          '<button class="ghost" data-savf="' + esc(f.path) + '">ОК</button></div></div>'
        ).join('');
        cList.querySelectorAll('button[data-revf]').forEach((b) => {
          b.onclick = () => vscode.postMessage({ action: 'revertChanges', paths: [b.dataset.revf] });
        });
        cList.querySelectorAll('button[data-savf]').forEach((b) => {
          b.onclick = () => vscode.postMessage({ action: 'saveChanges', paths: [b.dataset.savf] });
        });
      } else {
        cCard.classList.add('hidden');
      }

      const devBox = document.getElementById('devList');
      devBox.innerHTML = (st.pairedDevices || []).length
        ? st.pairedDevices.map((d) =>
            '<div class="row-between"><span class="muted">' + esc(d.name) + ' (' + esc(d.platform) + ')</span><button class="ghost" data-rev="' + esc(d.id) + '">X</button></div>'
          ).join('')
        : '<span class="muted">Сканируйте QR-код с телефона</span>';

      devBox.querySelectorAll('button[data-rev]').forEach((b) => {
        b.onclick = () => vscode.postMessage({ action: 'revokeDevice', deviceId: b.dataset.rev });
      });
    }

    document.getElementById('btnRotate').onclick = () => vscode.postMessage({ action: 'rotatePin' });
    document.getElementById('btnAllowAll').onclick = () =>
      vscode.postMessage({ action: 'decideApproval', all: true, decision: 'allow' });
    document.getElementById('btnSaveAll').onclick = () => vscode.postMessage({ action: 'saveChanges' });
    document.getElementById('btnRevertAll').onclick = () =>
      vscode.postMessage({ action: 'revertChanges', all: true });
    document.getElementById('btnCopy').onclick = () => vscode.postMessage({ action: 'copyUrl', url: currentUrl });
    document.getElementById('lanSelect').onchange = (e) =>
      vscode.postMessage({ action: 'updateSettings', settings: { preferredLanIp: e.target.value } });

    document.querySelectorAll('.mode').forEach((b) => {
      b.onclick = () => vscode.postMessage({ action: 'updateSettings', settings: { approvalMode: b.dataset.m } });
    });

    ['cfMode', 'cfUrl', 'cfSecret'].forEach((id) => {
      document.getElementById(id).oninput = () => { cfTouched = true; };
    });

    document.getElementById('btnSaveCf').onclick = () => {
      cfTouched = false;
      vscode.postMessage({
        action: 'updateSettings',
        settings: {
          cloudflareMode: document.getElementById('cfMode').value,
          cloudflareEdgeUrl: document.getElementById('cfUrl').value,
          cloudflareEdgeSecret: document.getElementById('cfSecret').value,
        },
      });
    };

    vscode.postMessage({ action: 'ready' });
  </script>
</body>
</html>`;
  }
}

