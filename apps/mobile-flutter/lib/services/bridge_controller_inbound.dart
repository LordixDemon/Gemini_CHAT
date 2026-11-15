part of 'bridge_controller.dart';

extension _BridgeControllerInbound on BridgeController {
  void _resolveArtifactWaiter(String? fileName, String? content) {
    if (fileName != null && _artifactWaiters.containsKey(fileName)) {
      final bucket = _artifactWaiters[fileName]!;
      if (bucket.isNotEmpty) {
        final waiter = bucket.removeAt(0);
        if (bucket.isEmpty) _artifactWaiters.remove(fileName);
        if (!waiter.isCompleted) waiter.complete(content);
        return;
      }
    }
    if (_artifactWaiters.isNotEmpty) {
      final firstKey = _artifactWaiters.keys.first;
      final bucket = _artifactWaiters[firstKey]!;
      if (bucket.isNotEmpty) {
        final waiter = bucket.removeAt(0);
        if (bucket.isEmpty) _artifactWaiters.remove(firstKey);
        if (!waiter.isCompleted) waiter.complete(content);
      }
    }
  }

  void _updateOptimisticStepStatus(int? optimisticSeq, String nextStatus) {
    var updated = false;
    activeSteps = activeSteps.map((s) {
      if (s.isOptimistic && !updated && (optimisticSeq == null || s.seq == optimisticSeq)) {
        updated = true;
        return s.copyWith(status: nextStatus);
      }
      return s;
    }).toList();
  }

  PendingOutboundPrompt? _consumeMatchingPendingPrompt(String? reqId, String? convId) {
    if (_pendingPrompts.isEmpty) return null;
    var idx = -1;
    if (reqId != null && reqId.isNotEmpty) {
      idx = _pendingPrompts.indexWhere((x) => x.reqId == reqId);
    }
    if (idx == -1 && convId != null && convId.isNotEmpty) {
      idx = _pendingPrompts.indexWhere((x) => x.conversationId == convId);
    }
    if (idx == -1) {
      idx = 0;
    }
    final item = _pendingPrompts.removeAt(idx);
    item.ackTimer?.cancel();
    item.ackTimer = null;
    return item;
  }

  void _applyWorkspacesPayload(Map<String, dynamic> p) {
    if (p['activeWorkspace'] != null) {
      activeWorkspace = p['activeWorkspace'].toString();
      if (workspacePath.isEmpty) {
        workspacePath = activeWorkspace;
      }
    }
    if (p['workspaces'] is List) {
      workspaces = (p['workspaces'] as List)
          .whereType<Map>()
          .map((e) => WorkspaceInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
  }

  void _handleSocketMessage(dynamic raw) {
    if (raw is! String) return;
    _lastInboundMs = DateTime.now().millisecondsSinceEpoch;
    _pongWatchdogTimer?.cancel();
    _pongWatchdogTimer = null;

    Map<String, dynamic> env;
    try {
      env = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final reqId = env['reqId']?.toString();
    final type = (env['type'] ?? '').toString();
    final p = env['payload'] is Map
        ? Map<String, dynamic>.from(env['payload'] as Map)
        : <String, dynamic>{};

    switch (type) {
      case 'server.hello':
      case 'host.snapshot':
        if (p['approvalMode'] != null) approvalMode = p['approvalMode'].toString();
        if (p['sessions'] is List) {
          sessions = (p['sessions'] as List)
              .whereType<Map>()
              .map((e) => _applyStoppedMask(SessionSummary.fromJson(Map<String, dynamic>.from(e))))
              .toList();
        }
        _applyWorkspacesPayload(p);
        if (p['pendingApprovals'] is List) {
          pendingApprovals = (p['pendingApprovals'] as List)
              .whereType<Map>()
              .map((e) => ApprovalRequest.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
        if (p['pendingChanges'] is List) {
          pendingChanges = (p['pendingChanges'] as List)
              .whereType<Map>()
              .map((e) => PendingFileChange.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
        unawaited(_persistMachineSnapshot());
        _emitChange();
        break;

      case 'server.pong':
        if (_lastPingSentMs > 0) {
          latencyMs = DateTime.now().millisecondsSinceEpoch - _lastPingSentMs;
          _emitChange();
        }
        break;

      case 'sessions.list.result':
      case 'sessions.updated':
        if (p['sessions'] is List) {
          sessions = (p['sessions'] as List)
              .whereType<Map>()
              .map((e) => _applyStoppedMask(SessionSummary.fromJson(Map<String, dynamic>.from(e))))
              .toList();
          unawaited(_persistMachineSnapshot());
          _emitChange();
        }
        break;

      case 'workspaces.list.result':
      case 'workspace.selected':
        _applyWorkspacesPayload(p);
        unawaited(_persistMachineSnapshot());
        _emitChange();
        break;

      case 'workspace.upload_file.result':
        if (reqId != null && _uploadWaiters.containsKey(reqId)) {
          final waiter = _uploadWaiters.remove(reqId)!;
          if (!waiter.isCompleted) waiter.complete(p);
        }
        break;

      case 'chat.stop.result':
      case 'session.stopped':
        _stopResetTimer?.cancel();
        stoppingSession = false;
        final stoppedId = (p['conversationId'] ?? '').toString();
        _markSessionStoppedLocally(stoppedId);
        if (stoppedId.isNotEmpty && stoppedId != '*') {
          pendingApprovals.removeWhere((a) => a.conversationId == stoppedId);
        } else {
          pendingApprovals = [];
        }
        unawaited(_persistMachineSnapshot());
        _emitChange();
        break;

      case 'session.detail.result':
        final detail = p['detail'];
        if (detail is Map) {
          final prevConvId = activeConversationId;
          final map = Map<String, dynamic>.from(detail);
          final summary = map['summary'] is Map
              ? SessionSummary.fromJson(Map<String, dynamic>.from(map['summary'] as Map))
              : null;
          if (summary != null) {
            activeConversationId = summary.id;
            _upsertSessionSummary(summary);
          }
          final loadedSteps = (map['steps'] as List? ?? const [])
              .whereType<Map>()
              .map((e) => AgentStep.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (prevConvId != null && prevConvId == activeConversationId) {
            final pendingOptimistic = activeSteps.where((s) => s.isOptimistic).toList();
            final arrivedUserContents = <String>{
              for (final s in loadedSteps)
                if (s.role == 'user') s.content.trim(),
            };
            for (final opt in pendingOptimistic) {
              if (!arrivedUserContents.contains(opt.content.trim())) {
                loadedSteps.add(opt);
              }
            }
          }
          activeSteps = loadedSteps;
          activeArtifacts = (map['artifacts'] as List? ?? const [])
              .whereType<Map>()
              .map((e) => ArtifactInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (activeConversationId != null) {
            unawaited(
              _cache.saveSessionDetail(
                conversationId: activeConversationId!,
                steps: activeSteps,
                artifacts: activeArtifacts,
              ),
            );
          }
          _emitChange();
        }
        break;

      case 'session.steps_delta':
        final deltaConvId = p['conversationId']?.toString();
        if (p['summary'] is Map) {
          _upsertSessionSummary(
            SessionSummary.fromJson(Map<String, dynamic>.from(p['summary'] as Map)),
          );
        }
        if (deltaConvId == activeConversationId) {
          if (p['artifacts'] is List) {
            activeArtifacts = (p['artifacts'] as List)
                .whereType<Map>()
                .map((e) => ArtifactInfo.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          }
          if (p['steps'] is List) {
            final pendingOptimistic = activeSteps.where((s) => s.isOptimistic).toList();
            final bySeq = <int, AgentStep>{
              for (final s in activeSteps)
                if (!s.isOptimistic) s.seq: s,
            };
            final arrivedUserContents = <String>{};
            for (final item in p['steps'] as List) {
              if (item is Map) {
                final step = AgentStep.fromJson(Map<String, dynamic>.from(item));
                bySeq[step.seq] = step;
                if (step.role == 'user') {
                  arrivedUserContents.add(step.content.trim());
                }
              }
            }
            final merged = bySeq.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
            for (final opt in pendingOptimistic) {
              if (!arrivedUserContents.contains(opt.content.trim())) {
                merged.add(opt);
              }
            }
            activeSteps = merged;
          }
          if (activeConversationId != null) {
            unawaited(
              _cache.saveSessionDetail(
                conversationId: activeConversationId!,
                steps: activeSteps,
                artifacts: activeArtifacts,
              ),
            );
          }
          _emitChange();
        } else if (p['summary'] is Map) {
          _emitChange();
        }
        break;

      case 'session.artifact.result':
        final art = p['artifact'];
        if (art is Map) {
          _resolveArtifactWaiter(art['fileName']?.toString(), (art['content'] ?? '').toString());
        } else {
          _resolveArtifactWaiter(null, null);
        }
        break;

      case 'chat.send.result':
        final newId = p['conversationId']?.toString();
        final flushedFromQueue = p['flushedFromQueue'] == true;
        final matchedPrompt = flushedFromQueue ? null : _consumeMatchingPendingPrompt(reqId, newId);
        if (p['ok'] == false) {
          _updateOptimisticStepStatus(matchedPrompt?.optimisticSeq, 'FAILED');
          lastError = (p['error'] ?? 'Не удалось доставить сообщение в Antigravity').toString();
          _emitChange();
          break;
        }
        if (p['delivery'] == 'queued') {
          _updateOptimisticStepStatus(matchedPrompt?.optimisticSeq, 'QUEUED');
          lastError = 'Окно Antigravity пробуждается — сообщение в очереди на доставку.';
          _emitChange();
        } else {
          if (flushedFromQueue && (newId == null || newId == activeConversationId)) {
            activeSteps = activeSteps
                .map((s) => s.isOptimistic && s.status == 'QUEUED' ? s.copyWith(status: 'SENT') : s)
                .toList();
          } else {
            _updateOptimisticStepStatus(matchedPrompt?.optimisticSeq, 'SENT');
          }
          final targetId = newId != null && newId.isNotEmpty ? newId : activeConversationId;
          if (targetId != null && targetId.isNotEmpty) {
            _stoppedSessionStepCounts.remove(targetId);
            sessions = sessions
                .map((s) => s.id == targetId ? s.copyWith(status: 'working') : s)
                .toList();
          }
          if (lastError != null &&
              (lastError!.contains('очеред') || lastError!.contains('WebSocket'))) {
            lastError = null;
          }
          _emitChange();
        }
        if (newId != null && newId.isNotEmpty && activeConversationId == null) {
          openSession(newId);
        }
        break;

      case 'approval.requested':
        final req = ApprovalRequest.fromJson(p);
        pendingApprovals.removeWhere((a) => a.id == req.id);
        pendingApprovals.add(req);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - _lastApprovalHapticMs >= 1500) {
          _lastApprovalHapticMs = nowMs;
          HapticFeedback.mediumImpact();
        }
        _emitChange();
        break;

      case 'approval.resolved':
        final rid = p['id']?.toString();
        pendingApprovals.removeWhere((a) => a.id == rid);
        _emitChange();
        break;

      case 'changes.updated':
      case 'changes.list.result':
      case 'changes.save_all.result':
      case 'changes.revert.result':
        if (p['files'] is List) {
          pendingChanges = (p['files'] as List)
              .whereType<Map>()
              .map((e) => PendingFileChange.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (pendingChangeDiffPath != null &&
              !pendingChanges.any((f) => f.path == pendingChangeDiffPath)) {
            pendingChangeDiffPath = null;
            pendingChangeDiffContent = '';
          }
          _emitChange();
        }
        break;

      case 'changes.diff.result':
        final diffPath = (p['path'] ?? '').toString();
        if (pendingChangeDiffPath == null || pendingChangeDiffPath == diffPath) {
          pendingChangeDiffPath = diffPath;
          pendingChangeDiffContent = (p['diff'] ?? '').toString();
          _emitChange();
        }
        break;

      case 'settings.updated':
        if (p['approvalMode'] != null) {
          approvalMode = p['approvalMode'].toString();
          _emitChange();
        }
        break;

      case 'workspace.status.result':
        gitBranch = (p['branch'] ?? 'workspace').toString();
        workspacePath = (p['workspace'] ?? '').toString();
        if (activeWorkspace.isEmpty && workspacePath.isNotEmpty) {
          activeWorkspace = workspacePath;
        }
        gitFiles = (p['files'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => GitFileChange.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _emitChange();
        break;

      case 'workspace.diff.result':
        selectedDiffPath = (p['path'] ?? '').toString();
        selectedDiffContent = (p['diff'] ?? '').toString();
        _emitChange();
        break;

      case 'terminal.exec.result':
        terminalBusy = false;
        final cmd = (p['command'] ?? '').toString();
        final out = (p['output'] ?? '').toString();
        final code = p['exitCode'] ?? 0;
        final dur = p['durationMs'] ?? 0;
        terminalOutput = '\$ $cmd\n${out.isEmpty ? '(пусто)' : out}\n\n[exit $code • ${dur}ms]';
        _emitChange();
        break;

      case 'error':
        terminalBusy = false;
        if (reqId != null && _uploadWaiters.containsKey(reqId)) {
          final waiter = _uploadWaiters.remove(reqId)!;
          if (!waiter.isCompleted) waiter.complete(null);
        }
        lastError = (p['message'] ?? 'Ошибка запроса').toString();
        _emitChange();
        break;
    }
  }
}
