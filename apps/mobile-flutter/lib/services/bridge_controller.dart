import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/remote_models.dart';
import 'lan_discovery_service.dart';
import 'offline_cache_service.dart';

enum ConnectionPhase { disconnected, connecting, connected }

/// Transport abstraction decoupling `BridgeController` from concrete WebSocket I/O.
abstract interface class RpcSocketTransport {
  Future<void> get ready;
  Stream<dynamic> get stream;
  void send(String data);
  Future<void> close();
}

/// Default production WebSocket transport backed by `package:web_socket_channel`.
class WebSocketRpcTransport implements RpcSocketTransport {
  final WebSocketChannel _channel;

  WebSocketRpcTransport(Uri uri) : _channel = WebSocketChannel.connect(uri) {
    // Prevent unhandled async WebSocketChannelException if TCP handshake times out
    // or socket is closed while connecting.
    _channel.ready.then<void>((_) {}, onError: (_) {});
  }

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}

class _PendingOutboundPrompt {
  final String reqId;
  final String? conversationId;
  final String prompt;
  final String? workspace;
  final int? optimisticSeq;
  bool sentOnCurrentSocket = false;
  Timer? ackTimer;

  _PendingOutboundPrompt({
    required this.reqId,
    required this.conversationId,
    required this.prompt,
    this.workspace,
    required this.optimisticSeq,
  });
}

class BridgeController extends ChangeNotifier {
  static const String _machinesPrefsKey = 'agy_remote_saved_machines_v1';
  static const MethodChannel _androidChannel = MethodChannel('dev.antigravity.remote/android');
  static const List<String> validApprovalModes = ['ask-mobile', 'auto-safe', 'observe'];
  static final RegExp _imageExtRe =
      RegExp(r'\.(png|jpe?g|webp|gif|heic|heif|bmp|svg)$', caseSensitive: false);

  http.Client _httpClient;
  final bool _ownsHttpClient;
  final RpcSocketTransport Function(Uri uri) _socketFactory;
  final OfflineCacheService _cache;
  late final LanDiscoveryService _lanDiscovery;
  final bool _enableAutoLanDiscovery;
  final Duration reconnectDelay;
  final Duration pingInterval;
  final Duration pongTimeout;
  final Duration chatAckTimeout;

  BridgeController({
    http.Client? httpClient,
    RpcSocketTransport Function(Uri uri)? socketFactory,
    OfflineCacheService? cacheService,
    Future<List<DiscoveredLanBridge>> Function()? lanScanner,
    this.reconnectDelay = const Duration(milliseconds: 1800),
    this.pingInterval = const Duration(seconds: 10),
    this.pongTimeout = const Duration(seconds: 5),
    this.chatAckTimeout = const Duration(seconds: 10),
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _socketFactory = socketFactory ?? WebSocketRpcTransport.new,
        _cache = cacheService ?? OfflineCacheService(),
        _enableAutoLanDiscovery = httpClient == null || lanScanner != null {
    _lanDiscovery = LanDiscoveryService(
      httpClientProvider: () => _httpClient,
      customScanner: lanScanner,
    );
    _registerPlatformCallbacksIfSupported();
  }

  List<SavedMachine> savedMachines = [];
  SavedMachine? activeMachine;
  ConnectionPhase phase = ConnectionPhase.disconnected;
  String activeTransport = 'LAN'; // 'LAN' | 'CF EDGE'
  int? latencyMs;
  String? lastError;

  // #22 LAN Discovery state
  List<DiscoveredLanBridge> discoveredBridges = [];
  bool scanningLan = false;

  // #20 & #21 Workspaces, Pinning, and Session Filters
  String approvalMode = 'ask-mobile';
  List<SessionSummary> sessions = [];
  Set<String> pinnedSessionIds = <String>{};
  List<WorkspaceInfo> workspaces = [];
  String activeWorkspace = '';
  String selectedWorkspaceFilter = ''; // '' = all workspaces

  String? activeConversationId;
  List<AgentStep> activeSteps = [];
  List<ArtifactInfo> activeArtifacts = [];
  List<ApprovalRequest> pendingApprovals = [];
  List<PendingFileChange> pendingChanges = [];
  String? pendingChangeDiffPath;
  String pendingChangeDiffContent = '';

  // #11 & #12 Uploads & Stop state
  List<PendingAttachment> pendingAttachments = [];
  bool stoppingSession = false;

  String gitBranch = 'main';
  String workspacePath = '';
  List<GitFileChange> gitFiles = [];
  String? selectedDiffPath;
  String selectedDiffContent = '';

  String terminalOutput = '# Удалённый терминал готов к работе';
  bool terminalBusy = false;

  void clearTerminalOutput() {
    terminalOutput = '# Вывод терминала очищен';
    notifyListeners();
  }

  RpcSocketTransport? _socket;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _pingTimer;
  Timer? _pongWatchdogTimer;
  Timer? _reconnectTimer;
  Timer? _attemptWatchdogTimer;
  Timer? _networkDebounceTimer;
  Timer? _stopResetTimer;
  int _lastPingSentMs = 0;
  int _lastInboundMs = 0;
  int _lastPausedAtMs = 0;
  int _lastAttemptStartedMs = 0;
  int _lastApprovalHapticMs = 0;
  int _outboundSeq = 0;
  int _connectEpoch = 0;
  int _reconnectAttempts = 0;
  bool _manualDisconnect = false;
  bool _appInBackground = false;
  bool _disposed = false;
  final Map<String, List<Completer<String?>>> _artifactWaiters = {};
  final Map<String, Completer<Map<String, dynamic>?>> _uploadWaiters = {};
  final List<_PendingOutboundPrompt> _pendingPrompts = [];
  final Map<String, int> _stoppedSessionStepCounts = {};

  void _markSessionStoppedLocally(String convId) {
    if (convId.isEmpty || convId == '*') {
      for (final s in sessions) {
        if (s.status == 'working') {
          _stoppedSessionStepCounts[s.id] = s.stepCount;
        }
      }
      sessions = sessions
          .map(
            (s) => s.status == 'working'
                ? s.copyWith(status: 'idle', lastActivity: 'Stopped')
                : s,
          )
          .toList();
      return;
    }
    final existing = sessions
        .where((s) => s.id == convId)
        .cast<SessionSummary?>()
        .firstWhere((_) => true, orElse: () => null);
    final baselineSteps = existing?.stepCount ?? activeSteps.length;
    final prevRecorded = _stoppedSessionStepCounts[convId];
    if (prevRecorded == null || baselineSteps > prevRecorded) {
      _stoppedSessionStepCounts[convId] = baselineSteps;
    }
    sessions = sessions
        .map(
          (s) => s.id == convId
              ? s.copyWith(status: 'idle', lastActivity: 'Stopped')
              : s,
        )
        .toList();
  }

  SessionSummary _applyStoppedMask(SessionSummary s) {
    final stoppedStepCount = _stoppedSessionStepCounts[s.id];
    if (stoppedStepCount == null) return s;
    if (s.status != 'working') return s;
    if (s.stepCount > stoppedStepCount) {
      _stoppedSessionStepCounts.remove(s.id);
      return s;
    }
    return s.copyWith(status: 'idle', lastActivity: 'Stopped');
  }

  void _upsertSessionSummary(SessionSummary incoming) {
    final masked = _applyStoppedMask(incoming);
    final idx = sessions.indexWhere((s) => s.id == masked.id);
    if (idx == -1) {
      sessions = [masked, ...sessions];
    } else {
      final copy = List<SessionSummary>.from(sessions);
      copy[idx] = masked;
      sessions = copy;
    }
  }

  void _registerPlatformCallbacksIfSupported() {
    if (kIsWeb) return;
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return;
      _androidChannel.setMethodCallHandler((call) async {
        if (_disposed) return null;
        switch (call.method) {
          case 'onNetworkAvailable':
            onNetworkAvailable();
            break;
          case 'onNativeResumed':
            onAppResumed();
            break;
          case 'onNativePaused':
            onAppPaused();
            break;
        }
        return null;
      });
    } catch (_) {}
  }

  void _refreshHttpClientIfOwned() {
    if (!_ownsHttpClient || _disposed) return;
    final old = _httpClient;
    _httpClient = http.Client();
    try {
      old.close();
    } catch (_) {}
  }

  bool get hasUploadingAttachments => pendingAttachments.any((a) => a.uploading);
  bool get hasReadyAttachments =>
      pendingAttachments.any((a) => !a.uploading && a.savedPath.isNotEmpty);

  String get activeWorkspaceName {
    final raw = activeWorkspace.isNotEmpty ? activeWorkspace : workspacePath;
    if (raw.isEmpty) return 'Проект';
    final parts = raw.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? raw : parts.last;
  }

  bool isSessionPinned(String id) => pinnedSessionIds.contains(id);
  bool isSessionCached(String id) => _cache.hasCachedDetailSync(id);

  Future<void> togglePinSession(String id) async {
    if (id.isEmpty) return;
    if (pinnedSessionIds.contains(id)) {
      pinnedSessionIds = Set<String>.from(pinnedSessionIds)..remove(id);
    } else {
      pinnedSessionIds = Set<String>.from(pinnedSessionIds)..add(id);
    }
    notifyListeners();
    await _cache.savePinnedSessions(pinnedSessionIds);
  }

  void setWorkspaceFilter(String filter) {
    if (selectedWorkspaceFilter == filter) return;
    selectedWorkspaceFilter = filter;
    notifyListeners();
  }

  List<SessionSummary> filterAndSortSessions({
    String query = '',
    String statusFilter = 'all',
  }) {
    final q = query.trim().toLowerCase();
    final wsFilter = selectedWorkspaceFilter.trim().toLowerCase();

    final list = sessions.where((s) {
      if (statusFilter == 'working' && s.status != 'working') return false;
      if (statusFilter == 'pinned' && !pinnedSessionIds.contains(s.id)) return false;
      if (wsFilter.isNotEmpty) {
        final sWsName = s.workspaceName.toLowerCase();
        final sWsHint = s.workspaceHint.toLowerCase();
        if (sWsName != wsFilter && !sWsHint.endsWith('/$wsFilter') && sWsHint != wsFilter) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      if (s.title.toLowerCase().contains(q) ||
          s.lastActivity.toLowerCase().contains(q) ||
          s.workspaceName.toLowerCase().contains(q)) {
        return true;
      }
      return _cache.getCachedSearchText(s.id).contains(q);
    }).toList();

    list.sort((a, b) {
      final aPinned = pinnedSessionIds.contains(a.id);
      final bPinned = pinnedSessionIds.contains(b.id);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      return b.updatedAtMs.compareTo(a.updatedAtMs);
    });
    return list;
  }

  Future<void> init({bool autoConnect = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_machinesPrefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        savedMachines = decoded
            .whereType<Map>()
            .map((m) => SavedMachine.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      } catch (_) {}
    }
    pinnedSessionIds = await _cache.loadPinnedSessions();
    unawaited(_cache.warmSearchIndex());
    notifyListeners();
    if (autoConnect && savedMachines.isNotEmpty) {
      unawaited(connectToMachine(savedMachines.first));
    }
  }

  Future<void> _persistMachines() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _machinesPrefsKey,
      jsonEncode(savedMachines.map((m) => m.toJson()).toList()),
    );
  }

  Future<void> _persistMachineSnapshot() async {
    final mid = activeMachine?.machineId ?? '';
    if (mid.isEmpty) return;
    await _cache.saveMachineSnapshot(
      machineId: mid,
      sessions: sessions,
      workspaces: workspaces,
      activeWorkspace: activeWorkspace,
    );
  }

  /// Scans Wi-Fi via mDNS + UDP Broadcast for running Antigravity Remote Bridges (#22).
  Future<List<DiscoveredLanBridge>> scanLanBridges({bool force = false}) async {
    if (!force && !_enableAutoLanDiscovery) return discoveredBridges;
    if (scanningLan) return discoveredBridges;
    scanningLan = true;
    notifyListeners();
    try {
      final found = await _lanDiscovery.discover();
      discoveredBridges = found;
      var updatedSaved = false;
      for (var i = 0; i < savedMachines.length; i++) {
        final saved = savedMachines[i];
        if (saved.machineId.isEmpty) continue;
        final match = found
            .where((b) => b.machineId == saved.machineId)
            .cast<DiscoveredLanBridge?>()
            .firstWhere((_) => true, orElse: () => null);
        if (match != null && match.lanUrl.isNotEmpty && match.lanUrl != saved.lanUrl) {
          savedMachines[i] = saved.copyWith(lanUrl: match.lanUrl);
          updatedSaved = true;
        }
      }
      if (updatedSaved) {
        await _persistMachines();
      }
      return found;
    } finally {
      scanningLan = false;
      notifyListeners();
    }
  }

  Future<void> removeMachine(String machineId) async {
    if (activeMachine?.machineId == machineId) {
      await disconnect();
    }
    savedMachines.removeWhere((m) => m.machineId == machineId);
    await _persistMachines();
    notifyListeners();
  }

  /// Pairs using a scanned QR code URL (`http://<LAN>:7443/pair?t=...&cf=...`).
  Future<bool> pairFromQrUrl(String rawUrl, {String deviceName = 'Flutter Mobile'}) async {
    final parsed = PairingQrPayload.tryParse(rawUrl);
    if (parsed == null) {
      lastError = 'Некорректный формат QR-кода Antigravity Remote.';
      notifyListeners();
      return false;
    }
    return pairWithEndpoint(
      baseUrl: parsed.baseUrl,
      token: parsed.token,
      cloudflareUrl: parsed.cloudflareUrl,
      sessionId: parsed.sessionId,
      deviceName: deviceName,
    );
  }

  /// Pairs with either LAN Bridge or Cloudflare Edge Worker via QR Token or 6-digit PIN.
  Future<bool> pairWithEndpoint({
    required String baseUrl,
    String token = '',
    String pin = '',
    String cloudflareUrl = '',
    String sessionId = '',
    String deviceName = 'Flutter Mobile',
  }) async {
    lastError = null;
    phase = ConnectionPhase.connecting;
    notifyListeners();

    final cleanBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final res = await _httpClient
          .post(
            Uri.parse('$cleanBase/api/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token': token,
              'pin': pin.replaceAll(RegExp(r'\s+|-'), ''),
              'sessionId': sessionId,
              'deviceName': deviceName,
              'platform': defaultTargetPlatform.name,
            }),
          )
          .timeout(const Duration(seconds: 8));

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || body['ok'] != true) {
        lastError = (body['error'] ?? 'Ошибка привязки (${res.statusCode})').toString();
        phase = ConnectionPhase.disconnected;
        notifyListeners();
        return false;
      }

      final isEdgeUrl =
          cleanBase.contains('workers.dev') || cleanBase.contains('trycloudflare.com');
      final machineId = (body['machineId'] ?? sessionId).toString();
      final machineName = (body['machineName'] ?? 'Antigravity PC').toString();
      final issuedToken = (body['deviceToken'] ?? '').toString();
      final reportedLan = body['lanIp'] != null && body['port'] != null
          ? 'http://${body['lanIp']}:${body['port']}'
          : '';
      final reportedCf = (body['cloudflareUrl'] ?? cloudflareUrl).toString();

      final machine = SavedMachine(
        machineId: machineId,
        machineName: machineName,
        lanUrl: isEdgeUrl ? reportedLan : cleanBase,
        cloudflareUrl: isEdgeUrl ? cleanBase : reportedCf,
        sessionId: (body['sessionId'] ?? machineId).toString(),
        deviceToken: isEdgeUrl ? '' : issuedToken,
        edgeDeviceToken: isEdgeUrl ? issuedToken : '',
        lastConnectedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

      savedMachines.removeWhere((m) => m.machineId == machine.machineId);
      savedMachines.insert(0, machine);
      await _persistMachines();

      await connectToMachine(machine);
      return true;
    } catch (e) {
      lastError = 'Не удалось подключиться к $cleanBase: $e';
      phase = ConnectionPhase.disconnected;
      notifyListeners();
      return false;
    }
  }

  /// Connects to a saved machine using Epoch-Preemptive Smart Auto-Failover + Offline Cache Hydration + DHCP IP Healing:
  /// - Monotonic `_connectEpoch` guarantees a hung background attempt can never block foreground recovery.
  /// 0. Hydrates cached sessions/workspaces immediately (#23)
  /// 1. Fast LAN Wi-Fi probe (1.4s timeout) -> lowest latency!
  /// 2. If LAN ping fails (e.g. router reassigned DHCP IP), probes mDNS/UDP LAN beacon to heal IP (#22)
  /// 3. Automatic fallback to Cloudflare Edge WSS if outside home LAN!
  Future<void> connectToMachine(SavedMachine machine) async {
    if (_disposed) return;
    final epoch = ++_connectEpoch;
    _manualDisconnect = false;
    _lastAttemptStartedMs = DateTime.now().millisecondsSinceEpoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attemptWatchdogTimer?.cancel();
    _attemptWatchdogTimer = Timer(const Duration(seconds: 10), () {
      if (_disposed || _manualDisconnect || _appInBackground) return;
      if (epoch == _connectEpoch && phase != ConnectionPhase.connected) {
        _scheduleReconnect();
      }
    });

    var currentMachine = machine;
    activeMachine = currentMachine;
    phase = ConnectionPhase.connecting;
    lastError = null;
    notifyListeners();

    try {
      if (sessions.isEmpty && currentMachine.machineId.isNotEmpty) {
        try {
          final cached = await _cache
              .loadMachineSnapshot(currentMachine.machineId)
              .timeout(const Duration(milliseconds: 600));
          if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
          if (sessions.isEmpty &&
              (cached.sessions.isNotEmpty || cached.workspaces.isNotEmpty)) {
            sessions = cached.sessions;
            workspaces = cached.workspaces;
            if (activeWorkspace.isEmpty && cached.activeWorkspace.isNotEmpty) {
              activeWorkspace = cached.activeWorkspace;
            }
            notifyListeners();
          }
        } catch (_) {
          if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
        }
      }

      _closeSocketOnly();
      if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;

      String? targetWsUrl;
      String chosenTransport = 'LAN';

      if (currentMachine.lanUrl.isNotEmpty && currentMachine.deviceToken.isNotEmpty) {
        var lanReachable = await _probePing(currentMachine.lanUrl);
        if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;

        if (!lanReachable &&
            _enableAutoLanDiscovery &&
            currentMachine.machineId.isNotEmpty) {
          final discovered = await _lanDiscovery.discover(
            timeout: const Duration(milliseconds: 950),
          );
          if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
          discoveredBridges = discovered;
          final match = discovered
              .where((b) => b.machineId == currentMachine.machineId)
              .cast<DiscoveredLanBridge?>()
              .firstWhere((_) => true, orElse: () => null);
          if (match != null &&
              match.lanUrl.isNotEmpty &&
              match.lanUrl != currentMachine.lanUrl) {
            currentMachine = currentMachine.copyWith(lanUrl: match.lanUrl);
            activeMachine = currentMachine;
            final sIdx =
                savedMachines.indexWhere((m) => m.machineId == currentMachine.machineId);
            if (sIdx != -1) {
              savedMachines[sIdx] = currentMachine;
              await _persistMachines();
              if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
            }
            lanReachable = await _probePing(currentMachine.lanUrl);
            if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
          }
        }
        if (lanReachable) {
          final wsBase = currentMachine.lanUrl
              .replaceFirst(RegExp(r'^http:'), 'ws:')
              .replaceFirst(RegExp(r'^https:'), 'wss:');
          targetWsUrl =
              '$wsBase/ws?token=${Uri.encodeComponent(currentMachine.deviceToken)}';
          chosenTransport = 'LAN';
        }
      }

      if (targetWsUrl == null && currentMachine.cloudflareUrl.isNotEmpty) {
        final tok = currentMachine.edgeDeviceToken.isNotEmpty
            ? currentMachine.edgeDeviceToken
            : currentMachine.deviceToken;
        if (tok.isNotEmpty) {
          final wsBase = currentMachine.cloudflareUrl
              .replaceFirst(RegExp(r'^http:'), 'ws:')
              .replaceFirst(RegExp(r'^https:'), 'wss:');
          targetWsUrl =
              '$wsBase/ws?token=${Uri.encodeComponent(tok)}&sessionId=${Uri.encodeComponent(currentMachine.sessionId)}';
          chosenTransport = 'CF EDGE';
        }
      }

      // Fallback: try LAN URL directly even if HTTP ping probe timed out
      if (targetWsUrl == null &&
          currentMachine.lanUrl.isNotEmpty &&
          currentMachine.deviceToken.isNotEmpty) {
        final wsBase = currentMachine.lanUrl
            .replaceFirst(RegExp(r'^http:'), 'ws:')
            .replaceFirst(RegExp(r'^https:'), 'wss:');
        targetWsUrl =
            '$wsBase/ws?token=${Uri.encodeComponent(currentMachine.deviceToken)}';
        chosenTransport = 'LAN';
      }

      if (targetWsUrl == null) {
        _attemptWatchdogTimer?.cancel();
        _attemptWatchdogTimer = null;
        lastError = 'Нет доступного токена для LAN или Cloudflare Edge.';
        phase = ConnectionPhase.disconnected;
        notifyListeners();
        return;
      }

      activeTransport = chosenTransport;
      final socket = _socketFactory(Uri.parse(targetWsUrl));
      _socket = socket;

      await socket.ready.timeout(const Duration(seconds: 5));
      if (epoch != _connectEpoch || _socket != socket || _manualDisconnect || _disposed) {
        unawaited(
          socket
              .close()
              .timeout(const Duration(milliseconds: 400), onTimeout: () {})
              .catchError((_) {}),
        );
        return;
      }

      _wsSub = socket.stream.listen(
        _onSocketMessage,
        onError: (Object err) {
          if (_disposed || _manualDisconnect || epoch != _connectEpoch || _socket != socket) {
            return;
          }
          lastError = err.toString();
          _scheduleReconnect();
        },
        onDone: () {
          if (_disposed || _manualDisconnect || epoch != _connectEpoch || _socket != socket) {
            return;
          }
          _scheduleReconnect();
        },
      );

      _attemptWatchdogTimer?.cancel();
      _attemptWatchdogTimer = null;
      _reconnectAttempts = 0;
      phase = ConnectionPhase.connected;
      _lastInboundMs = DateTime.now().millisecondsSinceEpoch;
      _sendPing();
      _pingTimer = Timer.periodic(pingInterval, (_) => _sendPing());
      sendRpc('sessions.list', const {});
      sendRpc('workspaces.list', const {});
      sendRpc('workspace.status', const {});
      sendRpc('changes.list', const {});
      if (activeConversationId != null) {
        sendRpc('session.detail', {'conversationId': activeConversationId, 'maxSteps': 250});
      }
      _flushPendingPrompts();
      notifyListeners();
    } catch (e) {
      if (_disposed || _manualDisconnect || epoch != _connectEpoch) return;
      _attemptWatchdogTimer?.cancel();
      _attemptWatchdogTimer = null;
      lastError = 'Ошибка WebSocket: $e';
      _scheduleReconnect();
    }
  }

  /// Called when the app enters background (`AppLifecycleState.paused`).
  /// Stops periodic pings and background retry churn against Android's UID firewall.
  void onAppPaused() {
    if (_disposed || _appInBackground) return;
    _appInBackground = true;
    _lastPausedAtMs = DateTime.now().millisecondsSinceEpoch;
    ++_connectEpoch;
    _pingTimer?.cancel();
    _pingTimer = null;
    _pongWatchdogTimer?.cancel();
    _pongWatchdogTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attemptWatchdogTimer?.cancel();
    _attemptWatchdogTimer = null;
    _networkDebounceTimer?.cancel();
    _networkDebounceTimer = null;
  }

  /// Called when the app returns to foreground (`AppLifecycleState.resumed`) after Android sleep/Doze.
  void onAppResumed() {
    if (_disposed || _manualDisconnect) return;
    final wasInBackground = _appInBackground;
    _appInBackground = false;
    final m = activeMachine;
    if (m == null) return;

    _reconnectAttempts = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pausedDurationMs = _lastPausedAtMs > 0 ? (now - _lastPausedAtMs) : 0;
    _lastPausedAtMs = 0;

    // After >= 8s in background (or if already disconnected/connecting), TCP sockets on Android/OxygenOS
    // are dead or frozen — preemptively rebuild HTTP client & WebSocket immediately!
    if (pausedDurationMs >= 8000 || _socket == null || phase != ConnectionPhase.connected) {
      final elapsedSinceAttempt = now - _lastAttemptStartedMs;
      // Avoid cancelling a brand-new foreground startup/resume attempt started < 450ms ago
      if (!wasInBackground &&
          phase == ConnectionPhase.connecting &&
          _reconnectTimer == null &&
          elapsedSinceAttempt >= 0 &&
          elapsedSinceAttempt < 450) {
        return;
      }
      _refreshHttpClientIfOwned();
      reconnectNow();
      return;
    }

    // Brief app switch (< 8s) while still connected: restart periodic ping timer and probe immediately.
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) => _sendPing());
    final probeMs = pongTimeout.inMilliseconds < 1200 ? pongTimeout.inMilliseconds : 1200;
    _sendPing(customWatchdogTimeout: Duration(milliseconds: probeMs));
  }

  /// Triggered by Android `ConnectivityManager.NetworkCallback` when Wi-Fi/cell becomes available
  /// or when OxygenOS/ColorOS unblocks network sockets for the app UID ~200-800ms after resume.
  void onNetworkAvailable() {
    if (_disposed || _manualDisconnect || _appInBackground) return;
    if (activeMachine == null || phase == ConnectionPhase.connected) return;

    _reconnectAttempts = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsedSinceAttempt = now - _lastAttemptStartedMs;

    if (elapsedSinceAttempt >= 250) {
      _networkDebounceTimer?.cancel();
      _networkDebounceTimer = null;
      _refreshHttpClientIfOwned();
      reconnectNow();
      return;
    }

    // An attempt just started <250ms ago (potentially right before UID network unblock finished).
    // Schedule a follow-up check so if that attempt didn't immediately connect, we preempt with a fresh post-unblock socket.
    _networkDebounceTimer?.cancel();
    _networkDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _networkDebounceTimer = null;
      if (_disposed || _manualDisconnect || _appInBackground) return;
      if (activeMachine != null && phase != ConnectionPhase.connected) {
        _refreshHttpClientIfOwned();
        reconnectNow();
      }
    });
  }

  /// Immediately preempts any in-flight or scheduled reconnect attempt and starts a fresh connection.
  void reconnectNow() {
    if (_disposed || _manualDisconnect || activeMachine == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(connectToMachine(activeMachine!));
  }

  Future<bool> _probePing(String baseUrl) async {
    try {
      final res = await _httpClient
          .get(Uri.parse('$baseUrl/api/ping'))
          .timeout(const Duration(milliseconds: 1400));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _manualDisconnect || activeMachine == null) return;
    phase = ConnectionPhase.connecting;
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_appInBackground) {
      // Do not churn sockets while minimized; onAppResumed() + onNetworkAvailable() will reconnect immediately.
      return;
    }

    _reconnectAttempts++;
    if (_reconnectAttempts % 3 == 0) {
      _refreshHttpClientIfOwned();
    }

    final Duration delay;
    if (reconnectDelay.inMilliseconds <= 500) {
      delay = reconnectDelay;
    } else {
      final ms = switch (_reconnectAttempts) {
        1 => 600,
        2 => 1200,
        3 => 2000,
        _ => 3000,
      };
      delay = Duration(milliseconds: ms);
    }

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      final m = activeMachine;
      if (m != null && !_manualDisconnect && !_disposed && !_appInBackground) {
        unawaited(connectToMachine(m));
      }
    });
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    ++_connectEpoch;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attemptWatchdogTimer?.cancel();
    _attemptWatchdogTimer = null;
    _networkDebounceTimer?.cancel();
    _networkDebounceTimer = null;
    _clearPendingPrompts();
    activeMachine = null;
    phase = ConnectionPhase.disconnected;
    sessions = [];
    workspaces = [];
    activeWorkspace = '';
    selectedWorkspaceFilter = '';
    activeConversationId = null;
    activeSteps = [];
    activeArtifacts = [];
    pendingApprovals = [];
    pendingChanges = [];
    pendingAttachments = [];
    pendingChangeDiffPath = null;
    pendingChangeDiffContent = '';
    notifyListeners();
    _closeSocketOnly();
  }

  /// Detaches and closes the current WebSocket non-blockingly (`0ms`) so a dead/half-open TCP socket
  /// left behind by Android sleep/UID firewall can never hang `connectToMachine` or `disconnect`.
  void _closeSocketOnly() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pongWatchdogTimer?.cancel();
    _pongWatchdogTimer = null;
    for (final item in _pendingPrompts) {
      item.ackTimer?.cancel();
      item.ackTimer = null;
      item.sentOnCurrentSocket = false;
    }
    final sub = _wsSub;
    _wsSub = null;
    final sock = _socket;
    _socket = null;
    _failPendingArtifactWaiters();
    _failPendingUploadWaiters();
    if (sub != null) {
      unawaited(
        sub
            .cancel()
            .timeout(const Duration(milliseconds: 400), onTimeout: () {})
            .catchError((_) {}),
      );
    }
    if (sock != null) {
      unawaited(
        sock
            .close()
            .timeout(const Duration(milliseconds: 400), onTimeout: () {})
            .catchError((_) {}),
      );
    }
  }

  void _clearPendingPrompts() {
    for (final item in _pendingPrompts) {
      item.ackTimer?.cancel();
      item.ackTimer = null;
    }
    _pendingPrompts.clear();
  }

  void _failPendingArtifactWaiters() {
    for (final waiters in _artifactWaiters.values) {
      for (final c in waiters) {
        if (!c.isCompleted) {
          c.complete(null);
        }
      }
    }
    _artifactWaiters.clear();
  }

  void _failPendingUploadWaiters() {
    for (final c in _uploadWaiters.values) {
      if (!c.isCompleted) {
        c.complete(null);
      }
    }
    _uploadWaiters.clear();
  }

  void _sendPing({Duration? customWatchdogTimeout}) {
    final sock = _socket;
    if (sock == null || phase != ConnectionPhase.connected) return;
    final sentAt = DateTime.now().millisecondsSinceEpoch;
    _lastPingSentMs = sentAt;
    sendRpc('client.ping', const {});

    _pongWatchdogTimer?.cancel();
    _pongWatchdogTimer = Timer(customWatchdogTimeout ?? pongTimeout, () {
      if (_disposed || _manualDisconnect || _socket != sock || phase != ConnectionPhase.connected) {
        return;
      }
      if (_lastInboundMs < sentAt) {
        // Half-open TCP stream after sleep/Wi-Fi switch — reconnect immediately!
        reconnectNow();
      }
    });
  }

  String sendRpc(String type, Map<String, dynamic> payload, {String? reqId}) {
    final resolvedReqId = reqId ?? 'f_${DateTime.now().microsecondsSinceEpoch}_${++_outboundSeq}';
    final sock = _socket;
    if (sock == null || phase != ConnectionPhase.connected) return resolvedReqId;
    final env = {
      'v': 'arp.v1',
      'type': type,
      'reqId': resolvedReqId,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    };
    try {
      sock.send(jsonEncode(env));
    } catch (_) {
      reconnectNow();
    }
    return resolvedReqId;
  }

  void _dispatchOrQueuePrompt(_PendingOutboundPrompt item) {
    if (_socket != null && phase == ConnectionPhase.connected) {
      item.sentOnCurrentSocket = true;
      final isExisting = item.conversationId != null;
      final payload = isExisting
          ? <String, dynamic>{
              'conversationId': item.conversationId,
              'prompt': item.prompt,
              if (item.workspace != null && item.workspace!.isNotEmpty)
                'workspace': item.workspace,
            }
          : <String, dynamic>{
              'prompt': item.prompt,
              if (item.workspace != null && item.workspace!.isNotEmpty)
                'workspace': item.workspace,
            };
      sendRpc(
        isExisting ? 'chat.send' : 'chat.new',
        payload,
        reqId: item.reqId,
      );
      item.ackTimer?.cancel();
      item.ackTimer = Timer(chatAckTimeout, () {
        if (!_pendingPrompts.contains(item) || _manualDisconnect || _disposed) return;
        item.sentOnCurrentSocket = false;
        reconnectNow();
      });
      return;
    }

    item.sentOnCurrentSocket = false;
    if (!_manualDisconnect && !_disposed && activeMachine != null) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - _lastAttemptStartedMs;
      if (phase == ConnectionPhase.disconnected || _reconnectTimer != null || elapsed > 2500) {
        reconnectNow();
      }
    }
  }

  void _flushPendingPrompts() {
    if (_socket == null || phase != ConnectionPhase.connected) return;
    for (final item in List<_PendingOutboundPrompt>.from(_pendingPrompts)) {
      if (!item.sentOnCurrentSocket) {
        _dispatchOrQueuePrompt(item);
      }
    }
  }

  void openSession(String conversationId) {
    activeConversationId = conversationId;
    activeSteps = [];
    activeArtifacts = [];
    notifyListeners();
    unawaited(_hydrateCachedSessionDetail(conversationId));
    sendRpc('session.detail', {'conversationId': conversationId, 'maxSteps': 250});
  }

  Future<void> _hydrateCachedSessionDetail(String conversationId) async {
    final cached = await _cache.loadSessionDetail(conversationId);
    if (cached == null) return;
    if (activeConversationId != conversationId || activeSteps.isNotEmpty) return;
    activeSteps = cached.steps;
    activeArtifacts = cached.artifacts;
    notifyListeners();
  }

  void prepareNewSession() {
    activeConversationId = null;
    activeSteps = [];
    activeArtifacts = [];
    notifyListeners();
  }

  /// Switches the active Mac workspace for Git Diff, Terminal, and new conversations (#20).
  void selectWorkspace(String path) {
    final clean = path.trim();
    if (clean.isEmpty) return;
    activeWorkspace = clean;
    workspacePath = clean;
    workspaces = workspaces
        .map(
          (w) => WorkspaceInfo(
            path: w.path,
            name: w.name,
            isDefault: w.path == clean,
            isOpenInHost: w.isOpenInHost,
            sessionCount: w.sessionCount,
          ),
        )
        .toList();
    notifyListeners();
    sendRpc('workspace.select', {'path': clean});
    sendRpc('workspace.status', {'workspace': clean});
    unawaited(_persistMachineSnapshot());
  }

  /// Interrupts the currently running agent task (`chat.stop`) (#12).
  void stopActiveSession() {
    final convId = activeConversationId ?? '';
    stoppingSession = true;
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
    activeSteps = activeSteps
        .where(
          (s) =>
              !(s.stepIndex == 999999 &&
                  (s.status == 'SENDING' || s.status == 'QUEUED')),
        )
        .toList();
    if (lastError != null && lastError!.contains('очеред')) {
      lastError = null;
    }
    unawaited(_persistMachineSnapshot());
    notifyListeners();
    sendRpc('chat.stop', {'conversationId': convId});
    _stopResetTimer?.cancel();
    _stopResetTimer = Timer(const Duration(milliseconds: 1400), () {
      if (stoppingSession) {
        stoppingSession = false;
        notifyListeners();
      }
    });
  }

  void removeAttachment(String id) {
    pendingAttachments = pendingAttachments.where((a) => a.id != id).toList();
    notifyListeners();
  }

  /// Opens the native Android picker (`image` or `file`) and uploads the selected file to Mac (#11).
  Future<bool> pickAndUploadAttachment({required String kind}) async {
    try {
      final res = await _androidChannel.invokeMethod<Map<dynamic, dynamic>>(
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
        notifyListeners();
        return false;
      }
      return await uploadAttachmentBytes(fileName: fileName, bytes: bytes, mimeType: mimeType);
    } on PlatformException catch (e) {
      lastError = e.message ?? 'Не удалось открыть выбор файла.';
      notifyListeners();
      return false;
    } catch (e) {
      lastError = 'Ошибка выбора вложения: $e';
      notifyListeners();
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
      notifyListeners();
      return false;
    }
    final isImg = mimeType.toLowerCase().startsWith('image/') || _imageExtRe.hasMatch(fileName);
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
    notifyListeners();

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
      sendRpc(
        'workspace.upload_file',
        {
          'fileName': fileName,
          'base64Data': b64,
          if (targetWs.isNotEmpty) 'workspace': targetWs,
        },
        reqId: reqId,
      );
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
    notifyListeners();
    return true;
  }

  void _removeFailedAttachment(String attId, String message) {
    pendingAttachments = pendingAttachments.where((a) => a.id != attId).toList();
    lastError = message;
    notifyListeners();
  }

  void sendPrompt(String prompt) {
    final clean = prompt.trim();
    final readyAttachments = pendingAttachments
        .where((a) => !a.uploading && a.savedPath.isNotEmpty)
        .toList();
    if (clean.isEmpty && readyAttachments.isEmpty) return;

    String composed = clean;
    if (readyAttachments.isNotEmpty) {
      final attLines = readyAttachments.map((a) {
        final kindTag = a.isImage ? 'Изображение' : 'Файл';
        return '- $kindTag `${a.fileName}`: `${a.savedPath}`';
      }).join('\n');
      final header = '[Прикреплено с телефона]\n$attLines';
      final defaultAsk = readyAttachments.every((a) => a.isImage)
          ? 'Посмотри прикреплённое изображение через read_file и помоги по нему.'
          : 'Прочитай прикреплённый файл через read_file и выполни задачу.';
      composed = clean.isEmpty ? '$header\n\n$defaultAsk' : '$header\n\n$clean';
      final consumedIds = readyAttachments.map((a) => a.id).toSet();
      pendingAttachments =
          pendingAttachments.where((a) => !consumedIds.contains(a.id)).toList();
    }

    lastError = null;
    final reqId = 'chat_${DateTime.now().microsecondsSinceEpoch}_${++_outboundSeq}';
    final targetWs = activeWorkspace.isNotEmpty ? activeWorkspace : null;

    if (activeConversationId != null) {
      _stoppedSessionStepCounts.remove(activeConversationId);
      final nextOptimisticSeq =
          activeSteps.isEmpty ? 999999 : (activeSteps.last.seq + 100000);
      activeSteps = [
        ...activeSteps,
        AgentStep(
          seq: nextOptimisticSeq,
          stepIndex: 999999,
          role: 'user',
          status: 'SENDING',
          source: 'mobile',
          thinking: '',
          content: composed,
          toolCalls: const [],
        ),
      ];
      final pending = _PendingOutboundPrompt(
        reqId: reqId,
        conversationId: activeConversationId,
        prompt: composed,
        workspace: targetWs,
        optimisticSeq: nextOptimisticSeq,
      );
      _pendingPrompts.add(pending);
      notifyListeners();
      _dispatchOrQueuePrompt(pending);
    } else {
      final pending = _PendingOutboundPrompt(
        reqId: reqId,
        conversationId: null,
        prompt: composed,
        workspace: targetWs,
        optimisticSeq: null,
      );
      _pendingPrompts.add(pending);
      notifyListeners();
      _dispatchOrQueuePrompt(pending);
    }
  }

  void retryFailedPrompt(int optimisticSeq) {
    final idx = activeSteps.indexWhere((s) => s.stepIndex == 999999 && s.seq == optimisticSeq);
    if (idx == -1) return;
    final step = activeSteps[idx];
    activeSteps = List<AgentStep>.from(activeSteps)..removeAt(idx);
    sendPrompt(step.content);
  }

  void setApprovalMode(String mode) {
    if (!validApprovalModes.contains(mode)) return;
    approvalMode = mode;
    notifyListeners();
    sendRpc('settings.set', {'approvalMode': mode});
  }

  void cycleApprovalMode() {
    final idx = validApprovalModes.indexOf(approvalMode);
    final next = validApprovalModes[(idx + 1) % validApprovalModes.length];
    setApprovalMode(next);
  }

  void decideApproval(String id, String decision) {
    sendRpc('approval.decide', {'id': id, 'decision': decision});
    pendingApprovals.removeWhere((a) => a.id == id);
    notifyListeners();
  }

  void decideAllApprovals(String decision) {
    if (pendingApprovals.isEmpty) return;
    final ids = pendingApprovals.map((a) => a.id).toList();
    sendRpc('approval.decide_batch', {'ids': ids, 'decision': decision});
    pendingApprovals = [];
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
  }

  void requestPendingChangeDiff(String path) {
    if (pendingChangeDiffPath == path) {
      pendingChangeDiffPath = null;
      pendingChangeDiffContent = '';
      notifyListeners();
      return;
    }
    pendingChangeDiffPath = path;
    pendingChangeDiffContent = 'Загрузка diff…';
    notifyListeners();
    sendRpc('changes.diff', {'path': path});
  }

  void requestFileDiff(String path) {
    selectedDiffPath = path;
    selectedDiffContent = 'Загрузка diff…';
    notifyListeners();
    sendRpc('workspace.diff', {'path': path});
  }

  void runQuickCommand(String cmd) {
    final clean = cmd.trim();
    if (clean.isEmpty) return;
    terminalBusy = true;
    terminalOutput = '\$ $clean\nВыполнение…';
    notifyListeners();
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
    // Fallback FIFO if server omitted fileName (e.g. null artifact)
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
      if (s.stepIndex == 999999 &&
          !updated &&
          (optimisticSeq == null || s.seq == optimisticSeq)) {
        updated = true;
        return AgentStep(
          seq: s.seq,
          stepIndex: s.stepIndex,
          role: s.role,
          status: nextStatus,
          source: s.source,
          thinking: s.thinking,
          content: s.content,
          toolCalls: s.toolCalls,
        );
      }
      return s;
    }).toList();
  }

  _PendingOutboundPrompt? _consumeMatchingPendingPrompt(String? reqId, String? convId) {
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

  void _onSocketMessage(dynamic raw) {
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
        notifyListeners();
        break;

      case 'server.pong':
        if (_lastPingSentMs > 0) {
          latencyMs = DateTime.now().millisecondsSinceEpoch - _lastPingSentMs;
          notifyListeners();
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
          notifyListeners();
        }
        break;

      case 'workspaces.list.result':
      case 'workspace.selected':
        _applyWorkspacesPayload(p);
        unawaited(_persistMachineSnapshot());
        notifyListeners();
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
        notifyListeners();
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
            final pendingOptimistic =
                activeSteps.where((s) => s.stepIndex == 999999).toList();
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
          notifyListeners();
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
            final pendingOptimistic =
                activeSteps.where((s) => s.stepIndex == 999999).toList();
            final bySeq = <int, AgentStep>{
              for (final s in activeSteps)
                if (s.stepIndex != 999999) s.seq: s,
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
          notifyListeners();
        } else if (p['summary'] is Map) {
          notifyListeners();
        }
        break;

      case 'session.artifact.result':
        final art = p['artifact'];
        if (art is Map) {
          _resolveArtifactWaiter(
            art['fileName']?.toString(),
            (art['content'] ?? '').toString(),
          );
        } else {
          _resolveArtifactWaiter(null, null);
        }
        break;

      case 'chat.send.result':
        final newId = p['conversationId']?.toString();
        final flushedFromQueue = p['flushedFromQueue'] == true;
        final matchedPrompt =
            flushedFromQueue ? null : _consumeMatchingPendingPrompt(reqId, newId);
        if (p['ok'] == false) {
          _updateOptimisticStepStatus(matchedPrompt?.optimisticSeq, 'FAILED');
          lastError = (p['error'] ?? 'Не удалось доставить сообщение в Antigravity').toString();
          notifyListeners();
          break;
        }
        if (p['delivery'] == 'queued') {
          _updateOptimisticStepStatus(matchedPrompt?.optimisticSeq, 'QUEUED');
          lastError = 'Окно Antigravity пробуждается — сообщение в очереди на доставку.';
          notifyListeners();
        } else {
          if (flushedFromQueue && (newId == null || newId == activeConversationId)) {
            activeSteps = activeSteps
                .map(
                  (s) => s.stepIndex == 999999 && s.status == 'QUEUED'
                      ? AgentStep(
                          seq: s.seq,
                          stepIndex: s.stepIndex,
                          role: s.role,
                          status: 'SENT',
                          source: s.source,
                          thinking: s.thinking,
                          content: s.content,
                          toolCalls: s.toolCalls,
                        )
                      : s,
                )
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
          notifyListeners();
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
        notifyListeners();
        break;

      case 'approval.resolved':
        final rid = p['id']?.toString();
        pendingApprovals.removeWhere((a) => a.id == rid);
        notifyListeners();
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
          notifyListeners();
        }
        break;

      case 'changes.diff.result':
        final diffPath = (p['path'] ?? '').toString();
        if (pendingChangeDiffPath == null || pendingChangeDiffPath == diffPath) {
          pendingChangeDiffPath = diffPath;
          pendingChangeDiffContent = (p['diff'] ?? '').toString();
          notifyListeners();
        }
        break;

      case 'settings.updated':
        if (p['approvalMode'] != null) {
          approvalMode = p['approvalMode'].toString();
          notifyListeners();
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
        notifyListeners();
        break;

      case 'workspace.diff.result':
        selectedDiffPath = (p['path'] ?? '').toString();
        selectedDiffContent = (p['diff'] ?? '').toString();
        notifyListeners();
        break;

      case 'terminal.exec.result':
        terminalBusy = false;
        final cmd = (p['command'] ?? '').toString();
        final out = (p['output'] ?? '').toString();
        final code = p['exitCode'] ?? 0;
        final dur = p['durationMs'] ?? 0;
        terminalOutput = '\$ $cmd\n${out.isEmpty ? '(пусто)' : out}\n\n[exit $code • ${dur}ms]';
        notifyListeners();
        break;

      case 'error':
        terminalBusy = false;
        if (reqId != null && _uploadWaiters.containsKey(reqId)) {
          final waiter = _uploadWaiters.remove(reqId)!;
          if (!waiter.isCompleted) waiter.complete(null);
        }
        lastError = (p['message'] ?? 'Ошибка запроса').toString();
        notifyListeners();
        break;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _manualDisconnect = true;
    ++_connectEpoch;
    _reconnectTimer?.cancel();
    _attemptWatchdogTimer?.cancel();
    _networkDebounceTimer?.cancel();
    _stopResetTimer?.cancel();
    _clearPendingPrompts();
    _closeSocketOnly();
    if (!kIsWeb) {
      try {
        if (!Platform.environment.containsKey('FLUTTER_TEST')) {
          _androidChannel.setMethodCallHandler(null);
        }
      } catch (_) {}
    }
    if (_ownsHttpClient) {
      try {
        _httpClient.close();
      } catch (_) {}
    }
    super.dispose();
  }
}
