(() => {
  const STORAGE_KEY = 'agy_remote_session_v1';
  const $ = (id) => document.getElementById(id);

  const state = {
    auth: loadSavedAuth(),
    ws: null,
    sessions: [],
    activeConvId: null,
    steps: [],
    pendingApprovals: [],
    pendingChanges: [],
    changesExpanded: false,
    approvalMode: 'ask-mobile',
    latencyMs: null,
    pingSentAt: 0,
    lastInboundAt: 0,
    lastVibrateAt: 0,
    outboundQueue: [],
  };

  function loadSavedAuth() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
    } catch {
      return null;
    }
  }

  function saveAuth(data) {
    state.auth = data;
    localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
  }

  function toast(msg) {
    const el = document.createElement('div');
    el.className = 'toast';
    el.textContent = msg;
    $('toastBox').appendChild(el);
    setTimeout(() => el.remove(), 2600);
  }

  function esc(str) {
    return String(str ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  // Handle QR auto-pair token in query string (?pairToken=...)
  async function boot() {
    const params = new URLSearchParams(location.search);
    const qrToken = params.get('t') || params.get('pairToken');
    const sessionId = params.get('s') || '';

    if (qrToken) {
      history.replaceState({}, '', '/app' + (sessionId ? `?s=${encodeURIComponent(sessionId)}` : ''));
      const ok = await performPair({ token: qrToken, sessionId });
      if (ok) {
        showCockpit();
        connectWs();
        return;
      }
    }

    if (state.auth?.deviceToken) {
      showCockpit();
      connectWs();
    } else {
      showPairView();
    }
  }

  function showPairView() {
    $('pairView').classList.remove('hidden');
    $('cockpitView').classList.add('hidden');
  }

  function showCockpit() {
    $('pairView').classList.add('hidden');
    $('cockpitView').classList.remove('hidden');
    if (state.auth?.machineName) {
      $('hostTitle').textContent = state.auth.machineName;
    }
  }

  async function performPair({ token = '', pin = '', sessionId = '' }) {
    const deviceName = $('deviceNameInput')?.value.trim() || navigator.platform || 'Mobile Browser';
    try {
      const res = await fetch('/api/pair', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token, pin, sessionId, deviceName, platform: 'pwa' }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        showError(data.error || 'Неверный код привязки');
        return false;
      }
      saveAuth({
        deviceToken: data.deviceToken,
        deviceId: data.deviceId,
        machineId: data.machineId,
        machineName: data.machineName,
        sessionId: data.sessionId || sessionId,
      });
      return true;
    } catch (err) {
      showError(err.message);
      return false;
    }
  }

  function showError(msg) {
    const box = $('pairError');
    box.textContent = msg;
    box.classList.remove('hidden');
  }

  $('pairForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    $('pairError').classList.add('hidden');
    const pin = $('pinInput').value.trim();
    if (await performPair({ pin })) {
      showCockpit();
      connectWs();
    }
  });

  // Tabs
  document.querySelectorAll('.tab').forEach((btn) => {
    btn.addEventListener('click', () => {
      const target = btn.dataset.tab;
      document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('active', b === btn));
      document.querySelectorAll('.tab-panel').forEach((p) => p.classList.toggle('active', p.id === `tab-${target}`));
      if (target === 'workspace') sendRpc('workspace.status', {});
    });
  });

  function switchTab(name) {
    const btn = document.querySelector(`.tab[data-tab="${name}"]`);
    if (btn) btn.click();
  }

  // WebSocket Connection
  function connectWs() {
    if (!state.auth?.deviceToken) return;
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const sessionParam = state.auth.sessionId ? `&sessionId=${encodeURIComponent(state.auth.sessionId)}` : '';
    const wsUrl = `${proto}//${location.host}/ws?token=${encodeURIComponent(state.auth.deviceToken)}${sessionParam}`;

    setConnIndicator('warn', 'Подключение…');
    const ws = new WebSocket(wsUrl);
    state.ws = ws;

    ws.addEventListener('open', () => {
      state.lastInboundAt = Date.now();
      setConnIndicator('live', location.hostname.endsWith('.workers.dev') ? 'CF EDGE • Online' : 'LAN • Online');
      sendRpc('sessions.list', {});
      sendRpc('workspace.status', {});
      if (state.activeConvId) {
        sendRpc('session.detail', { conversationId: state.activeConvId });
      }
      state.pingSentAt = Date.now();
      sendRpc('client.ping', {});
      while (state.outboundQueue.length > 0 && ws.readyState === WebSocket.OPEN) {
        const item = state.outboundQueue.shift();
        sendRpc(item.type, item.payload);
      }
    });

    ws.addEventListener('message', (ev) => {
      state.lastInboundAt = Date.now();
      let env;
      try {
        env = JSON.parse(ev.data);
      } catch {
        return;
      }
      handleEnvelope(env);
    });

    ws.addEventListener('close', (ev) => {
      if (ev.code === 4001) {
        localStorage.removeItem(STORAGE_KEY);
        state.auth = null;
        showPairView();
        return;
      }
      setConnIndicator('off', 'Переподключение…');
      setTimeout(connectWs, 2500);
    });
  }

  function setConnIndicator(kind, text) {
    const dot = $('connDot');
    dot.className = 'dot ' + (kind === 'live' ? 'dot-live' : kind === 'warn' ? 'dot-warn' : 'dot-off');
    $('connMeta').textContent = text;
  }

  function sendRpc(type, payload = {}) {
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
      if (type === 'chat.send' || type === 'chat.new') {
        state.outboundQueue.push({ type, payload });
        if (!state.ws || state.ws.readyState === WebSocket.CLOSED) {
          connectWs();
        }
      }
      return;
    }
    state.ws.send(
      JSON.stringify({
        v: 'arp.v1',
        type,
        reqId: `req_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
        ts: Date.now(),
        payload,
      }),
    );
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.auth?.deviceToken) {
      if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
        connectWs();
      } else {
        state.pingSentAt = Date.now();
        sendRpc('client.ping', {});
      }
    }
  });

  function handleEnvelope(env) {
    const p = env.payload || {};
    switch (env.type) {
      case 'server.hello':
      case 'host.snapshot': {
        if (p.machineName) $('hostTitle').textContent = p.machineName;
        if (p.approvalMode) updateModeLabel(p.approvalMode);
        if (Array.isArray(p.sessions)) {
          state.sessions = p.sessions;
          renderSessions();
        }
        if (Array.isArray(p.pendingApprovals)) {
          state.pendingApprovals = p.pendingApprovals;
          renderApprovalSheet();
        }
        if (Array.isArray(p.pendingChanges)) {
          state.pendingChanges = p.pendingChanges;
          renderPendingChanges();
        }
        break;
      }
      case 'server.pong': {
        if (state.pingSentAt) {
          state.latencyMs = Date.now() - state.pingSentAt;
          const modeTag = location.hostname.includes('workers.dev') || location.hostname.includes('trycloudflare') ? 'CF' : 'LAN';
          setConnIndicator('live', `${modeTag} • ${state.latencyMs}ms`);
        }
        break;
      }
      case 'sessions.list.result':
      case 'sessions.updated': {
        state.sessions = p.sessions || [];
        renderSessions();
        break;
      }
      case 'session.detail.result': {
        if (p.detail) {
          state.activeConvId = p.detail.summary.id;
          state.steps = p.detail.steps || [];
          $('chatHeader').textContent = `${p.detail.summary.title} (${p.detail.summary.status})`;
          renderSteps(true);
        }
        break;
      }
      case 'session.steps_delta': {
        if (p.conversationId === state.activeConvId && Array.isArray(p.steps)) {
          const stepKey = (s) => Number.isFinite(s.seq) ? s.seq : s.stepIndex;
          const byKey = new Map(
            state.steps.filter((s) => s.stepIndex !== 999999).map((s) => [stepKey(s), s]),
          );
          for (const st of p.steps) byKey.set(stepKey(st), st);
          state.steps = [...byKey.values()].sort((a, b) => stepKey(a) - stepKey(b));
          $('chatHeader').textContent = `${p.summary?.title || state.activeConvId} (${p.summary?.status || 'live'})`;
          renderSteps(true);
        }
        break;
      }
      case 'chat.send.result': {
        toast(p.delivery === 'queued' ? 'Поставлено в очередь агента' : 'Отправлено в Antigravity');
        if (p.conversationId && !state.activeConvId) {
          openSession(p.conversationId);
        }
        break;
      }
      case 'chat.stop.result': {
        toast('Сессия остановлена');
        break;
      }
      case 'session.stopped': {
        const stoppedId = p.conversationId || '*';
        state.sessions = state.sessions.map((s) =>
          stoppedId === '*' || s.id === stoppedId ? { ...s, status: 'idle', lastActivity: 'Stopped' } : s,
        );
        renderSessions();
        if (stoppedId === '*' || stoppedId === state.activeConvId) {
          const cur = state.sessions.find((s) => s.id === state.activeConvId);
          if (cur) {
            $('chatHeader').textContent = `${cur.title} (idle)`;
          }
        }
        break;
      }
      case 'approval.requested': {
        state.pendingApprovals = state.pendingApprovals.filter((a) => a.id !== p.id);
        state.pendingApprovals.push(p);
        const now = Date.now();
        if (navigator.vibrate && now - state.lastVibrateAt > 1500) {
          state.lastVibrateAt = now;
          navigator.vibrate(80);
        }
        renderApprovalSheet();
        break;
      }
      case 'approval.resolved': {
        state.pendingApprovals = state.pendingApprovals.filter((a) => a.id !== p.id);
        renderApprovalSheet();
        break;
      }
      case 'changes.updated':
      case 'changes.list.result':
      case 'changes.save_all.result':
      case 'changes.revert.result': {
        if (Array.isArray(p.files)) {
          state.pendingChanges = p.files;
          renderPendingChanges();
        }
        break;
      }
      case 'changes.diff.result': {
        renderPendingChangeDiff(p);
        break;
      }
      case 'settings.updated': {
        if (p.approvalMode) updateModeLabel(p.approvalMode);
        break;
      }
      case 'workspace.status.result': {
        renderWorkspace(p);
        break;
      }
      case 'workspace.diff.result': {
        renderDiff(p);
        break;
      }
      case 'terminal.exec.result': {
        const prefix = `$ ${p.command || ''}\n`;
        $('termOutput').textContent = `${prefix}${p.output || '(пусто)'}\n[exit ${p.exitCode} • ${p.durationMs}ms]`;
        break;
      }
      case 'error': {
        toast(p.message || 'Ошибка запроса');
        break;
      }
    }
  }

  function updateModeLabel(mode) {
    state.approvalMode = mode;
    const labels = {
      'ask-mobile': 'Ask Phone',
      'auto-safe': 'Auto-Safe',
      observe: 'Observe',
    };
    $('approvalModeBtn').textContent = labels[mode] || mode;
  }

  $('approvalModeBtn').addEventListener('click', () => {
    const order = ['ask-mobile', 'auto-safe', 'observe'];
    const next = order[(order.indexOf(state.approvalMode) + 1) % order.length];
    sendRpc('settings.set', { approvalMode: next });
  });

  function renderSessions() {
    $('sessCount').textContent = String(state.sessions.length);
    const box = $('sessionsList');
    if (!state.sessions.length) {
      box.innerHTML = `<div class="muted">Активных сессий в ~/.gemini/*/brain пока не найдено. Нажмите «+ Новая задача».</div>`;
      return;
    }
    box.innerHTML = state.sessions
      .map(
        (s) => `
      <div class="session-card ${s.id === state.activeConvId ? 'selected' : ''}" data-conv="${esc(s.id)}">
        <div class="session-head">
          <span class="session-title">${esc(s.title)}</span>
          <span class="dot ${s.status === 'working' ? 'dot-live' : 'dot-warn'}"></span>
        </div>
        <div class="session-sub">
          <span>${esc(s.lastActivity)}</span>
          <span>${s.stepCount} шагов</span>
        </div>
      </div>`,
      )
      .join('');

    box.querySelectorAll('.session-card').forEach((card) => {
      card.addEventListener('click', () => openSession(card.dataset.conv));
    });
  }

  function openSession(convId) {
    state.activeConvId = convId;
    switchTab('chat');
    sendRpc('session.detail', { conversationId: convId });
  }

  function renderSteps(scrollBottom = false) {
    const stream = $('stepsStream');
    const visible = state.steps.filter((s) => s.role !== 'tool_result');
    if (!visible.length) {
      stream.innerHTML = `<div class="muted">История шагов пуста. Напишите промпт внизу!</div>`;
      return;
    }
    stream.innerHTML = visible
      .map((s) => {
        if (s.role === 'user') {
          return `<div class="step-user">${esc(s.content)}</div>`;
        }
        const thinkHtml = s.thinking
          ? `<details class="think-details"><summary>Размышление агента</summary><div class="think-body">${esc(s.thinking)}</div></details>`
          : '';
        const toolsHtml = (s.toolCalls || [])
          .map((tc) => `<div class="tool-pill">${esc(tc.summary)}</div>`)
          .join('');
        const bodyHtml = s.content ? `<div class="agent-reply">${esc(s.content)}</div>` : '';
        return `<div class="step-agent">${thinkHtml}${toolsHtml}${bodyHtml}</div>`;
      })
      .join('');

    if (scrollBottom) {
      stream.scrollTop = stream.scrollHeight;
    }
  }

  // Send Prompt / New Session
  $('newSessionBtn').addEventListener('click', () => {
    state.activeConvId = null;
    state.steps = [];
    $('chatHeader').textContent = 'Новая сессия Antigravity';
    renderSteps();
    switchTab('chat');
    $('promptInput').focus();
  });

  $('refreshSessionsBtn').addEventListener('click', () => sendRpc('sessions.list', {}));

  document.querySelectorAll('.slash-chip').forEach((chip) => {
    chip.addEventListener('click', () => {
      const inp = $('promptInput');
      inp.value = chip.dataset.slash;
      inp.focus();
    });
  });

  $('chatForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const prompt = $('promptInput').value.trim();
    if (!prompt) return;
    $('promptInput').value = '';
    if (state.activeConvId) {
      state.steps.push({ stepIndex: 999999, role: 'user', content: prompt });
      renderSteps(true);
      sendRpc('chat.send', { conversationId: state.activeConvId, prompt });
    } else {
      sendRpc('chat.new', { prompt });
    }
  });

  // Workspace Diffs
  $('refreshGitBtn').addEventListener('click', () => sendRpc('workspace.status', {}));

  function renderWorkspace(p) {
    $('gitBranchLabel').textContent = p.branch || 'workspace';
    const files = p.files || [];
    $('diffCount').textContent = String(files.length);
    const box = $('gitFilesList');
    if (!files.length) {
      box.innerHTML = `<div class="muted">Нет незакоммиченных изменений в рабочей директории (${esc(p.workspace || '')}).</div>`;
      $('diffViewer').classList.add('hidden');
      return;
    }
    box.innerHTML = files
      .map(
        (f) => `
      <div class="session-card" data-path="${esc(f.path)}">
        <div class="session-head">
          <span class="session-title">${esc(f.path)}</span>
          <span class="mono-tag">${esc(f.status)}</span>
        </div>
      </div>`,
      )
      .join('');

    box.querySelectorAll('.session-card').forEach((el) => {
      el.addEventListener('click', () => sendRpc('workspace.diff', { path: el.dataset.path }));
    });
  }

  function renderDiff(p) {
    const viewer = $('diffViewer');
    viewer.classList.remove('hidden');
    const lines = String(p.diff || '').split('\n');
    viewer.innerHTML = lines
      .map((l) => {
        if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('@@')) {
          return `<span class="diff-hunk">${esc(l)}</span>`;
        }
        if (l.startsWith('+')) return `<span class="diff-add">${esc(l)}</span>`;
        if (l.startsWith('-')) return `<span class="diff-del">${esc(l)}</span>`;
        return `<span>${esc(l)}\n</span>`;
      })
      .join('');
  }

  // Quick Terminal
  document.querySelectorAll('.cmd-chip').forEach((chip) => {
    chip.addEventListener('click', () => {
      $('cmdInput').value = chip.dataset.cmd;
      sendRpc('terminal.exec', { command: chip.dataset.cmd });
    });
  });

  $('termForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const cmd = $('cmdInput').value.trim();
    if (!cmd) return;
    $('termOutput').textContent = `$ ${cmd}\nВыполнение…`;
    sendRpc('terminal.exec', { command: cmd });
  });

  // Sticky bottom Pending File Changes bar intentionally hidden so it never clutters Chat;
  // laptop automatically accepts & saves all file changes when each task completes.
  function renderPendingChanges() {
    const bar = $('pendingChangesBar');
    if (bar) bar.classList.add('hidden');
    state.changesExpanded = false;
    $('pendingChangesDrawer')?.classList.add('hidden');
    $('pendingChangesDiff')?.classList.add('hidden');
  }

  function renderPendingChangeDiff(p) {
    const viewer = $('pendingChangesDiff');
    if (!viewer) return;
    viewer.classList.remove('hidden');
    const lines = String(p.diff || '').split('\n');
    viewer.innerHTML = lines
      .map((l) => {
        if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('@@')) {
          return `<span class="diff-hunk">${esc(l)}</span>`;
        }
        if (l.startsWith('+')) return `<span class="diff-add">${esc(l)}</span>`;
        if (l.startsWith('-')) return `<span class="diff-del">${esc(l)}</span>`;
        return `<span>${esc(l)}\n</span>`;
      })
      .join('');
  }

  $('toggleChangesListBtn')?.addEventListener('click', () => {
    state.changesExpanded = !state.changesExpanded;
    renderPendingChanges();
  });

  $('saveAllPwaBtn')?.addEventListener('click', () => {
    sendRpc('changes.save_all', {});
    state.pendingChanges = [];
    renderPendingChanges();
    toast('Все изменения сохранены');
  });

  $('revertAllPwaBtn')?.addEventListener('click', () => {
    sendRpc('changes.revert', { all: true });
    state.pendingChanges = [];
    renderPendingChanges();
    toast('Изменения откачены');
  });

  // Urgent PreToolUse Approval Sheet (supports single item & batch queue with "Сохранить всё / Разрешить всё")
  function renderApprovalSheet() {
    const sheet = $('approvalSheet');
    const queue = state.pendingApprovals;
    const item = queue[0];
    if (!item) {
      sheet.classList.add('hidden');
      return;
    }
    sheet.classList.remove('hidden');
    const isBatch = queue.length > 1;
    const allFiles = queue.every((q) => q.toolName === 'write_file' || q.toolName === 'edit_file');

    const pill = $('approvalTitlePill');
    if (pill) {
      pill.textContent = isBatch
        ? `Ожидают подтверждения (${queue.length})`
        : 'Запрос разрешения тула';
    }
    $('approvalToolName').textContent = isBatch
      ? allFiles
        ? `Запись файлов (${queue.length})`
        : `Очередь запросов (${queue.length})`
      : item.toolName;

    const summaryEl = $('approvalSummary');
    const queueBox = $('approvalQueueList');
    if (isBatch && queueBox) {
      summaryEl.classList.add('hidden');
      queueBox.classList.remove('hidden');
      queueBox.innerHTML = queue
        .map(
          (q) => `
        <div class="approval-queue-item">
          <div style="min-width:0;flex:1">
            <strong style="font-family:var(--font-mono)">${esc(q.toolName)}</strong>
            <div class="muted" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(q.args?.CommandLine || q.args?.Path || q.summary || '')}</div>
          </div>
          <button type="button" class="btn-ghost sm" data-apr-one="${esc(q.id)}">ОК</button>
        </div>`,
        )
        .join('');
      queueBox.querySelectorAll('button[data-apr-one]').forEach((b) => {
        b.addEventListener('click', () => {
          sendRpc('approval.decide', { id: b.dataset.aprOne, decision: 'allow' });
          state.pendingApprovals = state.pendingApprovals.filter((x) => x.id !== b.dataset.aprOne);
          renderApprovalSheet();
        });
      });
    } else {
      summaryEl.classList.remove('hidden');
      queueBox?.classList.add('hidden');
      summaryEl.textContent =
        item.args?.CommandLine || item.summary || JSON.stringify(item.args, null, 2);
    }

    $('approvalCwd').textContent = item.cwd || '';
    const leftSec = Math.max(0, Math.round(((item.expiresAt || Date.now()) - Date.now()) / 1000));
    $('approvalTimer').textContent = `${leftSec}s`;
    $('btnAllowOnce').textContent = isBatch
      ? allFiles
        ? `Сохранить всё (${queue.length})`
        : `Разрешить всё (${queue.length})`
      : 'Разрешить';
    $('btnDenyTool').textContent = isBatch ? 'Отклонить всё' : 'Заблокировать';
  }

  setInterval(() => {
    if (state.pendingApprovals.length) renderApprovalSheet();
  }, 1000);

  function decideCurrent(decision) {
    if (!state.pendingApprovals.length) return;
    if (state.pendingApprovals.length > 1) {
      const ids = state.pendingApprovals.map((a) => a.id);
      sendRpc('approval.decide_batch', { ids, decision });
      state.pendingApprovals = [];
      renderApprovalSheet();
      return;
    }
    const item = state.pendingApprovals[0];
    sendRpc('approval.decide', { id: item.id, decision });
    state.pendingApprovals.shift();
    renderApprovalSheet();
  }

  $('btnAllowOnce').addEventListener('click', () => decideCurrent('allow'));
  $('btnAllowSession').addEventListener('click', () => decideCurrent('allow_session'));
  $('btnDenyTool').addEventListener('click', () => decideCurrent('deny'));

  boot();
})();

