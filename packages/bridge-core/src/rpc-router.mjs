/**
 * Isolated ARP v1 Client RPC Router (`dispatchClientRpc`).
 * Decouples mobile WebSocket / Cloudflare Edge command handling from HTTP transport.
 */
import { APPROVAL_MODES, createEnvelope } from '@agy-remote/protocol';
import { isUserWorkspacePath } from './host-registry.mjs';

/**
 * @param {{ type: string, reqId?: string, payload?: Record<string, any> }} env
 * @param {{ deviceName: string, reply: (envelope: any) => void }} ctx
 * @param {{
 *   brain: import('./brain-watcher.mjs').BrainWatcher,
 *   driver: import('./agent-driver.mjs').AgentDriver,
 *   approvals: import('./approval-gate.mjs').ApprovalGate,
 *   changes?: import('./change-tracker.mjs').ChangeTracker,
 *   auth: import('./auth-manager.mjs').AuthManager,
 *   broadcast: (envelope: any) => void,
 *   onStatusChanged: () => void
 * }} services
 */
export async function dispatchClientRpc(env, ctx, services) {
  const p = env?.payload || {};
  const reqId = env?.reqId;
  const { brain, driver, approvals, changes, auth, broadcast, onStatusChanged } = services;

  try {
    switch (env?.type) {
      case 'client.ping': {
        ctx.reply(createEnvelope('server.pong', { serverTs: Date.now() }, reqId));
        break;
      }
      case 'sessions.list': {
        ctx.reply(
          createEnvelope('sessions.list.result', { sessions: brain.listSessions(50) }, reqId),
        );
        break;
      }
      case 'session.detail': {
        const detail = brain.getSessionDetail(p.conversationId, p.maxSteps || 300);
        ctx.reply(createEnvelope('session.detail.result', { detail }, reqId));
        break;
      }
      case 'session.artifact': {
        const artifact = brain.getArtifactContent(p.conversationId, p.fileName);
        ctx.reply(createEnvelope('session.artifact.result', { artifact }, reqId));
        break;
      }
      case 'chat.send': {
        approvals?.clearStop?.(p.conversationId);
        brain?.clearSessionStopped?.(p.conversationId);
        const sessionWs = brain?.getSessionWorkspaceHint?.(p.conversationId) || '';
        const clientWs = typeof p.workspace === 'string' ? p.workspace.trim() : '';
        const workspaceHint =
          (isUserWorkspacePath(sessionWs) ? sessionWs : '') ||
          (isUserWorkspacePath(clientWs) ? clientWs : '');
        const res = await driver.sendMessage(p.conversationId, p.prompt, { workspaceHint });
        ctx.reply(
          createEnvelope('chat.send.result', { conversationId: p.conversationId, ...res }, reqId),
        );
        if (brain?.scanNow) {
          const fastScan = setTimeout(() => brain.scanNow(true), 350);
          const followScan = setTimeout(() => brain.scanNow(true), 1400);
          fastScan.unref?.();
          followScan.unref?.();
        }
        break;
      }
      case 'chat.new': {
        approvals?.clearStop?.('');
        brain?.clearSessionStopped?.('');
        const res = await driver.createConversation(p.prompt, { workspaceHint: p.workspace });
        ctx.reply(createEnvelope('chat.send.result', res, reqId));
        if (p.workspace) {
          const sessions = brain ? brain.listSessions(60) : [];
          broadcast(
            createEnvelope('workspace.selected', {
              activeWorkspace: driver.defaultWorkspace,
              workspaces: driver.listWorkspaces(sessions),
            }),
          );
        }
        const scanTimer = setTimeout(() => brain.scanNow(true), 1200);
        scanTimer.unref?.();
        break;
      }
      case 'chat.stop': {
        const convId = typeof p.conversationId === 'string' ? p.conversationId.trim() : '';
        const gateRes = approvals
          ? approvals.requestStop(convId, ctx.deviceName)
          : { ok: true, conversationId: convId || '*', abortedApprovals: 0 };
        const drvRes = driver ? driver.stopConversation(convId) : { ok: true, clearedQueued: 0, killedCommands: 0 };
        brain?.markSessionStopped?.(convId);
        services.onStopRequested?.(convId);
        const payload = { ...gateRes, ...drvRes, conversationId: convId || '*' };
        ctx.reply(createEnvelope('chat.stop.result', payload, reqId));
        broadcast(createEnvelope('session.stopped', { conversationId: convId || '*', byDevice: ctx.deviceName }));
        if (brain?.listSessions) {
          broadcast(createEnvelope('sessions.updated', { sessions: brain.listSessions(50) }));
        }
        break;
      }
      case 'workspaces.list': {
        const sessions = brain ? brain.listSessions(60) : [];
        ctx.reply(
          createEnvelope(
            'workspaces.list.result',
            {
              workspaces: driver.listWorkspaces(sessions),
              activeWorkspace: driver.defaultWorkspace,
            },
            reqId,
          ),
        );
        break;
      }
      case 'workspace.select': {
        if (p.path) {
          driver.setDefaultWorkspace(String(p.path));
        }
        const sessions = brain ? brain.listSessions(60) : [];
        const wsPayload = {
          workspaces: driver.listWorkspaces(sessions),
          activeWorkspace: driver.defaultWorkspace,
        };
        ctx.reply(createEnvelope('workspaces.list.result', wsPayload, reqId));
        broadcast(createEnvelope('workspace.selected', wsPayload));
        onStatusChanged?.();
        break;
      }
      case 'workspace.upload_file': {
        const uploaded = driver.saveUploadedFile({
          fileName: p.fileName,
          base64Data: p.base64Data,
          workspacePath: p.workspace,
        });
        ctx.reply(createEnvelope('workspace.upload_file.result', uploaded, reqId));
        break;
      }
      case 'approval.decide': {
        const res = approvals.decide({
          id: p.id,
          decision: p.decision,
          reason: p.reason,
          byDevice: ctx.deviceName,
        });
        ctx.reply(createEnvelope('approval.decide.result', res, reqId));
        break;
      }
      case 'approval.decide_batch': {
        const res = approvals.decideBatch({
          ids: p.ids,
          decision: p.decision,
          reason: p.reason,
          byDevice: ctx.deviceName,
        });
        ctx.reply(createEnvelope('approval.decide_batch.result', res, reqId));
        break;
      }
      case 'changes.list': {
        const files = changes ? changes.listPending() : [];
        ctx.reply(createEnvelope('changes.list.result', { files }, reqId));
        break;
      }
      case 'changes.diff': {
        const res = changes
          ? changes.getPendingDiff(p.path)
          : { ok: false, path: String(p.path || ''), diff: '' };
        ctx.reply(createEnvelope('changes.diff.result', res, reqId));
        break;
      }
      case 'changes.save_all': {
        const res = changes
          ? changes.saveChanges({ paths: p.paths })
          : { ok: true, savedCount: 0, files: [] };
        ctx.reply(createEnvelope('changes.save_all.result', res, reqId));
        break;
      }
      case 'changes.revert': {
        const res = changes
          ? changes.revertChanges({ paths: p.paths, all: Boolean(p.all) })
          : { ok: true, revertedCount: 0, files: [] };
        ctx.reply(createEnvelope('changes.revert.result', res, reqId));
        break;
      }
      case 'settings.set': {
        if (p.approvalMode && APPROVAL_MODES.includes(p.approvalMode)) {
          const next = auth.updateSettings({ approvalMode: p.approvalMode });
          broadcast(createEnvelope('settings.updated', next));
          onStatusChanged();
        }
        break;
      }
      case 'workspace.status': {
        const res = await driver.getWorkspaceStatus(p.workspace);
        ctx.reply(createEnvelope('workspace.status.result', res, reqId));
        break;
      }
      case 'workspace.diff': {
        const res = await driver.getFileDiff(p.path, p.workspace);
        ctx.reply(createEnvelope('workspace.diff.result', res, reqId));
        break;
      }
      case 'terminal.exec': {
        const res = await driver.runQuickCommand(p.command, p.workspace);
        ctx.reply(
          createEnvelope('terminal.exec.result', { command: p.command, ...res }, reqId),
        );
        break;
      }
      default: {
        if (reqId) {
          ctx.reply(
            createEnvelope('error', { message: `Unsupported RPC type: ${env?.type}` }, reqId),
          );
        }
        break;
      }
    }
  } catch (err) {
    ctx.reply(createEnvelope('error', { message: err?.message || String(err) }, reqId));
  }
}

