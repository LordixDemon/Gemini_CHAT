import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_models.dart';
import '../theme/telemetry_theme.dart';
import 'lan_discovery_service.dart';
import 'offline_cache_service.dart';
import 'rpc_transport.dart';

export 'rpc_transport.dart' show ConnectionPhase, RpcSocketTransport, WebSocketRpcTransport;

part 'bridge_controller_actions.dart';
part 'bridge_controller_inbound.dart';

class BridgeController extends ChangeNotifier {
  static const String _machinesPrefsKey = 'agy_remote_saved_machines_v1';
  static const String _chatFontScaleKey = 'agy_remote_chat_font_scale_v1';
  static const String _keepScreenOnKey = 'agy_remote_keep_screen_on_v1';
  static const String _notificationsEnabledKey = 'agy_remote_notifications_v1';
  static const String _terminalHistoryKey = 'agy_remote_terminal_history_v1';
  static const int _maxTerminalOutputChars = 28000;
  static const int _maxTerminalHistory = 15;
  static const MethodChannel _androidChannel = MethodChannel('dev.antigravity.remote/android');
  static const List<String> validApprovalModes = ['ask-mobile', 'auto-safe', 'observe'];
  static final RegExp _imageExtRe = RegExp(
    r'\.(png|jpe?g|webp|gif|heic|heif|bmp|svg)$',
    caseSensitive: false,
  );

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
  }) : _httpClient = httpClient ?? http.Client(),
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

  final ValueNotifier<bool> hasActiveMachineNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<int?> latencyNotifier = ValueNotifier<int?>(null);
  final ValueNotifier<String?> notificationOpenSessionNotifier = ValueNotifier<String?>(null);

  List<SavedMachine> savedMachines = [];
  SavedMachine? activeMachine;
  ConnectionPhase phase = ConnectionPhase.disconnected;
  String activeTransport = 'LAN'; // 'LAN' | 'CF EDGE'
  int? get latencyMs => latencyNotifier.value;
  set latencyMs(int? value) => latencyNotifier.value = value;
  String? lastError;

  List<DiscoveredLanBridge> discoveredBridges = [];
  bool scanningLan = false;
  Map<String, bool> machineLanReachable = {};
  String? connectingMachineId;
  List<PairedMobileDevice> pairedDevices = [];
  String currentDeviceId = '';

  String approvalMode = 'ask-mobile';
  List<SessionSummary> sessions = [];
  Set<String> pinnedSessionIds = <String>{};
  List<WorkspaceInfo> workspaces = [];
  String activeWorkspace = '';
  String selectedWorkspaceFilter = ''; // '' = all workspaces

  double chatFontScale = 1.0;
  bool keepScreenOn = false;
  bool notificationsEnabled = true;

  String? activeConversationId;
  List<AgentStep> activeSteps = [];
  List<ArtifactInfo> activeArtifacts = [];
  int activeMaxSteps = 250;
  int activeVisibleStepCount = 0;
  bool activeHasMoreSteps = false;
  bool loadingOlderSteps = false;
  bool loadingSessionDetail = false;
  List<ApprovalRequest> pendingApprovals = [];
  List<PendingFileChange> pendingChanges = [];
  String? pendingChangeDiffPath;
  String pendingChangeDiffContent = '';

  List<PendingAttachment> pendingAttachments = [];
  bool stoppingSession = false;

  String gitBranch = 'main';
  String workspacePath = '';
  List<GitFileChange> gitFiles = [];
  String? selectedDiffPath;
  String selectedDiffContent = '';

  String terminalOutput = '# Удалённый терминал готов к работе';
  bool terminalBusy = false;
  List<String> terminalHistory = [];

  void clearTerminalOutput() {
    terminalOutput = '# Вывод терминала очищен';
    _emitChange();
  }

  void clearError() {
    if (lastError == null) return;
    lastError = null;
    _emitChange();
  }

  Future<void> setChatFontScale(double scale) async {
    final clamped = scale.clamp(0.85, 1.25).toDouble();
    if ((chatFontScale - clamped).abs() < 0.001) return;
    chatFontScale = clamped;
    _emitChange();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_chatFontScaleKey, clamped);
  }

  Future<void> setKeepScreenOn(bool enabled) async {
    if (keepScreenOn == enabled) return;
    keepScreenOn = enabled;
    _emitChange();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnKey, enabled);
    await _invokeAndroidMethod<bool>('setKeepScreenOn', {'enabled': enabled});
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    if (notificationsEnabled == enabled) return;
    notificationsEnabled = enabled;
    _emitChange();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationsEnabledKey, enabled);
    if (enabled) {
      await _invokeAndroidMethod<bool>('requestNotificationPermission');
    } else {
      await _invokeAndroidMethod<bool>('cancelNotification');
    }
  }

  Future<bool> openExternalUrl(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) return false;
    final res = await _invokeAndroidMethod<bool>('openExternalUrl', {'url': clean});
    return res == true;
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
  final List<PendingOutboundPrompt> _pendingPrompts = [];
  final Map<String, int> _stoppedSessionStepCounts = {};
  final Set<String> _workingSessionIds = <String>{};

  void _emitChange() {
    if (_disposed) return;
    hasActiveMachineNotifier.value = activeMachine != null;
    notifyListeners();
  }

  Future<T?> _invokeAndroidMethod<T>(String method, [Map<String, dynamic>? args]) async {
    if (kIsWeb) return null;
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
      return await _androidChannel.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  void _markSessionStoppedLocally(String convId) {
    if (convId.isEmpty || convId == '*') {
      for (final s in sessions) {
        if (s.status == 'working') {
          _stoppedSessionStepCounts[s.id] = s.stepCount;
        }
      }
      sessions = sessions
          .map(
            (s) => s.status == 'working' ? s.copyWith(status: 'idle', lastActivity: 'Stopped') : s,
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
        .map((s) => s.id == convId ? s.copyWith(status: 'idle', lastActivity: 'Stopped') : s)
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
    if (incoming.isSubagent) {
      sessions = sessions.where((s) => s.id != incoming.id).toList();
      return;
    }
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
          case 'onNotificationTapped':
            final args = call.arguments is Map ? call.arguments as Map : const {};
            final convId = (args['conversationId'] ?? '').toString().trim();
            if (convId.isNotEmpty && activeMachine != null) {
              openSession(convId);
              notificationOpenSessionNotifier.value = convId;
            }
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
    _emitChange();
    await _cache.savePinnedSessions(pinnedSessionIds);
  }

  void setWorkspaceFilter(String filter) {
    if (selectedWorkspaceFilter == filter) return;
    selectedWorkspaceFilter = filter;
    _emitChange();
  }

  List<SessionSummary> filterAndSortSessions({String query = '', String statusFilter = 'all'}) {
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
    chatFontScale = (prefs.getDouble(_chatFontScaleKey) ?? 1.0).clamp(0.85, 1.25).toDouble();
    keepScreenOn = prefs.getBool(_keepScreenOnKey) ?? false;
    notificationsEnabled = prefs.getBool(_notificationsEnabledKey) ?? true;
    terminalHistory = List<String>.from(prefs.getStringList(_terminalHistoryKey) ?? const []);
    if (keepScreenOn) {
      unawaited(_invokeAndroidMethod<bool>('setKeepScreenOn', {'enabled': true}));
    }
    pinnedSessionIds = await _cache.loadPinnedSessions();
    unawaited(_cache.warmSearchIndex());
    _emitChange();
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

  /// Scans Wi-Fi via mDNS + UDP Broadcast for running Antigravity Remote Bridges.
  Future<List<DiscoveredLanBridge>> scanLanBridges({bool force = false}) async {
    if (!force && !_enableAutoLanDiscovery) return discoveredBridges;
    if (scanningLan) return discoveredBridges;
    scanningLan = true;
    _emitChange();
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
      unawaited(probeSavedMachines());
      return found;
    } finally {
      scanningLan = false;
      _emitChange();
    }
  }

  Future<void> probeSavedMachines() async {
    if (_disposed || savedMachines.isEmpty) return;
    final discoveredIds = discoveredBridges
        .map((b) => b.machineId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final next = <String, bool>{};
    await Future.wait(
      savedMachines.map((m) async {
        if (m.machineId.isEmpty) return;
        if (discoveredIds.contains(m.machineId)) {
          next[m.machineId] = true;
          return;
        }
        if (m.lanUrl.isEmpty) {
          next[m.machineId] = false;
          return;
        }
        next[m.machineId] = await _probePing(m.lanUrl);
      }),
    );
    if (_disposed) return;
    var changed = next.length != machineLanReachable.length;
    if (!changed) {
      for (final e in next.entries) {
        if (machineLanReachable[e.key] != e.value) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      machineLanReachable = next;
      _emitChange();
    }
  }

  Future<void> updateSavedMachine(
    String machineId, {
    String? machineName,
    String? lanUrl,
    String? cloudflareUrl,
  }) async {
    final idx = savedMachines.indexWhere((m) => m.machineId == machineId);
    if (idx == -1) return;
    final prev = savedMachines[idx];
    final cleanName = machineName?.trim();
    final cleanLan = lanUrl?.trim().replaceAll(RegExp(r'/+$'), '');
    final cleanCf = cloudflareUrl?.trim().replaceAll(RegExp(r'/+$'), '');
    final updated = prev.copyWith(
      machineName: (cleanName != null && cleanName.isNotEmpty) ? cleanName : prev.machineName,
      lanUrl: cleanLan ?? prev.lanUrl,
      cloudflareUrl: cleanCf ?? prev.cloudflareUrl,
    );
    savedMachines[idx] = updated;
    if (activeMachine?.machineId == machineId) {
      activeMachine = updated;
    }
    await _persistMachines();
    _emitChange();
  }

  Future<void> removeMachine(String machineId) async {
    if (activeMachine?.machineId == machineId) {
      await disconnect();
    }
    savedMachines.removeWhere((m) => m.machineId == machineId);
    machineLanReachable.remove(machineId);
    await _persistMachines();
    _emitChange();
  }

  /// Pairs using a scanned QR code URL (`http://<LAN>:7443/pair?t=...&cf=...`).
  Future<bool> pairFromQrUrl(String rawUrl, {String deviceName = 'Flutter Mobile'}) async {
    final parsed = PairingQrPayload.tryParse(rawUrl);
    if (parsed == null) {
      lastError = 'Некорректный формат QR-кода Antigravity Remote.';
      _emitChange();
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
    _emitChange();

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
        _emitChange();
        return false;
      }

      final isQuickTunnel = cleanBase.contains('trycloudflare.com');
      final isEdgeWorker = !isQuickTunnel && cleanBase.contains('workers.dev');
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
        lanUrl: (isEdgeWorker || isQuickTunnel) ? reportedLan : cleanBase,
        cloudflareUrl: (isEdgeWorker || isQuickTunnel) ? cleanBase : reportedCf,
        sessionId: (body['sessionId'] ?? machineId).toString(),
        deviceToken: isEdgeWorker ? '' : issuedToken,
        edgeDeviceToken: (isEdgeWorker || isQuickTunnel) ? issuedToken : '',
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
      _emitChange();
      return false;
    }
  }

  /// Connects to a saved machine using Epoch-Preemptive Smart Auto-Failover + Offline Cache Hydration + DHCP IP Healing.
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
    connectingMachineId = currentMachine.machineId;
    phase = ConnectionPhase.connecting;
    lastError = null;
    _emitChange();

    try {
      if (sessions.isEmpty && currentMachine.machineId.isNotEmpty) {
        try {
          final cached = await _cache
              .loadMachineSnapshot(currentMachine.machineId)
              .timeout(const Duration(milliseconds: 600));
          if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
          if (sessions.isEmpty && (cached.sessions.isNotEmpty || cached.workspaces.isNotEmpty)) {
            sessions = cached.sessions;
            workspaces = cached.workspaces;
            if (activeWorkspace.isEmpty && cached.activeWorkspace.isNotEmpty) {
              activeWorkspace = cached.activeWorkspace;
            }
            _emitChange();
          }
        } catch (_) {
          if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
        }
      }

      _closeSocketOnly();
      if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;

      String? targetWsUrl;
      String chosenTransport = 'LAN';
      final isQuickTunnel = currentMachine.cloudflareUrl.contains('trycloudflare.com');
      final lanToken = currentMachine.deviceToken.isNotEmpty
          ? currentMachine.deviceToken
          : (isQuickTunnel ? currentMachine.edgeDeviceToken : '');

      if (lanToken.isNotEmpty &&
          (currentMachine.lanUrl.isNotEmpty ||
              (_enableAutoLanDiscovery && currentMachine.machineId.isNotEmpty))) {
        var lanReachable =
            currentMachine.lanUrl.isNotEmpty ? await _probePing(currentMachine.lanUrl) : false;
        if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;

        if (!lanReachable && _enableAutoLanDiscovery && currentMachine.machineId.isNotEmpty) {
          final discovered = await _lanDiscovery.discover(
            timeout: const Duration(milliseconds: 950),
          );
          if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
          discoveredBridges = discovered;
          final match = discovered
              .where((b) => b.machineId == currentMachine.machineId)
              .cast<DiscoveredLanBridge?>()
              .firstWhere((_) => true, orElse: () => null);
          if (match != null && match.lanUrl.isNotEmpty && match.lanUrl != currentMachine.lanUrl) {
            currentMachine = currentMachine.copyWith(
              lanUrl: match.lanUrl,
              deviceToken: lanToken,
            );
            activeMachine = currentMachine;
            final sIdx = savedMachines.indexWhere((m) => m.machineId == currentMachine.machineId);
            if (sIdx != -1) {
              savedMachines[sIdx] = currentMachine;
              await _persistMachines();
              if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
            }
            lanReachable = await _probePing(currentMachine.lanUrl);
            if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
          }
        }
        if (lanReachable && currentMachine.lanUrl.isNotEmpty) {
          if (currentMachine.deviceToken.isEmpty) {
            currentMachine = currentMachine.copyWith(deviceToken: lanToken);
            activeMachine = currentMachine;
            final sIdx = savedMachines.indexWhere((m) => m.machineId == currentMachine.machineId);
            if (sIdx != -1) {
              savedMachines[sIdx] = currentMachine;
              await _persistMachines();
              if (epoch != _connectEpoch || _manualDisconnect || _disposed) return;
            }
          }
          final wsBase = httpToWsBaseUrl(currentMachine.lanUrl);
          targetWsUrl = '$wsBase/ws?token=${Uri.encodeComponent(lanToken)}';
          chosenTransport = 'LAN';
        }
      }

      if (targetWsUrl == null && currentMachine.cloudflareUrl.isNotEmpty) {
        final tok = currentMachine.edgeDeviceToken.isNotEmpty
            ? currentMachine.edgeDeviceToken
            : currentMachine.deviceToken;
        if (tok.isNotEmpty) {
          final wsBase = httpToWsBaseUrl(currentMachine.cloudflareUrl);
          targetWsUrl =
              '$wsBase/ws?token=${Uri.encodeComponent(tok)}&sessionId=${Uri.encodeComponent(currentMachine.sessionId)}';
          chosenTransport = 'CF EDGE';
        }
      }

      if (targetWsUrl == null &&
          currentMachine.lanUrl.isNotEmpty &&
          lanToken.isNotEmpty) {
        final wsBase = httpToWsBaseUrl(currentMachine.lanUrl);
        targetWsUrl = '$wsBase/ws?token=${Uri.encodeComponent(lanToken)}';
        chosenTransport = 'LAN';
      }

      if (targetWsUrl == null) {
        _attemptWatchdogTimer?.cancel();
        _attemptWatchdogTimer = null;
        connectingMachineId = null;
        lastError = 'Нет доступного токена для LAN или Cloudflare Edge.';
        phase = ConnectionPhase.disconnected;
        _emitChange();
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
        _handleSocketMessage,
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
      connectingMachineId = null;
      phase = ConnectionPhase.connected;
      _lastInboundMs = DateTime.now().millisecondsSinceEpoch;
      _sendPing();
      _pingTimer = Timer.periodic(pingInterval, (_) => _sendPing());
      sendRpc('sessions.list', const {});
      sendRpc('workspaces.list', const {});
      sendRpc('workspace.status', const {});
      sendRpc('changes.list', const {});
      if (activeConversationId != null) {
        sendRpc('session.detail', {
          'conversationId': activeConversationId,
          'maxSteps': activeMaxSteps,
        });
      }
      _flushPendingPrompts();
      _emitChange();
    } catch (e) {
      if (_disposed || _manualDisconnect || epoch != _connectEpoch) return;
      _attemptWatchdogTimer?.cancel();
      _attemptWatchdogTimer = null;
      lastError = 'Ошибка WebSocket: $e';
      _scheduleReconnect();
    }
  }

  /// Called when the app enters background (`AppLifecycleState.paused`).
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
    unawaited(_invokeAndroidMethod<bool>('cancelNotification'));
    if (keepScreenOn) {
      unawaited(_invokeAndroidMethod<bool>('setKeepScreenOn', {'enabled': true}));
    }
    final m = activeMachine;
    if (m == null) return;

    _reconnectAttempts = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pausedDurationMs = _lastPausedAtMs > 0 ? (now - _lastPausedAtMs) : 0;
    _lastPausedAtMs = 0;

    if (pausedDurationMs >= 8000 || _socket == null || phase != ConnectionPhase.connected) {
      final elapsedSinceAttempt = now - _lastAttemptStartedMs;
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

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) => _sendPing());
    final probeMs = pongTimeout.inMilliseconds < 1200 ? pongTimeout.inMilliseconds : 1200;
    _sendPing(customWatchdogTimeout: Duration(milliseconds: probeMs));
  }

  /// Triggered by Android `ConnectivityManager.NetworkCallback` when Wi-Fi/cell becomes available.
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
    _emitChange();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_appInBackground) return;

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
    connectingMachineId = null;
    pairedDevices = [];
    currentDeviceId = '';
    phase = ConnectionPhase.disconnected;
    sessions = [];
    workspaces = [];
    activeWorkspace = '';
    selectedWorkspaceFilter = '';
    activeConversationId = null;
    activeSteps = [];
    activeArtifacts = [];
    activeMaxSteps = 250;
    activeVisibleStepCount = 0;
    activeHasMoreSteps = false;
    loadingOlderSteps = false;
    loadingSessionDetail = false;
    _workingSessionIds.clear();
    latencyNotifier.value = null;
    pendingApprovals = [];
    pendingChanges = [];
    pendingAttachments = [];
    pendingChangeDiffPath = null;
    pendingChangeDiffContent = '';
    _emitChange();
    _closeSocketOnly();
  }

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
        if (!c.isCompleted) c.complete(null);
      }
    }
    _artifactWaiters.clear();
  }

  void _failPendingUploadWaiters() {
    for (final c in _uploadWaiters.values) {
      if (!c.isCompleted) c.complete(null);
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

  void _dispatchOrQueuePrompt(PendingOutboundPrompt item) {
    if (_socket != null && phase == ConnectionPhase.connected) {
      item.sentOnCurrentSocket = true;
      final isExisting = item.conversationId != null;
      final payload = isExisting
          ? <String, dynamic>{
              'conversationId': item.conversationId,
              'prompt': item.prompt,
              if (item.workspace != null && item.workspace!.isNotEmpty) 'workspace': item.workspace,
            }
          : <String, dynamic>{
              'prompt': item.prompt,
              if (item.workspace != null && item.workspace!.isNotEmpty) 'workspace': item.workspace,
            };
      sendRpc(isExisting ? 'chat.send' : 'chat.new', payload, reqId: item.reqId);
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
    for (final item in List<PendingOutboundPrompt>.from(_pendingPrompts)) {
      if (!item.sentOnCurrentSocket) {
        _dispatchOrQueuePrompt(item);
      }
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
    hasActiveMachineNotifier.dispose();
    latencyNotifier.dispose();
    notificationOpenSessionNotifier.dispose();
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
