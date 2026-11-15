import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antigravity_remote/models/remote_models.dart';
import 'package:antigravity_remote/services/bridge_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeRpcSocketTransport implements RpcSocketTransport {
  final Uri uri;
  final StreamController<dynamic> incoming = StreamController<dynamic>.broadcast();
  final List<Map<String, dynamic>> sentEnvelopes = [];
  final Future<void>? customReady;
  final Future<void>? customClose;
  bool closed = false;

  FakeRpcSocketTransport(this.uri, {this.customReady, this.customClose});

  @override
  Future<void> get ready => customReady ?? Future<void>.value();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  void send(String data) {
    sentEnvelopes.add(jsonDecode(data) as Map<String, dynamic>);
  }

  void emitServer(String type, Map<String, dynamic> payload) {
    incoming.add(
      jsonEncode({
        'v': 'arp.v1',
        'type': type,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'payload': payload,
      }),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
    if (customClose != null) {
      await customClose;
      return;
    }
    await incoming.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('init loads persisted machines, handles corrupt prefs, and removeMachine disconnects', () async {
    SharedPreferences.setMockInitialValues({
      'agy_remote_saved_machines_v1': '{corrupt_json',
    });
    final c1 = BridgeController();
    await c1.init();
    expect(c1.savedMachines, isEmpty);
    c1.dispose();

    const saved = SavedMachine(
      machineId: 'mach_saved',
      machineName: 'Mac.local',
      lanUrl: 'http://192.168.1.7:7443',
      cloudflareUrl: '',
      sessionId: 'mach_saved',
      deviceToken: 'tok_saved',
      lastConnectedAtMs: 1000,
    );
    SharedPreferences.setMockInitialValues({
      'agy_remote_saved_machines_v1': jsonEncode([saved.toJson()]),
    });

    FakeRpcSocketTransport? sock;
    final mockHttp = MockClient((req) async => http.Response('{"ok":true}', 200));
    final ctrl = BridgeController(
      httpClient: mockHttp,
      socketFactory: (uri) => sock = FakeRpcSocketTransport(uri),
    );
    await ctrl.init();
    expect(ctrl.savedMachines.length, 1);

    await ctrl.connectToMachine(ctrl.savedMachines.first);
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(sock, isNotNull);

    await ctrl.removeMachine('mach_saved');
    expect(ctrl.savedMachines, isEmpty);
    expect(ctrl.phase, ConnectionPhase.disconnected);
    expect(sock!.closed, isTrue);
    ctrl.dispose();
  });

  test('pairFromQrUrl, Cloudflare failover, auto-reconnect, and full ARP v1 RPC lifecycle', () async {
    SharedPreferences.setMockInitialValues({});
    var lanPingOk = true;
    final createdSockets = <FakeRpcSocketTransport>[];

    final mockHttp = MockClient((req) async {
      if (req.url.path == '/api/ping') {
        return lanPingOk ? http.Response('{"ok":true}', 200) : http.Response('offline', 503);
      }
      if (req.url.path == '/api/pair') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['pin'] == '000000') {
          return http.Response(jsonEncode({'ok': false, 'error': 'Invalid PIN'}), 401);
        }
        final isEdge = req.url.host.contains('workers.dev');
        return http.Response(
          jsonEncode({
            'ok': true,
            'machineId': 'mach_99',
            'machineName': 'StudioMac.local',
            'deviceToken': isEdge ? 'edge.tok.sig' : 'dev_lan_tok',
            'lanIp': '192.168.1.50',
            'port': 7443,
            'cloudflareUrl': 'https://agy.example.workers.dev',
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final ctrl = BridgeController(
      httpClient: mockHttp,
      socketFactory: (uri) {
        final s = FakeRpcSocketTransport(uri);
        createdSockets.add(s);
        return s;
      },
      reconnectDelay: const Duration(milliseconds: 40),
    );
    await ctrl.init();

    // 1. Invalid QR URL & failed PIN pairing
    expect(await ctrl.pairFromQrUrl('not-a-qr'), isFalse);
    expect(ctrl.lastError, contains('QR'));

    expect(
      await ctrl.pairWithEndpoint(baseUrl: 'http://192.168.1.50:7443', pin: '000 000'),
      isFalse,
    );
    expect(ctrl.lastError, 'Invalid PIN');

    // 2. Successful QR pairing over LAN
    final paired = await ctrl.pairFromQrUrl(
      'http://192.168.1.50:7443/pair?t=qr_tok_1&m=mach_99&cf=https%3A%2F%2Fagy.example.workers.dev',
    );
    expect(paired, isTrue);
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(ctrl.activeTransport, 'LAN');

    final sock = createdSockets.last;
    expect(sock.sentEnvelopes.map((e) => e['type']), containsAll(['client.ping', 'sessions.list', 'workspace.status']));

    // 3. Incoming server.hello, server.pong, sessions, steps_delta, concurrent artifacts, approvals, git, terminal
    sock.emitServer('server.hello', {
      'approvalMode': 'ask-mobile',
      'sessions': [
        {
          'id': 'conv_1',
          'title': 'Initial Session',
          'status': 'working',
          'stepCount': 2,
          'lastActivity': 'Read file',
          'artifactCount': 1,
          'updatedAtMs': 1700000000000,
        },
      ],
      'pendingApprovals': [
        {
          'id': 'apr_1',
          'conversationId': 'conv_1',
          'toolName': 'run_command',
          'summary': 'Run tests',
          'args': {'CommandLine': 'npm test'},
          'cwd': '/repo',
        },
      ],
    });
    sock.emitServer('server.pong', {});
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.sessions.length, 1);
    expect(ctrl.pendingApprovals.length, 1);
    expect(ctrl.latencyMs, isNotNull);

    // Open session & receive detail
    ctrl.openSession('conv_1');
    sock.emitServer('session.detail.result', {
      'detail': {
        'summary': {'id': 'conv_1', 'title': 'Initial Session'},
        'steps': [
          {'stepIndex': 0, 'role': 'user', 'content': 'Hi'},
        ],
        'artifacts': [
          {'fileName': 'plan.md', 'sizeBytes': 120},
          {'fileName': 'notes.md', 'sizeBytes': 80},
        ],
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.activeSteps.length, 1);
    expect(ctrl.activeArtifacts.length, 2);

    // Send prompt to existing session -> optimistic step 999999 -> replaced by session.steps_delta
    ctrl.sendPrompt('Run refactor');
    expect(ctrl.activeSteps.last.stepIndex, 999999);
    sock.emitServer('session.steps_delta', {
      'conversationId': 'conv_1',
      'steps': [
        {'stepIndex': 1, 'role': 'user', 'content': 'Run refactor'},
        {'stepIndex': 2, 'role': 'assistant', 'content': 'Refactoring complete!'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.activeSteps.map((s) => s.stepIndex).toList(), [0, 1, 2]);

    // Concurrent artifact fetches resolved out-of-order by fileName!
    final futPlan = ctrl.fetchArtifactMarkdown('plan.md');
    final futNotes = ctrl.fetchArtifactMarkdown('notes.md');
    sock.emitServer('session.artifact.result', {
      'artifact': {'fileName': 'notes.md', 'content': '# Notes'},
    });
    sock.emitServer('session.artifact.result', {
      'artifact': {'fileName': 'plan.md', 'content': '# Plan'},
    });
    expect(await futNotes, '# Notes');
    expect(await futPlan, '# Plan');

    // Prepare new session + chat.new -> chat.send.result auto-opens new conversationId
    ctrl.prepareNewSession();
    expect(ctrl.activeConversationId, isNull);
    ctrl.sendPrompt('Brand new task');
    expect(sock.sentEnvelopes.last['type'], 'chat.new');
    sock.emitServer('chat.send.result', {'conversationId': 'conv_2'});
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.activeConversationId, 'conv_2');

    // Approvals & modes
    ctrl.decideApproval('apr_1', 'allow');
    expect(ctrl.pendingApprovals, isEmpty);
    sock.emitServer('approval.requested', {'id': 'apr_2', 'toolName': 'edit_file'});
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.pendingApprovals.length, 1);
    sock.emitServer('approval.resolved', {'id': 'apr_2'});
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.pendingApprovals, isEmpty);

    ctrl.setApprovalMode('invalid-mode');
    expect(ctrl.approvalMode, 'ask-mobile');
    ctrl.cycleApprovalMode();
    expect(ctrl.approvalMode, 'auto-safe');
    sock.emitServer('settings.updated', {'approvalMode': 'observe'});
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.approvalMode, 'observe');

    // Workspace status, diff, terminal, and error envelope
    sock.emitServer('workspace.status.result', {
      'branch': 'feat/ui',
      'workspace': '/repo',
      'files': [
        {'status': 'M', 'path': 'lib/main.dart'},
      ],
    });
    ctrl.requestFileDiff('lib/main.dart');
    sock.emitServer('workspace.diff.result', {'path': 'lib/main.dart', 'diff': '+new line'});
    ctrl.runQuickCommand('npm test');
    expect(ctrl.terminalBusy, isTrue);
    sock.emitServer('terminal.exec.result', {
      'command': 'npm test',
      'output': 'PASS',
      'exitCode': 0,
      'durationMs': 120,
    });
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.gitBranch, 'feat/ui');
    expect(ctrl.selectedDiffContent, '+new line');
    expect(ctrl.terminalBusy, isFalse);
    expect(ctrl.terminalOutput, contains('PASS'));

    sock.emitServer('error', {'message': 'Command failed'});
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.lastError, 'Command failed');

    // 4. Smart Auto-Failover to Cloudflare Edge when LAN /api/ping fails!
    lanPingOk = false;
    final edgeMachine = SavedMachine(
      machineId: 'mach_cf',
      machineName: 'RemoteMac',
      lanUrl: 'http://192.168.1.50:7443',
      cloudflareUrl: 'https://agy.example.workers.dev',
      sessionId: 'mach_cf',
      deviceToken: 'lan_tok',
      edgeDeviceToken: 'edge_tok',
      lastConnectedAtMs: 1000,
    );
    await ctrl.connectToMachine(edgeMachine);
    expect(ctrl.activeTransport, 'CF EDGE');
    expect(createdSockets.last.uri.toString(), contains('wss://agy.example.workers.dev/ws'));

    // Unexpected socket close triggers auto-reconnect; pending artifact waiter completes cleanly with null on disconnect
    ctrl.openSession('conv_cf');
    final pendingArt = ctrl.fetchArtifactMarkdown('hanging.md');
    await createdSockets.last.close();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(createdSockets.length, greaterThanOrEqualTo(3));

    await ctrl.disconnect();
    expect(await pendingArt, isNull);

    // Machine with no tokens sets error cleanly
    await ctrl.connectToMachine(
      const SavedMachine(
        machineId: 'empty',
        machineName: 'NoTok',
        lanUrl: '',
        cloudflareUrl: '',
        sessionId: '',
        deviceToken: '',
        lastConnectedAtMs: 0,
      ),
    );
    expect(ctrl.phase, ConnectionPhase.disconnected);
    expect(ctrl.lastError, isNotNull);

    ctrl.dispose();
  });

  test('handles socket.ready timeout gracefully, preserves monotonic seq ordering on stepIndex reset, and syncs live artifacts', () async {
    SharedPreferences.setMockInitialValues({});
    var failHandshake = true;
    FakeRpcSocketTransport? activeSock;

    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (uri) {
        if (failHandshake) {
          return FakeRpcSocketTransport(
            uri,
            customReady: Future<void>.error(Exception('SocketException: Connection timed out')),
          );
        }
        return activeSock = FakeRpcSocketTransport(uri);
      },
      reconnectDelay: const Duration(milliseconds: 500),
    );
    await ctrl.init();

    const machine = SavedMachine(
      machineId: 'mach_seq',
      machineName: 'MacBook-Pro.local',
      lanUrl: 'http://192.168.1.48:7443',
      cloudflareUrl: '',
      sessionId: 'mach_seq',
      deviceToken: 'tok_seq',
      lastConnectedAtMs: 1700000000000,
    );

    // 1. Handshake timeout does NOT throw unhandled WebSocketChannelException
    await ctrl.connectToMachine(machine);
    expect(ctrl.phase, isNot(ConnectionPhase.connected));
    expect(ctrl.lastError, contains('Ошибка WebSocket'));

    // 2. Subsequent connect succeeds cleanly
    failHandshake = false;
    await ctrl.connectToMachine(machine);
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(activeSock, isNotNull);

    ctrl.openSession('conv_big');
    activeSock!.emitServer('session.detail.result', {
      'detail': {
        'summary': {'id': 'conv_big', 'title': 'Wave 4 Plan'},
        'steps': [
          {
            'seq': 7390,
            'stepIndex': 6832,
            'role': 'assistant',
            'content': 'Полный план из 17 715 байт без обрезки середины.',
          },
        ],
        'artifacts': const <Map<String, dynamic>>[],
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.activeSteps.single.stepIndex, 6832);

    // 3. Optimistic mobile prompt -> SYSTEM_MESSAGE arrives with reset stepIndex (5911) but higher seq (7391)
    ctrl.sendPrompt('отлично!!! делаем всё!!!!');
    expect(ctrl.activeSteps.length, 2);
    expect(ctrl.activeSteps.last.stepIndex, 999999);

    activeSock!.emitServer('session.steps_delta', {
      'conversationId': 'conv_big',
      'steps': [
        {
          'seq': 7391,
          'stepIndex': 5911,
          'role': 'user',
          'source': 'mobile',
          'content': 'отлично!!! делаем всё!!!!',
        },
        {
          'seq': 7392,
          'stepIndex': 5912,
          'role': 'assistant',
          'content': 'Принято, начинаю выполнение плана!',
          'toolCalls': [
            {
              'name': 'write_file',
              'summary': 'Create wave4_plan.md',
              'artifactFileName': 'wave4_plan.md',
              'artifactSummary': 'Wave 4 upgrade plan',
            },
          ],
        },
      ],
      'artifacts': [
        {'fileName': 'wave4_plan.md', 'sizeBytes': 17715},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    // Monotonic seq preserves [6832, 5911, 5912] chronological order and removes optimistic 999999!
    expect(ctrl.activeSteps.map((s) => s.stepIndex).toList(), [6832, 5911, 5912]);
    expect(ctrl.activeSteps[1].source, 'mobile');
    expect(ctrl.activeArtifacts.map((a) => a.fileName).toList(), ['wave4_plan.md']);

    // 4. chat.send.result delivery error surfaces in lastError
    activeSock!.emitServer('chat.send.result', {
      'ok': false,
      'conversationId': 'conv_big',
      'error': 'Host window closed',
    });
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.lastError, contains('Host window closed'));

    ctrl.dispose();
  });

  test('queues outbound prompt during reconnect / half-open socket, flushes on connect, updates SENDING->SENT, and reconnects on pong timeout', () async {
    SharedPreferences.setMockInitialValues({});
    final sockets = <FakeRpcSocketTransport>[];

    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (uri) {
        final s = FakeRpcSocketTransport(uri);
        sockets.add(s);
        return s;
      },
      reconnectDelay: const Duration(milliseconds: 25),
      pingInterval: const Duration(seconds: 60),
      pongTimeout: const Duration(milliseconds: 45),
      chatAckTimeout: const Duration(milliseconds: 60),
    );
    await ctrl.init();

    const machine = SavedMachine(
      machineId: 'mach_mobile',
      machineName: 'MacBook-Pro',
      lanUrl: 'http://192.168.1.7:7443',
      cloudflareUrl: '',
      sessionId: 'mach_mobile',
      deviceToken: 'tok_mobile',
      lastConnectedAtMs: 1700000000000,
    );

    await ctrl.connectToMachine(machine);
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(sockets.length, 1);
    sockets.last.emitServer('server.pong', {});
    await Future<void>.delayed(Duration.zero);

    ctrl.openSession('conv_mob');
    sockets.last.emitServer('session.detail.result', {
      'detail': {
        'summary': {'id': 'conv_mob', 'title': 'Mobile Sync'},
        'steps': [
          {'seq': 1, 'stepIndex': 0, 'role': 'user', 'content': 'Первое сообщение'},
        ],
        'artifacts': const <Map<String, dynamic>>[],
      },
    });
    await Future<void>.delayed(Duration.zero);

    // 1. Simulate dead half-open socket (`CLOSE_WAIT` after Android sleep):
    // sendPrompt writes to dead socket[0], gets NO chat.send.result within chatAckTimeout (60ms),
    // automatically reconnects to socket[1], and flushes chat.send on socket[1]!
    ctrl.sendPrompt('Сообщение после сна экрана');
    expect(ctrl.activeSteps.last.stepIndex, 999999);
    expect(ctrl.activeSteps.last.status, 'SENDING');

    await Future<void>.delayed(const Duration(milliseconds: 110));
    expect(sockets.length, greaterThanOrEqualTo(2));
    final liveSock = sockets.last;
    liveSock.emitServer('server.pong', {});

    // Verify chat.send was automatically resent on the fresh socket!
    final resentChat = liveSock.sentEnvelopes.where((e) => e['type'] == 'chat.send').toList();
    expect(resentChat, isNotEmpty);
    expect((resentChat.last['payload'] as Map)['prompt'], 'Сообщение после сна экрана');

    // Reconnect session.detail.result before transcript flush MUST NOT wipe out optimistic bubble!
    liveSock.emitServer('session.detail.result', {
      'detail': {
        'summary': {'id': 'conv_mob', 'title': 'Mobile Sync'},
        'steps': [
          {'seq': 1, 'stepIndex': 0, 'role': 'user', 'content': 'Первое сообщение'},
        ],
        'artifacts': const <Map<String, dynamic>>[],
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.activeSteps.any((s) => s.stepIndex == 999999), isTrue);

    // Server confirms agentapi delivery -> status immediately transitions SENDING -> SENT ('Доставлено')!
    liveSock.incoming.add(
      jsonEncode({
        'v': 'arp.v1',
        'type': 'chat.send.result',
        'reqId': resentChat.last['reqId'],
        'ts': DateTime.now().millisecondsSinceEpoch,
        'payload': {'ok': true, 'delivery': 'agentapi', 'conversationId': 'conv_mob'},
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.activeSteps.last.status, 'SENT');

    // 2. onAppResumed() probes socket and reconnects if pong does not arrive!
    final countBeforeResume = sockets.length;
    ctrl.onAppResumed();
    // Wait for custom 1800ms resume watchdog? Also verify pongTimeout when disconnected:
    await liveSock.close();
    await Future<void>.delayed(Duration.zero);
    ctrl.onAppResumed();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sockets.length, greaterThan(countBeforeResume));
    sockets.last.emitServer('server.pong', {});
    await Future<void>.delayed(Duration.zero);

    // 3. Failed prompt marks status FAILED and retryFailedPrompt resends cleanly!
    ctrl.sendPrompt('Повторяемое сообщение');
    final failedSeq = ctrl.activeSteps.last.seq;
    sockets.last.emitServer('chat.send.result', {
      'ok': false,
      'conversationId': 'conv_mob',
      'error': 'Temporary LS error',
    });
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.activeSteps.last.status, 'FAILED');

    ctrl.retryFailedPrompt(failedSeq);
    expect(ctrl.activeSteps.last.status, 'SENDING');
    expect(
      sockets.last.sentEnvelopes.where((e) => e['type'] == 'chat.send').last['payload']['prompt'],
      'Повторяемое сообщение',
    );

    ctrl.dispose();
  });

  test('covers v1.2 enhancements: DHCP IP healing (#22), uploads (#11), Stop (#12), Workspaces (#20), Pin/Search (#21), and Offline Cache (#23)', () async {
    SharedPreferences.setMockInitialValues({});
    final sockets = <FakeRpcSocketTransport>[];
    var lanIp = '192.168.1.77';

    final mockHttp = MockClient((req) async {
      if (req.url.path == '/api/ping') {
        if (req.url.host == lanIp) {
          return http.Response(
            jsonEncode({'ok': true, 'machineId': 'mach_v12', 'machineName': 'StudioMac'}),
            200,
          );
        }
        return http.Response('unreachable', 503);
      }
      if (req.url.path == '/api/mobile/upload') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final name = body['fileName'] as String;
        return http.Response(
          jsonEncode({
            'ok': true,
            'fileName': name,
            'savedPath': '/Users/dev/alpha/.antigravity-uploads/1700_$name',
            'relativePath': '.antigravity-uploads/1700_$name',
            'workspace': body['workspace'] ?? '/Users/dev/alpha',
            'sizeBytes': 8,
            'isImage': name.endsWith('.png'),
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final ctrl = BridgeController(
      httpClient: mockHttp,
      socketFactory: (uri) {
        final s = FakeRpcSocketTransport(uri);
        sockets.add(s);
        return s;
      },
      lanScanner: () async => [
        DiscoveredLanBridge(
          machineId: 'mach_v12',
          machineName: 'StudioMac',
          lanUrl: 'http://$lanIp:7443',
          lanIp: lanIp,
          port: 7443,
          source: 'udp',
        ),
      ],
    );
    await ctrl.init();

    // 1. Auto-IP Healing (#22): saved machine has stale DHCP IP 192.168.1.10 -> heals to 192.168.1.77!
    const staleMachine = SavedMachine(
      machineId: 'mach_v12',
      machineName: 'StudioMac',
      lanUrl: 'http://192.168.1.10:7443',
      cloudflareUrl: '',
      sessionId: 'mach_v12',
      deviceToken: 'tok_v12',
      lastConnectedAtMs: 1700000000000,
    );
    ctrl.savedMachines = [staleMachine];
    await ctrl.connectToMachine(staleMachine);
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(ctrl.activeMachine!.lanUrl, 'http://192.168.1.77:7443');
    expect(ctrl.savedMachines.first.lanUrl, 'http://192.168.1.77:7443');

    final sock = sockets.last;
    sock.emitServer('server.hello', {
      'approvalMode': 'ask-mobile',
      'activeWorkspace': '/Users/dev/alpha',
      'workspaces': [
        {'path': '/Users/dev/alpha', 'name': 'alpha', 'isDefault': true, 'isOpenInHost': true, 'sessionCount': 1},
        {'path': '/Users/dev/beta', 'name': 'beta', 'isDefault': false, 'isOpenInHost': true, 'sessionCount': 1},
      ],
      'sessions': [
        {
          'id': 'conv_old_pinned',
          'title': 'Старая важная сессия',
          'status': 'idle',
          'stepCount': 4,
          'lastActivity': 'Готово',
          'artifactCount': 1,
          'updatedAtMs': 1700000001000,
          'workspaceHint': '/Users/dev/alpha',
          'workspaceName': 'alpha',
        },
        {
          'id': 'conv_new_work',
          'title': 'Новая активная задача',
          'status': 'working',
          'stepCount': 8,
          'lastActivity': 'Run build',
          'artifactCount': 0,
          'updatedAtMs': 1700000999000,
          'workspaceHint': '/Users/dev/beta',
          'workspaceName': 'beta',
        },
      ],
      'pendingApprovals': [
        {
          'id': 'apr_stop_test',
          'conversationId': 'conv_new_work',
          'toolName': 'run_command',
          'summary': 'sleep 60',
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);

    // 2. Pinning, Workspace Filter & Cached Step Search (#21)
    await ctrl.togglePinSession('conv_old_pinned');
    expect(ctrl.isSessionPinned('conv_old_pinned'), isTrue);
    final sorted = ctrl.filterAndSortSessions();
    expect(sorted.first.id, 'conv_old_pinned'); // pinned rises above newer session!

    ctrl.setWorkspaceFilter('beta');
    expect(ctrl.filterAndSortSessions().map((s) => s.id).toList(), ['conv_new_work']);
    ctrl.setWorkspaceFilter('');

    // Open conv_old_pinned, populate steps + artifact so OfflineCacheService indexes & persists them (#23)
    ctrl.openSession('conv_old_pinned');
    sock.emitServer('session.detail.result', {
      'detail': {
        'summary': {'id': 'conv_old_pinned', 'title': 'Старая важная сессия'},
        'steps': [
          {'seq': 1, 'stepIndex': 0, 'role': 'user', 'content': 'СекретныйКлючПоискаВШаге'},
        ],
        'artifacts': [
          {'fileName': 'architecture.md', 'sizeBytes': 64},
        ],
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Search finds session by text inside cached step!
    expect(
      ctrl.filterAndSortSessions(query: 'секретныйключпоиска').map((s) => s.id).toList(),
      ['conv_old_pinned'],
    );

    final artFetch = ctrl.fetchArtifactMarkdown('architecture.md');
    sock.emitServer('session.artifact.result', {
      'artifact': {'fileName': 'architecture.md', 'content': '# Offline Architecture Plan'},
    });
    expect(await artFetch, '# Offline Architecture Plan');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 3. Stop Agent (#12)
    ctrl.openSession('conv_new_work');
    ctrl.stopActiveSession();
    expect(sock.sentEnvelopes.any((e) => e['type'] == 'chat.stop'), isTrue);
    expect(ctrl.pendingApprovals, isEmpty);
    expect(ctrl.sessions.firstWhere((s) => s.id == 'conv_new_work').status, 'idle');

    // 4. Workspace Switcher (#20) + Photo Upload (#11)
    ctrl.selectWorkspace('/Users/dev/beta');
    expect(ctrl.activeWorkspaceName, 'beta');
    expect(sock.sentEnvelopes.any((e) => e['type'] == 'workspace.select'), isTrue);

    final uploadedOk = await ctrl.uploadAttachmentBytes(
      fileName: 'bug.png',
      bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      mimeType: 'image/png',
    );
    expect(uploadedOk, isTrue);
    expect(ctrl.pendingAttachments.length, 1);
    expect(ctrl.pendingAttachments.first.isImage, isTrue);

    ctrl.prepareNewSession();
    ctrl.sendPrompt('Исправь этот баг на скриншоте');
    expect(ctrl.pendingAttachments, isEmpty);
    final newChatEnv = sock.sentEnvelopes.lastWhere((e) => e['type'] == 'chat.new');
    expect(newChatEnv['payload']['workspace'], '/Users/dev/beta');
    expect(newChatEnv['payload']['prompt'], contains('.antigravity-uploads/1700_bug.png'));
    expect(newChatEnv['payload']['prompt'], contains('Исправь этот баг на скриншоте'));

    ctrl.dispose();

    // 5. Cold Offline Launch (#23): create brand-new controller while completely offline!
    final offlineCtrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('offline', 503)),
      socketFactory: (uri) => FakeRpcSocketTransport(
        uri,
        customReady: Future<void>.error(Exception('Network unreachable')),
      ),
      reconnectDelay: const Duration(seconds: 30),
    );
    await offlineCtrl.init();
    expect(offlineCtrl.isSessionPinned('conv_old_pinned'), isTrue);

    await offlineCtrl.connectToMachine(staleMachine);
    // Cached sessions & workspaces hydrated despite total network failure!
    expect(offlineCtrl.sessions.length, 2);
    expect(offlineCtrl.workspaces.length, 2);

    offlineCtrl.openSession('conv_old_pinned');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(offlineCtrl.activeSteps.single.content, 'СекретныйКлючПоискаВШаге');
    expect(await offlineCtrl.fetchArtifactMarkdown('architecture.md'), '# Offline Architecture Plan');

    offlineCtrl.dispose();
  });

  test('recovers immediately after long background sleep even when old socket close() and in-flight handshake are hung', () async {
    SharedPreferences.setMockInitialValues({});
    final neverEndingClose = Completer<void>();
    final stalledHandshake = Completer<void>();
    final createdSockets = <FakeRpcSocketTransport>[];
    var socketAttempt = 0;

    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (uri) {
        socketAttempt++;
        if (socketAttempt == 1) {
          // Socket #1: live initially, but its close() hangs forever (dead TCP FIN after sleep)
          final s = FakeRpcSocketTransport(uri, customClose: neverEndingClose.future);
          createdSockets.add(s);
          return s;
        }
        if (socketAttempt == 2) {
          // Socket #2: hung handshake (e.g. frozen mid-flight or started while UID network still blocked)
          final s = FakeRpcSocketTransport(
            uri,
            customReady: stalledHandshake.future,
            customClose: neverEndingClose.future,
          );
          createdSockets.add(s);
          return s;
        }
        // Socket #3+: healthy post-wake connection
        final s = FakeRpcSocketTransport(uri);
        createdSockets.add(s);
        return s;
      },
      reconnectDelay: const Duration(seconds: 30),
    );
    await ctrl.init();

    const machine = SavedMachine(
      machineId: 'mach_sleep',
      machineName: 'MacBook-Pro',
      lanUrl: 'http://192.168.1.7:7443',
      cloudflareUrl: '',
      sessionId: 'mach_sleep',
      deviceToken: 'tok_sleep',
      lastConnectedAtMs: 1700000000000,
    );

    // 1. Initial foreground connect -> Socket #1 connected
    await ctrl.connectToMachine(machine);
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(createdSockets.length, 1);

    // 2. App goes to background, and a stuck reconnect attempt (Socket #2) is in flight
    // while Socket #1's close() never completes!
    ctrl.onAppPaused();
    unawaited(ctrl.connectToMachine(machine));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(createdSockets.length, 2);
    expect(createdSockets[0].closed, isTrue);
    expect(ctrl.phase, ConnectionPhase.connecting);

    // 3. User reopens app -> onAppResumed() MUST NOT block on Socket #1 close() or bail out on Socket #2!
    ctrl.onAppResumed();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(createdSockets.length, 3);
    expect(ctrl.phase, ConnectionPhase.connected);

    // 4. Even if stalled Socket #2 later fails or resolves, stale epoch is ignored and live Socket #3 stays connected!
    stalledHandshake.completeError(Exception('Stale firewalled socket failed late'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(createdSockets.length, 3);

    // 5. Simulate OxygenOS UID unblock callback (`onNetworkAvailable`) while stuck in connecting
    await createdSockets.last.close();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(ctrl.phase, ConnectionPhase.connecting);

    ctrl.onNetworkAvailable();
    // Wait for 300ms debounce if triggered within 250ms of previous attempt, or immediate connect
    await Future<void>.delayed(const Duration(milliseconds: 340));
    expect(ctrl.phase, ConnectionPhase.connected);
    expect(createdSockets.length, greaterThanOrEqualTo(4));

    ctrl.dispose();
  });

  test('stopActiveSession latches idle status against stale working broadcasts until a new turn starts', () async {
    SharedPreferences.setMockInitialValues({});
    FakeRpcSocketTransport? sock;
    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (uri) => sock = FakeRpcSocketTransport(uri),
    );
    await ctrl.init();

    const machine = SavedMachine(
      machineId: 'mach_stop',
      machineName: 'MacBook-Pro',
      lanUrl: 'http://192.168.1.7:7443',
      cloudflareUrl: '',
      sessionId: 'mach_stop',
      deviceToken: 'tok_stop',
      lastConnectedAtMs: 1700000000000,
    );
    await ctrl.connectToMachine(machine);
    const convId = '33333333-4444-4555-8666-777777777777';

    sock!.emitServer('server.hello', {
      'sessions': [
        {
          'id': convId,
          'title': 'Тестовая сборка проекта',
          'status': 'working',
          'stepCount': 1454,
          'lastActivity': 'run_command',
          'artifactCount': 0,
          'updatedAtMs': 1700000001000,
        },
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 15));
    ctrl.openSession(convId);
    expect(ctrl.sessions.single.status, 'working');

    // User taps Stop on the phone
    ctrl.stopActiveSession();
    expect(ctrl.sessions.single.status, 'idle');
    expect(
      sock!.sentEnvelopes.any(
        (e) => e['type'] == 'chat.stop' && (e['payload'] as Map)['conversationId'] == convId,
      ),
      isTrue,
    );

    // Even if a stale in-flight `sessions.updated` or `session.detail.result` arrives with same stepCount & status='working',
    // the session MUST remain 'idle' and never bounce back!
    sock!.emitServer('sessions.updated', {
      'sessions': [
        {
          'id': convId,
          'title': 'Тестовая сборка проекта',
          'status': 'working',
          'stepCount': 1454,
          'lastActivity': 'run_command',
          'artifactCount': 0,
          'updatedAtMs': 1700000002000,
        },
      ],
    });
    sock!.emitServer('session.detail.result', {
      'detail': {
        'summary': {
          'id': convId,
          'title': 'Тестовая сборка проекта',
          'status': 'working',
          'stepCount': 1454,
          'lastActivity': 'run_command',
          'artifactCount': 0,
          'updatedAtMs': 1700000002000,
        },
        'steps': const [],
        'artifacts': const [],
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ctrl.sessions.single.status, 'idle');

    // When a genuinely new turn starts on the laptop (stepCount > 1454), status transitions cleanly to 'working'
    sock!.emitServer('sessions.updated', {
      'sessions': [
        {
          'id': convId,
          'title': 'Тестовая сборка проекта',
          'status': 'working',
          'stepCount': 1455,
          'lastActivity': 'User prompt',
          'artifactCount': 0,
          'updatedAtMs': 1700000009000,
        },
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ctrl.sessions.single.status, 'working');

    // Stop again, then verify mobile `sendPrompt` also clears the stop mask immediately
    ctrl.stopActiveSession();
    expect(ctrl.sessions.single.status, 'idle');
    ctrl.sendPrompt('новый вопрос с телефона');
    sock!.emitServer('sessions.updated', {
      'sessions': [
        {
          'id': convId,
          'title': 'Тестовая сборка проекта',
          'status': 'working',
          'stepCount': 1455,
          'lastActivity': 'User prompt',
          'artifactCount': 0,
          'updatedAtMs': 1700000010000,
        },
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ctrl.sessions.single.status, 'working');

    ctrl.dispose();
  });
}

