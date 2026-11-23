part of 'bridge_controller.dart';

extension BridgeControllerActions on BridgeController {
  void openSession(String conversationId) {
    activeConversationId = conversationId;
    activeSteps = [];
    activeArtifacts = [];
    activeMaxSteps = 250;
    activeVisibleStepCount = 0;
    activeHasMoreSteps = false;
    loadingOlderSteps = false;
    loadingSessionDetail = true;
    _emitChange();
    unawaited(_hydrateCachedSessionDetail(conversationId));
    sendRpc('session.detail', {'conversationId': conversationId, 'maxSteps': activeMaxSteps});
  }

  void loadOlderSteps() {
    final convId = activeConversationId;
    if (convId == null || convId.isEmpty || loadingOlderSteps || !activeHasMoreSteps) return;
    loadingOlderSteps = true;
    activeMaxSteps = (activeMaxSteps + 250).clamp(250, 2000);
    _emitChange();
    sendRpc('session.detail', {'conversationId': convId, 'maxSteps': activeMaxSteps});
  }

  Future<void> _hydrateCachedSessionDetail(String conversationId) async {
    final cached = await _cache.loadSessionDetail(conversationId);
    if (cached == null) return;
    if (activeConversationId != conversationId || activeSteps.isNotEmpty) return;
    activeSteps = cached.steps;
    activeArtifacts = cached.artifacts;
    if (cached.steps.isNotEmpty) {
      loadingSessionDetail = false;
    }
    _emitChange();
  }

  void prepareNewSession() {
    activeConversationId = null;
    activeSteps = [];
    activeArtifacts = [];
    activeMaxSteps = 250;
    activeVisibleStepCount = 0;
    activeHasMoreSteps = false;
    loadingOlderSteps = false;
    loadingSessionDetail = false;
    _emitChange();
  }

  /// Switches the active Mac workspace for Git Diff, Terminal, and new conversations.
  void selectWorkspace(String path) {
    final clean = path.trim();
    if (clean.isEmpty) return;
    activeWorkspace = clean;
    workspacePath = clean;
    workspaces = workspaces.map((w) => w.copyWith(isDefault: w.path == clean)).toList();
    _emitChange();
    sendRpc('workspace.select', {'path': clean});
    sendRpc('workspace.status', {'workspace': clean});
    unawaited(_persistMachineSnapshot());
  }

  /// Interrupts the currently open agent task (`chat.stop`).
  void stopActiveSession() => stopSession(activeConversationId ?? '');

  /// Interrupts a specific agent task (`chat.stop`), or all if [conversationId] is empty.
  void stopSession(String conversationId) {
    final convId = conversationId.trim();
    stoppingSession = true;
    if (convId.isEmpty || convId == '*') {
      _workingSessionIds.clear();
    } else {
      _workingSessionIds.remove(convId);
    }
    _markSessionStoppedLocally(convId);
    if (convId.isNotEmpty) {
      pendingApprovals.removeWhere((a) => a.conversationId == convId);
      final removedPending = _pendingPrompts.where((p) => p.conversationId == convId).toList();
      for (final item in removedPending) {
        item.ackTimer?.cancel();
        item.ackTimer = null;
      }
      _pendingPrompts.removeWhere((p) => p.conversationId == convId);
    } else {
      pendingApprovals = [];
      for (final item in _pendingPrompts) {
        item.ackTimer?.cancel();
        item.ackTimer = null;
      }
      _pendingPrompts.clear();
    }
    if (convId.isEmpty || convId == activeConversationId) {
      activeSteps = activeSteps
          .where((s) => !(s.isOptimistic && (s.status == 'SENDING' || s.status == 'QUEUED')))
          .toList();
    }
    if (lastError != null && lastError!.contains('очеред')) {
      lastError = null;
    }
    unawaited(_persistMachineSnapshot());
    _emitChange();
    sendRpc('chat.stop', {'conversationId': convId});
    _stopResetTimer?.cancel();
    _stopResetTimer = Timer(const Duration(milliseconds: 1400), () {
      if (stoppingSession) {
        stoppingSession = false;
        _emitChange();
      }
    });
  }

  void removeAttachment(String id) {
    pendingAttachments = pendingAttachments.where((a) => a.id != id).toList();
    _emitChange();
  }

  /// Opens the native Android picker (`image` or `file`) and uploads the selected file to Mac.
  Future<bool> pickAndUploadAttachment({required String kind}) async {
    try {
      final res = await BridgeController._androidChannel.invokeMethod<Map<dynamic, dynamic>>(
        'pickAttachment',
        {'kind': kind},
      );
      if (res == null) return false;
      final fileName = (res['fileName'] ?? 'attachment.bin').toString();
      final mimeType = (res['mimeType'] ?? '').toString();
      final rawBytes = res['bytes'];
      final Uint8List bytes;
      if (rawBytes is Uint8List) {
        bytes = rawBytes;
      } else if (rawBytes is List<int>) {
        bytes = Uint8List.fromList(rawBytes);
      } else {
        lastError = 'Не удалось получить байты выбранного файла.';
        _emitChange();
        return false;
      }
      return await uploadAttachmentBytes(fileName: fileName, bytes: bytes, mimeType: mimeType);
    } on PlatformException catch (e) {
      lastError = e.message ?? 'Не удалось открыть выбор файла.';
      _emitChange();
      return false;
    } catch (e) {
      lastError = 'Ошибка выбора вложения: $e';
      _emitChange();
      return false;
    }
  }

  /// Uploads raw file/photo bytes to `<workspace>/.antigravity-uploads/` via LAN HTTP (up to 20 MiB)
  /// or WebSocket fallback (`workspace.upload_file`).
  Future<bool> uploadAttachmentBytes({
    required String fileName,
    required Uint8List bytes,
    String mimeType = '',
  }) async {
    if (bytes.isEmpty) {
      lastError = 'Выбранный файл пуст.';
      _emitChange();
      return false;
    }
    final isImg =
        mimeType.toLowerCase().startsWith('image/') ||
        BridgeController._imageExtRe.hasMatch(fileName);
    final attId = 'att_${DateTime.now().microsecondsSinceEpoch}_${++_outboundSeq}';
    final placeholder = PendingAttachment(
      id: attId,
      fileName: fileName,
      sizeBytes: bytes.length,
      isImage: isImg,
      previewBytes: isImg ? bytes : null,
      uploading: true,
    );
    pendingAttachments = [...pendingAttachments, placeholder];
    lastError = null;
    _emitChange();

    final currentSess = sessions
        .where((s) => s.id == activeConversationId)
        .cast<SessionSummary?>()
        .firstWhere((_) => true, orElse: () => null);
    final targetWs = (currentSess != null && currentSess.workspaceHint.isNotEmpty)
        ? currentSess.workspaceHint
        : (activeWorkspace.isNotEmpty ? activeWorkspace : workspacePath);

    final b64 = base64Encode(bytes);
    Map<String, dynamic>? uploaded;

    final machine = activeMachine;
    if (machine != null &&
        machine.lanUrl.isNotEmpty &&
        machine.deviceToken.isNotEmpty &&
        activeTransport == 'LAN') {
      try {
        final cleanBase = machine.lanUrl.replaceAll(RegExp(r'/+$'), '');
        final res = await _httpClient
            .post(
              Uri.parse('$cleanBase/api/mobile/upload'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${machine.deviceToken}',
              },
              body: jsonEncode({
                'fileName': fileName,
                'base64Data': b64,
                if (targetWs.isNotEmpty) 'workspace': targetWs,
              }),
            )
            .timeout(const Duration(seconds: 25));
        if (res.statusCode == 200) {
          final parsed = jsonDecode(res.body) as Map<String, dynamic>;
          if (parsed['ok'] == true) {
            uploaded = parsed;
          }
        }
      } catch (_) {
        // Fall through to WebSocket RPC fallback below
      }
    }

    if (uploaded == null && _socket != null && phase == ConnectionPhase.connected) {
      if (bytes.length > 5 * 1024 * 1024) {
        _removeFailedAttachment(
          attId,
          'Через Cloudflare Edge лимит файла 5 МБ (по Wi‑Fi LAN — до 20 МБ).',
        );
        return false;
      }
      final reqId = 'up_${DateTime.now().microsecondsSinceEpoch}_${++_outboundSeq}';
      final completer = Completer<Map<String, dynamic>?>();
      _uploadWaiters[reqId] = completer;
      sendRpc('workspace.upload_file', {
        'fileName': fileName,
        'base64Data': b64,
        if (targetWs.isNotEmpty) 'workspace': targetWs,
      }, reqId: reqId);
      uploaded = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          _uploadWaiters.remove(reqId);
          return null;
        },
      );
    }

    if (uploaded == null || uploaded['ok'] != true) {
      _removeFailedAttachment(attId, 'Не удалось загрузить «$fileName» на компьютер.');
      return false;
    }

    pendingAttachments = pendingAttachments.map((a) {
      if (a.id != attId) return a;
      return a.copyWith(
        savedPath: (uploaded!['savedPath'] ?? '').toString(),
        relativePath: (uploaded['relativePath'] ?? '').toString(),
        isImage: uploaded['isImage'] == true || a.isImage,
        uploading: false,
        clearError: true,
      );
    }).toList();
    _emitChange();
    return true;
  }

  void _removeFailedAttachment(String attId, String message) {
    pendingAttachments = pendingAttachments.where((a) => a.id != attId).toList();
    lastError = message;
    _emitChange();
  }

  void sendPrompt(String prompt) {
    final clean = prompt.trim();
    final readyAttachments = pendingAttachments
        .where((a) => !a.uploading && a.savedPath.isNotEmpty)
        .toList();
    if (clean.isEmpty && readyAttachments.isEmpty) return;

    String composed = clean;
    if (readyAttachments.isNotEmpty) {
      final attLines = readyAttachments
          .map((a) {
            final kindTag = a.isImage ? 'Изображение' : 'Файл';
            return '- $kindTag `${a.fileName}`: `${a.savedPath}`';
          })
          .join('\n');
      final header = '[Прикреплено с телефона]\n$attLines';
      final defaultAsk = readyAttachments.every((a) => a.isImage)
          ? 'Посмотри прикреплённое изображение через read_file и помоги по нему.'
          : 'Прочитай прикреплённый файл через read_file и выполни задачу.';
      composed = clean.isEmpty ? '$header\n\n$defaultAsk' : '$header\n\n$clean';
      final consumedIds = readyAttachments.map((a) => a.id).toSet();
      pendingAttachments = pendingAttachments.where((a) => !consumedIds.contains(a.id)).toList();
    }

    lastError = null;
    final reqId = 'chat_${DateTime.now().microsecondsSinceEpoch}_${++_outboundSeq}';
    final currentSess = activeConversationId == null
        ? null
        : sessions
              .where((s) => s.id == activeConversationId)
              .cast<SessionSummary?>()
              .firstWhere((_) => true, orElse: () => null);
    final rawTargetWs = activeConversationId != null
        ? (currentSess != null && currentSess.workspaceHint.isNotEmpty
              ? currentSess.workspaceHint
              : '')
        : activeWorkspace;
    final normTargetWs = rawTargetWs.replaceAll('\\', '/');
    final targetWs =
        (rawTargetWs.isNotEmpty &&
            !normTargetWs.contains('/.gemini/') &&
            !normTargetWs.endsWith('/.gemini'))
        ? rawTargetWs
        : null;

    if (activeConversationId != null) {
      _stoppedSessionStepCounts.remove(activeConversationId);
      final nextOptimisticSeq = activeSteps.isEmpty
          ? AgentStep.optimisticStepIndex
          : (activeSteps.last.seq + 100000);
      activeSteps = [
        ...activeSteps,
        AgentStep(
          seq: nextOptimisticSeq,
          stepIndex: AgentStep.optimisticStepIndex,
          role: 'user',
          status: 'SENDING',
          source: 'mobile',
          thinking: '',
          content: composed,
          toolCalls: const [],
        ),
      ];
      final pending = PendingOutboundPrompt(
        reqId: reqId,
        conversationId: activeConversationId,
        prompt: composed,
        workspace: targetWs,
        optimisticSeq: nextOptimisticSeq,
      );
      _pendingPrompts.add(pending);
      _emitChange();
      _dispatchOrQueuePrompt(pending);
    } else {
      final pending = PendingOutboundPrompt(
        reqId: reqId,
        conversationId: null,
        prompt: composed,
        workspace: targetWs,
        optimisticSeq: null,
      );
      _pendingPrompts.add(pending);
      _emitChange();
      _dispatchOrQueuePrompt(pending);
    }
  }

  void retryFailedPrompt(int optimisticSeq) {
    final idx = activeSteps.indexWhere((s) => s.isOptimistic && s.seq == optimisticSeq);
    if (idx == -1) return;
    final step = activeSteps[idx];
    activeSteps = List<AgentStep>.from(activeSteps)..removeAt(idx);
    sendPrompt(step.content);
  }

  void setApprovalMode(String mode) {
    if (!BridgeController.validApprovalModes.contains(mode)) return;
    approvalMode = mode;
    _emitChange();
    sendRpc('settings.set', {'approvalMode': mode});
  }

  void cycleApprovalMode() {
    final idx = BridgeController.validApprovalModes.indexOf(approvalMode);
    final next =
        BridgeController.validApprovalModes[(idx + 1) % BridgeController.validApprovalModes.length];
    setApprovalMode(next);
  }

  void decideApproval(String id, String decision) {
    sendRpc('approval.decide', {'id': id, 'decision': decision});
    pendingApprovals.removeWhere((a) => a.id == id);
    _emitChange();
  }

  void decideAllApprovals(String decision) {
    if (pendingApprovals.isEmpty) return;
    final ids = pendingApprovals.map((a) => a.id).toList();
    sendRpc('approval.decide_batch', {'ids': ids, 'decision': decision});
    pendingApprovals = [];
    _emitChange();
  }

  void saveAllChanges({List<String>? paths}) {
    if (paths == null || paths.isEmpty) {
      sendRpc('changes.save_all', const {});
      pendingChanges = [];
      pendingChangeDiffPath = null;
      pendingChangeDiffContent = '';
    } else {
      sendRpc('changes.save_all', {'paths': paths});
      final pathSet = paths.toSet();
      pendingChanges.removeWhere((f) => pathSet.contains(f.path));
      if (pendingChangeDiffPath != null && pathSet.contains(pendingChangeDiffPath)) {
        pendingChangeDiffPath = null;
        pendingChangeDiffContent = '';
      }
    }
    sendRpc('workspace.status', const {});
    _emitChange();
  }

  void revertChanges({List<String>? paths, bool all = false}) {
    if (all) {
      sendRpc('changes.revert', const {'all': true});
      pendingChanges = [];
      pendingChangeDiffPath = null;
      pendingChangeDiffContent = '';
    } else if (paths != null && paths.isNotEmpty) {
      sendRpc('changes.revert', {'paths': paths});
      final pathSet = paths.toSet();
      pendingChanges.removeWhere((f) => pathSet.contains(f.path));
      if (pendingChangeDiffPath != null && pathSet.contains(pendingChangeDiffPath)) {
        pendingChangeDiffPath = null;
        pendingChangeDiffContent = '';
      }
    }
    sendRpc('workspace.status', const {});
    _emitChange();
  }

  void requestPendingChangeDiff(String path) {
    if (pendingChangeDiffPath == path) {
      pendingChangeDiffPath = null;
      pendingChangeDiffContent = '';
      _emitChange();
      return;
    }
    pendingChangeDiffPath = path;
    pendingChangeDiffContent = 'Загрузка diff…';
    _emitChange();
    sendRpc('changes.diff', {'path': path});
  }

  void requestFileDiff(String path) {
    selectedDiffPath = path;
    selectedDiffContent = 'Загрузка diff…';
    _emitChange();
    sendRpc('workspace.diff', {'path': path});
  }

  void runQuickCommand(String cmd) {
    final clean = cmd.trim();
    if (clean.isEmpty) return;
    terminalBusy = true;
    final nextHistory = [
      clean,
      ...terminalHistory.where((h) => h != clean),
    ];
    terminalHistory = nextHistory.length > BridgeController._maxTerminalHistory
        ? nextHistory.sublist(0, BridgeController._maxTerminalHistory)
        : nextHistory;
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setStringList(BridgeController._terminalHistoryKey, terminalHistory),
      ),
    );
    final pendingBlock = '\$ $clean\nВыполнение…';
    if (terminalOutput == '# Удалённый терминал готов к работе' ||
        terminalOutput == '# Вывод терминала очищен') {
      terminalOutput = pendingBlock;
    } else {
      final combined = '$terminalOutput\n\n$pendingBlock';
      terminalOutput = combined.length > BridgeController._maxTerminalOutputChars
          ? combined.substring(combined.length - BridgeController._maxTerminalOutputChars)
          : combined;
    }
    _emitChange();
    sendRpc('terminal.exec', {'command': clean});
  }

  Future<String?> fetchArtifactMarkdown(String fileName) async {
    final conv = activeConversationId;
    if (conv == null || fileName.trim().isEmpty) return null;

    if (_socket == null || phase != ConnectionPhase.connected) {
      return _cache.loadArtifactMarkdown(conv, fileName);
    }

    final completer = Completer<String?>();
    final bucket = _artifactWaiters.putIfAbsent(fileName, () => <Completer<String?>>[]);
    bucket.add(completer);
    sendRpc('session.artifact', {'conversationId': conv, 'fileName': fileName});
    final liveContent = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        bucket.remove(completer);
        if (bucket.isEmpty) _artifactWaiters.remove(fileName);
        return null;
      },
    );
    if (liveContent != null && liveContent.isNotEmpty) {
      unawaited(_cache.saveArtifactMarkdown(conv, fileName, liveContent));
      return liveContent;
    }
    return _cache.loadArtifactMarkdown(conv, fileName);
  }

  void requestDevicesList() => sendRpc('devices.list', const {});

  void revokePairedDevice(String deviceId) {
    final cleanId = deviceId.trim();
    if (cleanId.isEmpty) return;
    pairedDevices = pairedDevices.where((d) => d.id != cleanId).toList();
    _emitChange();
    sendRpc('devices.revoke', {'deviceId': cleanId});
  }
}
