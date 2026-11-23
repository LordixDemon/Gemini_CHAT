(() => {
  const $ = (id) => document.getElementById(id);
  const rpcFetch = window.sidecar?.fetch ? window.sidecar.fetch.bind(window.sidecar) : fetch;

  let lastQrUrl = '';
  let cfDirty = false;

  async function apiGet(path) {
    const res = await rpcFetch(path, { method: 'GET' });
    return res.json();
  }

  async function apiAction(payload) {
    const res = await rpcFetch('/api/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const st = await res.json();
    render(st);
    return st;
  }

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function render(st) {
    if (!st || !st.ok) return;

    $('hostSubtitle').textContent = `${st.machineName} • :${st.port}`;
    $('clientsBadge').textContent = `${st.connectedClients.total} онлайн`;
    $('pinValue').textContent = st.pairing.formattedPin;

    if (st.pairing.pairingUrl !== lastQrUrl) {
      lastQrUrl = st.pairing.pairingUrl;
      $('qrBox').innerHTML = st.pairing.qrSvg;
      $('pairUrlInput').value = st.pairing.pairingUrl;
    }

    // LAN IP Select
    const ipSel = $('lanIpSelect');
    const ips = st.lanInterfaces?.length ? st.lanInterfaces : [{ interface: 'loopback', address: st.lanIp }];
    ipSel.innerHTML = ips
      .map(
        (item) =>
          `<option value="${esc(item.address)}" ${item.address === st.lanIp ? 'selected' : ''}>${esc(item.address)} (${esc(item.interface)})</option>`,
      )
      .join('');

    // Approval Mode
    document.querySelectorAll('.mode-btn').forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.mode === st.settings.approvalMode);
    });

    // Cloudflare Status
    const cf = st.cloudflare || {};
    const badge = $('cfStatusBadge');
    if (cf.status === 'connected') {
      badge.textContent = cf.mode === 'cloudflared' ? 'Tunnel Live' : 'CF Edge Live';
      badge.className = 'status-tag online';
    } else if (cf.status === 'connecting') {
      badge.textContent = 'Connecting…';
      badge.className = 'status-tag';
    } else {
      badge.textContent = 'LAN Only';
      badge.className = 'status-tag';
    }

    if (!cfDirty) {
      $('cfModeSelect').value = st.settings.cloudflareMode || 'disabled';
      $('cfUrlInput').value = st.settings.cloudflareEdgeUrl || '';
      $('cfSecretInput').value = st.settings.cloudflareEdgeSecret || '';
      toggleCfInputs();
    }

    const errBox = $('cfErrorText');
    if (cf.lastError) {
      errBox.textContent = cf.lastError;
      errBox.classList.remove('hidden');
    } else {
      errBox.classList.add('hidden');
    }

    // Pending Approvals
    const pending = st.pendingApprovals || [];
    if (pending.length > 0) {
      $('pendingBox').classList.remove('hidden');
      $('pendingCount').textContent = String(pending.length);
      const allowAllBtn = $('allowAllBtn');
      if (allowAllBtn) {
        allowAllBtn.classList.toggle('hidden', pending.length <= 1);
        allowAllBtn.textContent = `Разрешить всё (${pending.length})`;
      }
      $('pendingList').innerHTML = pending
        .map(
          (a) => `
        <div class="device-row">
          <div>
            <div class="device-name">${esc(a.toolName)}</div>
            <div class="device-meta">${esc(a.summary)}</div>
          </div>
          <div style="display:flex;gap:5px">
            <button class="btn-danger-xs" data-apr="${esc(a.id)}" data-dec="deny">Deny</button>
            <button class="btn-primary" style="padding:4px 8px;font-size:11px" data-apr="${esc(a.id)}" data-dec="allow">Allow</button>
          </div>
        </div>`,
        )
        .join('');

      $('pendingList').querySelectorAll('button[data-apr]').forEach((b) => {
        b.addEventListener('click', () =>
          apiAction({ action: 'decideApproval', id: b.dataset.apr, decision: b.dataset.dec }),
        );
      });
    } else {
      $('pendingBox').classList.add('hidden');
    }

    // Pending File Changes ("Сохранить всё")
    const changes = st.pendingChanges || [];
    const changesBox = $('changesBox');
    if (changesBox) {
      if (changes.length > 0) {
        changesBox.classList.remove('hidden');
        $('changesCount').textContent = String(changes.length);
        $('changesList').innerHTML = changes
          .map(
            (f) => `
          <div class="device-row">
            <div style="min-width:0;flex:1">
              <div class="device-name" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(f.path)}</div>
              <div class="device-meta">${esc(f.status)} • <span style="color:#10B981">+${Number(f.additions || 0)}</span> <span style="color:#F87171">-${Number(f.deletions || 0)}</span></div>
            </div>
            <div style="display:flex;gap:4px">
              <button class="btn-danger-xs" data-rev-file="${esc(f.path)}">Откатить</button>
              <button class="btn-ghost xs" data-save-file="${esc(f.path)}">ОК</button>
            </div>
          </div>`,
          )
          .join('');

        $('changesList').querySelectorAll('button[data-rev-file]').forEach((b) => {
          b.addEventListener('click', () =>
            apiAction({ action: 'revertChanges', paths: [b.dataset.revFile] }),
          );
        });
        $('changesList').querySelectorAll('button[data-save-file]').forEach((b) => {
          b.addEventListener('click', () =>
            apiAction({ action: 'saveChanges', paths: [b.dataset.saveFile] }),
          );
        });
      } else {
        changesBox.classList.add('hidden');
      }
    }

    // Paired Devices
    const devices = st.pairedDevices || [];
    $('pairedCount').textContent = String(devices.length);
    const liveIds = new Set((st.connectedClients.lanDevices || []).map((d) => d.id));
    $('devicesList').innerHTML = devices.length
      ? devices
          .map(
            (d) => `
        <div class="device-row">
          <div>
            <div class="device-name">${esc(d.name)} ${liveIds.has(d.id) ? '• <span style="color:#10B981">LAN Live</span>' : ''}</div>
            <div class="device-meta">${esc(d.platform)}</div>
          </div>
          <button class="btn-danger-xs" data-revoke="${esc(d.id)}">Отвязать</button>
        </div>`,
          )
          .join('')
      : `<div class="muted-small">Нет привязанных телефонов. Отсканируйте QR-код выше.</div>`;

    $('devicesList').querySelectorAll('button[data-revoke]').forEach((btn) => {
      btn.addEventListener('click', () => apiAction({ action: 'revokeDevice', deviceId: btn.dataset.revoke }));
    });
  }

  function toggleCfInputs() {
    const mode = $('cfModeSelect').value;
    $('cfWorkerFields').classList.toggle('hidden', mode !== 'edge-worker');
  }

  $('rotatePinBtn').addEventListener('click', () => apiAction({ action: 'rotatePin' }));
  $('allowAllBtn')?.addEventListener('click', () =>
    apiAction({ action: 'decideApproval', all: true, decision: 'allow' }),
  );
  $('saveAllChangesBtn')?.addEventListener('click', () => apiAction({ action: 'saveChanges' }));
  $('revertAllChangesBtn')?.addEventListener('click', () =>
    apiAction({ action: 'revertChanges', all: true }),
  );

  $('lanIpSelect').addEventListener('change', (e) => {
    apiAction({ action: 'updateSettings', settings: { preferredLanIp: e.target.value } });
  });

  $('copyUrlBtn').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText($('pairUrlInput').value);
      $('copyUrlBtn').textContent = 'ОК!';
      setTimeout(() => ($('copyUrlBtn').textContent = 'Копия'), 1400);
    } catch {}
  });

  document.querySelectorAll('.mode-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      apiAction({ action: 'updateSettings', settings: { approvalMode: btn.dataset.mode } });
    });
  });

  $('cfModeSelect').addEventListener('change', () => {
    cfDirty = true;
    toggleCfInputs();
  });
  $('cfUrlInput').addEventListener('input', () => (cfDirty = true));
  $('cfSecretInput').addEventListener('input', () => (cfDirty = true));

  $('saveCfBtn').addEventListener('click', async () => {
    cfDirty = false;
    await apiAction({
      action: 'updateSettings',
      settings: {
        cloudflareMode: $('cfModeSelect').value,
        cloudflareEdgeUrl: $('cfUrlInput').value.trim(),
        cloudflareEdgeSecret: $('cfSecretInput').value,
      },
    });
  });

  async function poll() {
    try {
      const st = await apiGet('/api/status');
      render(st);
    } catch {}
  }

  poll();
  setInterval(poll, 2200);
})();

