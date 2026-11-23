import 'package:antigravity_remote/models/remote_models.dart';
import 'package:antigravity_remote/services/rpc_transport.dart';
import 'package:antigravity_remote/theme/telemetry_theme.dart';
import 'package:antigravity_remote/widgets/chat_step_cards.dart';
import 'package:antigravity_remote/widgets/pending_changes_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairingQrPayload', () {
    test('parses full URL, fallback defaults, and rejects invalid strings', () {
      final full = PairingQrPayload.tryParse(
        'http://192.168.1.7:7443/pair?t=tok_1&m=mach_1&n=MacStudio&cf=https%3A%2F%2Fedge.workers.dev&s=sess_1',
      );
      expect(full, isNotNull);
      expect(full!.baseUrl, 'http://192.168.1.7:7443');
      expect(full.token, 'tok_1');
      expect(full.machineId, 'mach_1');
      expect(full.machineName, 'MacStudio');
      expect(full.cloudflareUrl, 'https://edge.workers.dev');
      expect(full.sessionId, 'sess_1');

      final minimal = PairingQrPayload.tryParse('https://bridge.local:8443/pair?m=m2');
      expect(minimal, isNotNull);
      expect(minimal!.machineName, 'bridge.local');
      expect(minimal.sessionId, 'm2');
      expect(minimal.looksLikePairingCode, isTrue);

      final jsonPayload = PairingQrPayload.tryParse(
        '{"baseUrl":"http://192.168.1.7:7443","token":"tok_json","machineId":"mach_j","machineName":"DevBox"}',
      );
      expect(jsonPayload, isNotNull);
      expect(jsonPayload!.baseUrl, 'http://192.168.1.7:7443');
      expect(jsonPayload.token, 'tok_json');
      expect(jsonPayload.looksLikePairingCode, isTrue);

      final unrelatedSite = PairingQrPayload.tryParse('https://example.org/docs');
      expect(unrelatedSite, isNotNull);
      expect(unrelatedSite!.looksLikePairingCode, isFalse);

      expect(PairingQrPayload.tryParse('javascript:alert(1)'), isNull);
      expect(PairingQrPayload.tryParse(''), isNull);
      expect(PairingQrPayload.tryParse('   '), isNull);
      expect(PairingQrPayload.tryParse('not_a_uri'), isNull);
      expect(PairingQrPayload.tryParse('/relative/path'), isNull);
    });
  });

  group('SavedMachine & Protocol Models', () {
    test('SavedMachine round-trips JSON and supports copyWith', () {
      const m = SavedMachine(
        machineId: 'mach_1',
        machineName: 'Mac.local',
        lanUrl: 'http://192.168.1.7:7443',
        cloudflareUrl: 'https://cf.workers.dev',
        sessionId: 'mach_1',
        deviceToken: 'dev_tok',
        edgeDeviceToken: 'edge_tok',
        lastConnectedAtMs: 1700000000000,
      );

      final copy = m.copyWith(
        machineName: 'Mac Pro',
        lanUrl: 'http://10.0.0.2:7443',
        cloudflareUrl: 'https://cf2.workers.dev',
        sessionId: 'sess_2',
        deviceToken: 'dev_2',
        edgeDeviceToken: 'edge_2',
        lastConnectedAtMs: 1700000005000,
      );
      expect(copy.machineId, 'mach_1');
      expect(copy.machineName, 'Mac Pro');
      expect(copy.lanUrl, 'http://10.0.0.2:7443');
      expect(copy.edgeDeviceToken, 'edge_2');

      final unchanged = m.copyWith();
      expect(unchanged.machineName, 'Mac.local');

      final restored = SavedMachine.fromJson(copy.toJson());
      expect(restored.machineId, 'mach_1');
      expect(restored.deviceToken, 'dev_2');
      expect(restored.lastConnectedAtMs, 1700000005000);

      final empty = SavedMachine.fromJson(const {});
      expect(empty.machineName, 'Antigravity PC');
      expect(empty.lastConnectedAtMs, 0);
    });

    test(
      'SessionSummary, AgentStep, ArtifactInfo, ApprovalRequest, and GitFileChange parse JSON',
      () {
        final s = SessionSummary.fromJson({
          'id': 'conv_1',
          'title': 'Refactor',
          'status': 'working',
          'stepCount': 12,
          'lastActivity': 'Read main.dart',
          'artifactCount': 2,
          'updatedAtMs': 123456,
        });
        expect(s.id, 'conv_1');
        expect(s.stepCount, 12);
        expect(s.artifactCount, 2);

        final step = AgentStep.fromJson({
          'seq': 42,
          'stepIndex': 3,
          'role': 'assistant',
          'source': 'mobile',
          'status': 'DONE',
          'thinking': 'Analyzing...',
          'content': 'Done!',
          'toolCalls': [
            {'name': 'run_command', 'summary': r'$ npm test'},
            'ignored_non_map',
            {
              'name': 'write_file',
              'artifactFileName': 'wave4_plan.md',
              'artifactSummary': 'Detailed plan summary',
            },
          ],
        });
        expect(step.seq, 42);
        expect(step.stepIndex, 3);
        expect(step.source, 'mobile');
        expect(step.toolCalls.length, 2);
        expect(step.toolCalls[0].summary, r'$ npm test');
        expect(step.toolCalls[1].summary, 'write_file');
        expect(step.toolCalls[1].artifactFileName, 'wave4_plan.md');
        expect(step.toolCalls[1].artifactSummary, 'Detailed plan summary');

        final art = ArtifactInfo.fromJson({'fileName': 'plan.md', 'sizeBytes': 2048});
        expect(art.fileName, 'plan.md');
        expect(art.sizeBytes, 2048);

        final aprCmd = ApprovalRequest.fromJson({
          'id': 'apr_1',
          'conversationId': 'conv_1',
          'toolName': 'run_command',
          'summary': 'Run build',
          'args': {'CommandLine': 'npm run build'},
          'cwd': '/repo',
          'expiresAt': 999999,
        });
        expect(aprCmd.commandLine, 'npm run build');
        expect(aprCmd.expiresAtMs, 999999);

        final aprPath = ApprovalRequest.fromJson({
          'id': 'apr_2',
          'toolName': 'write_file',
          'args': {'Path': '/repo/a.dart'},
        });
        expect(aprPath.commandLine, '/repo/a.dart');
        expect(aprPath.expiresAtMs, greaterThan(0));

        final gf = GitFileChange.fromJson({'status': '??', 'path': 'lib/new.dart'});
        expect(gf.status, '??');
        expect(gf.path, 'lib/new.dart');

        final pfc = PendingFileChange.fromJson({
          'path': 'lib/screens/cockpit_screen.dart',
          'status': 'MOD',
          'additions': 18,
          'deletions': 4,
          'conversationId': 'conv_1',
          'updatedAt': 1700000111,
        });
        expect(pfc.path, 'lib/screens/cockpit_screen.dart');
        expect(pfc.status, 'MOD');
        expect(pfc.additions, 18);
        expect(pfc.deletions, 4);
        expect(formatFilesCountRu(1), '1 файл');
        expect(formatFilesCountRu(3), '3 файла');
        expect(formatFilesCountRu(5), '5 файлов');
        expect(formatFilesCountRu(11), '11 файлов');
        expect(formatFilesCountRu(21), '21 файл');
      },
    );
  });

  group('TelemetryFormatters & Theme', () {
    test(
      'cleanMachineName, relativeTime, cleanActivity, and buildTelemetryTheme cover all ranges',
      () {
        expect(TelemetryFormatters.cleanMachineName('Dev-Laptop.local'), 'Dev-Laptop');
        expect(TelemetryFormatters.cleanMachineName('  .local '), 'Antigravity Mac');
        expect(TelemetryFormatters.cleanMachineName('StudioPC'), 'StudioPC');

        final now = DateTime.now().millisecondsSinceEpoch;
        expect(TelemetryFormatters.relativeTime(0), '');
        expect(TelemetryFormatters.relativeTime(now - 10 * 1000), 'только что');
        expect(TelemetryFormatters.relativeTime(now - 5 * 60 * 1000), '5 мин');
        expect(TelemetryFormatters.relativeTime(now - 3 * 3600 * 1000), '3 ч');
        expect(TelemetryFormatters.relativeTime(now - 2 * 86400 * 1000), '2 дн');
        expect(TelemetryFormatters.relativeTime(now - 25 * 86400 * 1000), isNotEmpty);

        expect(TelemetryFormatters.cleanActivity(''), 'Готов к работе');
        expect(TelemetryFormatters.cleanActivity('Idle'), 'Готов к работе');
        expect(TelemetryFormatters.cleanActivity('Replied'), 'Ответ получен');
        expect(TelemetryFormatters.cleanActivity('User prompt received'), 'Обработка запроса…');
        expect(TelemetryFormatters.cleanActivity('Edit\n  file.dart'), 'Edit file.dart');

        final theme = buildTelemetryTheme();
        expect(theme.scaffoldBackgroundColor, TelemetryColors.bgCanvas);
        expect(theme.useMaterial3, isTrue);
      },
    );

    test(
      'httpToWsBaseUrl, optimistic AgentStep helpers, WorkspaceInfo.copyWith, and buildChatTimelineEntries',
      () {
        expect(httpToWsBaseUrl('http://192.168.1.7:7443/'), 'ws://192.168.1.7:7443');
        expect(
          httpToWsBaseUrl('https://edge.example.workers.dev///'),
          'wss://edge.example.workers.dev',
        );

        const optimistic = AgentStep(
          seq: -10,
          stepIndex: AgentStep.optimisticStepIndex,
          role: 'user',
          source: 'mobile',
          status: 'QUEUED',
          thinking: '',
          content: 'Ping',
          toolCalls: [],
        );
        expect(optimistic.isOptimistic, isTrue);
        final updatedOpt = optimistic.copyWith(status: 'DONE');
        expect(updatedOpt.isOptimistic, isTrue);
        expect(updatedOpt.content, 'Ping');
        expect(updatedOpt.status, 'DONE');

        const realUserStep = AgentStep(
          seq: 0,
          stepIndex: 4,
          role: 'user',
          status: 'DONE',
          thinking: '',
          content: 'Ping',
          toolCalls: [],
        );
        expect(realUserStep.isOptimistic, isFalse);

        const ws = WorkspaceInfo(path: '/workspace/demo', name: 'demo');
        final activeWs = ws.copyWith(isDefault: true, isOpenInHost: true, sessionCount: 3);
        expect(activeWs.path, '/workspace/demo');
        expect(activeWs.isDefault, isTrue);
        expect(activeWs.isOpenInHost, isTrue);
        expect(activeWs.sessionCount, 3);

        final timeline = buildChatTimelineEntries([
          realUserStep,
          const AgentStep(
            seq: 1,
            stepIndex: 5,
            role: 'assistant',
            status: 'DONE',
            thinking: 'Step 1',
            content: '',
            toolCalls: [ToolCallInfo(name: 'read_file', summary: 'Read app.dart')],
          ),
          const AgentStep(
            seq: 2,
            stepIndex: 6,
            role: 'assistant',
            status: 'DONE',
            thinking: 'Step 2',
            content: '',
            toolCalls: [ToolCallInfo(name: 'run_command', summary: 'flutter test')],
          ),
          const AgentStep(
            seq: 3,
            stepIndex: 7,
            role: 'assistant',
            status: 'DONE',
            thinking: '',
            content: 'Final reply',
            toolCalls: [],
          ),
        ]);
        expect(timeline.length, 3);
        expect(timeline[0].isPureToolGroup, isFalse);
        expect(timeline[1].isPureToolGroup, isTrue);
        expect(timeline[1].steps.length, 2);
        expect(timeline[2].isPureToolGroup, isFalse);
      },
    );

    test('httpToWsBaseUrl, optimistic AgentStep helpers, WorkspaceInfo.copyWith, and buildChatTimelineEntries', () {
      expect(httpToWsBaseUrl('http://192.168.1.7:7443/'), 'ws://192.168.1.7:7443');
      expect(httpToWsBaseUrl('https://edge.example.workers.dev///'), 'wss://edge.example.workers.dev');

      const optimistic = AgentStep(
        seq: -10,
        stepIndex: AgentStep.optimisticStepIndex,
        role: 'user',
        source: 'mobile',
        status: 'QUEUED',
        thinking: '',
        content: 'Ping',
        toolCalls: [],
      );
      expect(optimistic.isOptimistic, isTrue);
      final updatedOpt = optimistic.copyWith(status: 'DONE');
      expect(updatedOpt.isOptimistic, isTrue);
      expect(updatedOpt.content, 'Ping');
      expect(updatedOpt.status, 'DONE');

      const realUserStep = AgentStep(
        seq: 0,
        stepIndex: 4,
        role: 'user',
        status: 'DONE',
        thinking: '',
        content: 'Ping',
        toolCalls: [],
      );
      expect(realUserStep.isOptimistic, isFalse);

      const ws = WorkspaceInfo(path: '/workspace/demo', name: 'demo');
      final activeWs = ws.copyWith(isDefault: true, isOpenInHost: true, sessionCount: 3);
      expect(activeWs.path, '/workspace/demo');
      expect(activeWs.isDefault, isTrue);
      expect(activeWs.isOpenInHost, isTrue);
      expect(activeWs.sessionCount, 3);

      final timeline = buildChatTimelineEntries([
        realUserStep,
        const AgentStep(
          seq: 1,
          stepIndex: 5,
          role: 'assistant',
          status: 'DONE',
          thinking: 'Step 1',
          content: '',
          toolCalls: [ToolCallInfo(name: 'read_file', summary: 'Read app.dart')],
        ),
        const AgentStep(
          seq: 2,
          stepIndex: 6,
          role: 'assistant',
          status: 'DONE',
          thinking: 'Step 2',
          content: '',
          toolCalls: [ToolCallInfo(name: 'run_command', summary: 'flutter test')],
        ),
        const AgentStep(
          seq: 3,
          stepIndex: 7,
          role: 'assistant',
          status: 'DONE',
          thinking: '',
          content: 'Final reply',
          toolCalls: [],
        ),
      ]);
      expect(timeline.length, 3);
      expect(timeline[0].isPureToolGroup, isFalse);
      expect(timeline[1].isPureToolGroup, isTrue);
      expect(timeline[1].steps.length, 2);
      expect(timeline[2].isPureToolGroup, isFalse);
    });
  });
}
