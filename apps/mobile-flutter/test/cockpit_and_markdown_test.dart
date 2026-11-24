import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antigravity_remote/main.dart';
import 'package:antigravity_remote/models/remote_models.dart';
import 'package:antigravity_remote/services/bridge_controller.dart';
import 'package:antigravity_remote/widgets/markdown_view.dart';
import 'package:antigravity_remote/widgets/terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WidgetFakeSocket implements RpcSocketTransport {
  final StreamController<dynamic> incoming = StreamController<dynamic>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  void send(String data) {
    final env = jsonDecode(data) as Map<String, dynamic>;
    sent.add(env);
    if (env['type'] == 'session.artifact') {
      final p = env['payload'] as Map<String, dynamic>;
      incoming.add(
        jsonEncode({
          'v': 'arp.v1',
          'type': 'session.artifact.result',
          'payload': {
            'artifact': {
              'fileName': p['fileName'],
              'content': '# План рефакторинга\n- Модульная архитектура\n- 100% покрытие',
            },
          },
        }),
      );
    }
  }

  void emit(String type, Map<String, dynamic> payload) {
    incoming.add(jsonEncode({'v': 'arp.v1', 'type': type, 'payload': payload}));
  }

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('MarkdownBodyView renders headings, lists, quotes, inline chips, and copies code blocks', (tester) async {
    const md = '''
# Заголовок 1
## Подзаголовок 2
---
> Важная цитата с **жирным**, *курсивом*, `inline_code` и ссылкой [main.dart](file:///app/lib/main.dart).

- Первый пункт списка
  продолжение строки
1. Нумерованный шаг

```dart
void main() => runApp(const App());
```
''';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MarkdownBodyView(data: md)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('inline_code'), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    expect(find.textContaining('runApp'), findsOneWidget);

    await tester.tap(find.text('Копия'));
    await tester.pump();
    expect(find.text('Код скопирован'), findsOneWidget);
  });

  testWidgets('MarkdownBodyView renders GFM tables and GFM alerts', (tester) async {
    const md = '''
> [!IMPORTANT]
> Полная синхронизация планов без `<truncated>` активна.

> [!TIP]
> Нажмите карточку артефакта для встроенного просмотра.

| Компонент | Статус | Размер |
| :--- | :---: | ---: |
| BrainWatcher | Готово | 8 MiB |
| AgentDriver | IDE Hub | 100% |
''';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MarkdownBodyView(data: md)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ВАЖНО'), findsOneWidget);
    expect(find.text('СОВЕТ'), findsOneWidget);
    expect(find.textContaining('Полная синхронизация планов'), findsOneWidget);
    expect(find.text('BrainWatcher'), findsOneWidget);
    expect(find.text('IDE Hub'), findsOneWidget);
  });

  testWidgets('ConnectScreen renders saved workstations, advanced fields, error banner, and delete', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const saved = SavedMachine(
      machineId: 'm_1',
      machineName: 'MacBook-Pro.local',
      lanUrl: 'http://192.168.1.9:7443',
      cloudflareUrl: '',
      sessionId: 'm_1',
      deviceToken: 'tok_1',
      lastConnectedAtMs: 1700000000000,
    );
    SharedPreferences.setMockInitialValues({
      'agy_remote_saved_machines_v1': jsonEncode([saved.toJson()]),
    });

    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
    );
    await ctrl.init();
    ctrl.lastError = 'Тестовая ошибка сети';

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pumpAndSettle();

    expect(find.text('MacBook-Pro'), findsOneWidget);
    expect(find.text('Тестовая ошибка сети'), findsOneWidget);

    // Expand Manual PIN section -> Toggle advanced fields
    await tester.tap(find.text('По PIN'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Дополнительные параметры'));
    await tester.pumpAndSettle();
    expect(find.text('Имя этого смартфона'), findsOneWidget);

    // Edit & Delete saved workstation via card action menu
    await tester.drag(find.byType(ListView), const Offset(0, 360));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Действия'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Название'), 'MacBook Studio');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('MacBook Studio'), findsOneWidget);

    await tester.tap(find.byTooltip('Действия'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('MacBook Studio'), findsOneWidget);

    await tester.tap(find.byTooltip('Действия'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить').last);
    await tester.pumpAndSettle();
    expect(find.text('MacBook Studio'), findsNothing);

    ctrl.dispose();
  });

  testWidgets('CockpitScreen exercises Sessions, Chat, Artifacts, Approvals, Git Diff, and Terminal', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late WidgetFakeSocket sock;
    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (_) => sock = WidgetFakeSocket(),
    );
    await ctrl.init();

    await ctrl.connectToMachine(
      const SavedMachine(
        machineId: 'm_live',
        machineName: 'M4-Studio.local',
        lanUrl: 'http://192.168.1.7:7443',
        cloudflareUrl: '',
        sessionId: 'm_live',
        deviceToken: 'tok_live',
        lastConnectedAtMs: 1700000000000,
      ),
    );

    sock.emit('server.hello', {
      'approvalMode': 'ask-mobile',
      'sessions': [
        {
          'id': 'conv_alpha',
          'title': 'Рефакторинг мобильного UI',
          'status': 'working',
          'stepCount': 5,
          'lastActivity': 'Edit cockpit_screen.dart',
          'artifactCount': 1,
          'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      'pendingApprovals': [
        {
          'id': 'apr_live',
          'conversationId': 'conv_alpha',
          'toolName': 'run_command',
          'summary': 'Run flutter test',
          'args': {'CommandLine': 'flutter test --coverage'},
          'cwd': '/Users/dev/remote-app',
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 45000,
        },
      ],
    });
    sock.emit('workspace.status.result', {
      'branch': 'main',
      'workspace': '/Users/dev/remote-app',
      'files': [
        {'status': 'M', 'path': 'lib/main.dart'},
        {'status': '??', 'path': 'test/new_test.dart'},
        {'status': 'D', 'path': 'lib/old.dart'},
      ],
    });

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pump();

    // Header & Floating ApprovalGateCard
    expect(find.text('M4-Studio'), findsOneWidget);
    expect(find.text('Спросить'), findsOneWidget);
    expect(find.text('Запрос разрешения'), findsOneWidget);
    expect(find.text('flutter test --coverage'), findsOneWidget);

    // Approve tool call from floating card
    await tester.tap(find.text('Разрешить'));
    await tester.pump();
    expect(ctrl.pendingApprovals, isEmpty);
    expect(sock.sent.any((e) => e['type'] == 'approval.decide'), isTrue);

    // Switch PreToolUse Mode via Modal Bottom Sheet
    await tester.tap(find.text('Спросить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Авто-безопасный'));
    await tester.pumpAndSettle();
    expect(ctrl.approvalMode, 'auto-safe');

    // Search sessions & tap session tile -> opens Chat tab
    await tester.enterText(find.byType(TextField).first, 'несуществующий');
    await tester.pump();
    expect(find.textContaining('ничего не найдено'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    await tester.tap(find.text('Рефакторинг мобильного UI'));
    await tester.pump();

    // Hydrate chat steps + artifact
    sock.emit('session.detail.result', {
      'detail': {
        'summary': {
          'id': 'conv_alpha',
          'title': 'Рефакторинг мобильного UI',
          'status': 'working',
        },
        'steps': [
          {'stepIndex': 0, 'role': 'user', 'content': 'Обнови дизайн'},
          {
            'stepIndex': 1,
            'role': 'assistant',
            'thinking': 'Проверяю контраст и отступы',
            'content': 'Дизайн обновлён в **Obsidian Studio**!',
            'toolCalls': [
              {'name': 'edit_file', 'summary': 'Edit telemetry_theme.dart'},
              {
                'name': 'write_file',
                'summary': 'Create plan.md',
                'artifactFileName': 'plan.md',
                'artifactSummary': 'Полный план модернизации сцен',
              },
            ],
          },
        ],
        'artifacts': [
          {'fileName': 'plan.md', 'sizeBytes': 512},
        ],
      },
    });
    await tester.pump();

    expect(find.text('Обнови дизайн'), findsOneWidget);
    expect(find.text('Edit telemetry_theme.dart'), findsOneWidget);

    // Expand collapsible Thinking block
    await tester.ensureVisible(find.text('Размышление'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Размышление'));
    await tester.pumpAndSettle();
    expect(find.text('Проверяю контраст и отступы'), findsOneWidget);

    // Expand inline Artifact Plan Card directly inside chat bubble
    await tester.ensureVisible(find.text('Развернуть полный план'));
    await tester.pumpAndSettle();
    expect(find.text('Полный план модернизации сцен'), findsOneWidget);
    await tester.tap(find.text('Развернуть полный план'));
    await tester.pumpAndSettle();
    expect(find.text('План рефакторинга', findRichText: true), findsOneWidget);

    // Open Artifact modal bottom sheet via top ribbon or card button
    await tester.ensureVisible(find.text('Весь экран'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Весь экран'));
    await tester.pumpAndSettle();
    expect(find.text('План рефакторинга', findRichText: true), findsWidgets);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // Enter message & send in Chat composer
    await tester.enterText(
      find.widgetWithText(TextField, 'Добавить сообщение в очередь…'),
      '/plan обнови тесты',
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    expect(sock.sent.any((e) => e['type'] == 'chat.send'), isTrue);

    // Switch to Tab 2: Git Diff
    await tester.tap(find.text('Git Diff'));
    await tester.pump();
    expect(find.text('MOD'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('DEL'), findsOneWidget);

    await tester.tap(find.text('main.dart'));
    await tester.pump();
    sock.emit('workspace.diff.result', {
      'path': 'lib/main.dart',
      'diff': '@@ -1,2 +1,2 @@\n-oldLine\n+newLine',
    });
    await tester.pump();
    expect(find.text('+newLine'), findsOneWidget);

    // Toggle line wrap in Git Diff
    await tester.tap(find.text('Скролл'));
    await tester.pump();
    expect(find.text('Перенос'), findsOneWidget);

    // Switch to Tab 3: Terminal
    await tester.tap(find.text('Терминал'));
    await tester.pump();
    await tester.tap(find.text('git status -sb'));
    await tester.pump();
    expect(ctrl.terminalBusy, isTrue);

    sock.emit('terminal.exec.result', {
      'command': 'git status -sb',
      'output': '## main',
      'exitCode': 0,
      'durationMs': 18,
    });
    await tester.pump();
    expect(find.textContaining('## main'), findsOneWidget);

    // Copy terminal output & submit custom shell command
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    expect(find.text('Вывод терминала скопирован'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'echo ok');
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(sock.sent.last['type'], 'terminal.exec');

    ctrl.dispose();
  });

  testWidgets('Manual PIN pairing, empty states, and ApprovalGateCard deny / allow_session flows', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    late WidgetFakeSocket sock;
    final ctrl = BridgeController(
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/pair') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'machineId': 'm_pin',
              'machineName': 'PinMac',
              'deviceToken': 'tok_pin',
              'lanIp': '192.168.1.20',
              'port': 7443,
            }),
            200,
          );
        }
        return http.Response('{"ok":true}', 200);
      }),
      socketFactory: (_) => sock = WidgetFakeSocket(),
    );
    await ctrl.init();

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pumpAndSettle();

    // Fill PIN and submit manual pairing -> transitions to CockpitScreen with empty sessions & clean git tree!
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'http://192.168.1.20:7443');
    await tester.enterText(fields.at(1), '123456');
    await tester.drag(find.byType(ListView), const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Связать по PIN'));
    await tester.pumpAndSettle();

    expect(find.text('Загрузка чатов…'), findsOneWidget);
    sock.emit('sessions.list.result', {'sessions': []});
    await tester.pumpAndSettle();

    expect(find.text('Сессий пока нет'), findsOneWidget);

    // Tap "Новый" button -> switches to empty new Chat hero
    await tester.tap(find.text('Новый'));
    await tester.pump();
    expect(find.text('Запустите новую задачу'), findsOneWidget);

    // Switch to Git Diff -> shows clean tree state
    ctrl.workspacePath = '/Users/dev/clean-repo';
    await tester.tap(find.text('Git Diff'));
    await tester.pump();
    expect(find.text('Рабочее дерево чистое'), findsOneWidget);

    // Push 2 pending approvals to verify "+1" queue badge, "В сессии", and "Блок"
    sock.emit('approval.requested', {
      'id': 'apr_s1',
      'toolName': 'write_file',
      'args': {'Path': '/repo/a.dart'},
    });
    sock.emit('approval.requested', {
      'id': 'apr_s2',
      'toolName': 'other_tool',
      'summary': 'Custom action',
    });
    await tester.pump();
    expect(find.text('+1'), findsOneWidget);

    await tester.tap(find.text('В сессии'));
    await tester.pump();
    expect(ctrl.pendingApprovals.length, 1);

    await tester.tap(find.text('Блок'));
    await tester.pump();
    expect(ctrl.pendingApprovals, isEmpty);

    // Disconnect via AppBar power button (with confirmation dialog) -> returns to ConnectScreen with saved PinMac card, then reconnect via card
    await tester.tap(find.byIcon(Icons.power_settings_new_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отключиться'));
    await tester.pumpAndSettle();
    expect(ctrl.phase, ConnectionPhase.disconnected);
    expect(find.text('Войти'), findsOneWidget);

    await tester.tap(find.text('PinMac'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    expect(ctrl.phase, ConnectionPhase.connected, reason: 'lastError=${ctrl.lastError}');

    // Verify NO sticky PendingChangesBar hangs on Sessions/Chat, while Git Diff tab exposes optional review sheet!
    sock.emit('changes.updated', {
      'files': [
        {
          'path': 'lib/screens/cockpit_screen.dart',
          'status': 'MOD',
          'additions': 24,
          'deletions': 5,
          'conversationId': 'conv_1',
          'updatedAt': 1700000222,
        },
        {
          'path': 'lib/widgets/new_bar.dart',
          'status': 'NEW',
          'additions': 60,
          'deletions': 0,
          'conversationId': 'conv_1',
          'updatedAt': 1700000225,
        },
      ],
    });
    await tester.pumpAndSettle();
    expect(ctrl.pendingChanges.length, 2);
    // Must NOT hang on Sessions tab:
    expect(find.text('Сохранить всё'), findsNothing);

    // Switch to Git Diff -> unobtrusive card opens PendingChangesSheet
    await tester.tap(find.text('Git Diff'));
    await tester.pumpAndSettle();
    expect(find.text('Правки текущей задачи: 2 файла'), findsOneWidget);
    await tester.tap(find.text('Правки текущей задачи: 2 файла'));
    await tester.pumpAndSettle();
    expect(find.text('Изменённые файлы (2)'), findsOneWidget);
    expect(find.text('cockpit_screen.dart'), findsOneWidget);
    expect(find.text('new_bar.dart'), findsOneWidget);

    // Tap file row to load & display unified diff inline
    await tester.tap(find.text('cockpit_screen.dart'));
    await tester.pump();
    sock.emit('changes.diff.result', {
      'path': 'lib/screens/cockpit_screen.dart',
      'diff': '@@ -1,2 +1,2 @@\n-oldWidget\n+PendingChangesBar()',
    });
    await tester.pump();
    expect(find.text('+PendingChangesBar()'), findsOneWidget);

    // Revert single file via tooltip icon button (with confirmation dialog)
    await tester.tap(find.byTooltip('Откатить файл').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Откатить'));
    await tester.pumpAndSettle();
    expect(ctrl.pendingChanges.length, 1);
    expect(sock.sent.any((e) => e['type'] == 'changes.revert'), isTrue);

    // Tap "Сохранить всё" inside sheet -> saves remaining changes and closes sheet
    await tester.tap(find.text('Сохранить всё').last);
    await tester.pumpAndSettle();
    expect(ctrl.pendingChanges, isEmpty);
    expect(sock.sent.any((e) => e['type'] == 'changes.save_all'), isTrue);

    // Batch ApprovalGateCard ("Сохранить всё (2)" for external file queue)
    sock.emit('approval.requested', {
      'id': 'apr_b1',
      'toolName': 'write_file',
      'args': {'Path': '/etc/ext1.conf'},
    });
    sock.emit('approval.requested', {
      'id': 'apr_b2',
      'toolName': 'edit_file',
      'args': {'Path': '/etc/ext2.conf'},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Сохранить всё (2)'), findsOneWidget);
    await tester.tap(find.text('Сохранить всё (2)'));
    await tester.pump();
    expect(ctrl.pendingApprovals, isEmpty);
    expect(sock.sent.any((e) => e['type'] == 'approval.decide_batch'), isTrue);

    ctrl.dispose();
  });

  testWidgets('Opening Chat tab lands immediately on the latest messages even with 60+ long history steps', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    late WidgetFakeSocket sock;
    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (_) => sock = WidgetFakeSocket(),
    );
    await ctrl.init();

    await ctrl.connectToMachine(
      const SavedMachine(
        machineId: 'm_scroll',
        machineName: 'MacBook-Pro.local',
        lanUrl: 'http://192.168.1.7:7443',
        cloudflareUrl: '',
        sessionId: 'm_scroll',
        deviceToken: 'tok_scroll',
        lastConnectedAtMs: 1700000000000,
      ),
    );

    sock.emit('server.hello', {
      'approvalMode': 'observe',
      'sessions': [
        {
          'id': 'conv_long',
          'title': 'Большая история чата',
          'status': 'idle',
          'stepCount': 60,
          'lastActivity': 'Ответ получен',
          'artifactCount': 0,
          'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      'pendingApprovals': const <Map<String, dynamic>>[],
    });

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pump();

    // Tap bottom "Чат" tab directly -> automatically opens latest session `conv_long`
    await tester.tap(find.text('Чат'));
    await tester.pump();
    expect(ctrl.activeConversationId, 'conv_long');

    // Emit 60 tall messages asynchronously (simulating real network arrival after opening Chat)
    sock.emit('session.detail.result', {
      'detail': {
        'summary': {'id': 'conv_long', 'title': 'Большая история чата', 'status': 'idle'},
        'steps': [
          for (var i = 1; i <= 60; i++)
            {
              'seq': i,
              'stepIndex': i,
              'role': i.isOdd ? 'user' : 'assistant',
              'content': 'Сообщение номер #$i\nМногострочный текст для высоты карточки.\nСтрока 3.',
            },
        ],
        'artifacts': const <Map<String, dynamic>>[],
      },
    });
    await tester.pump();

    // Without any manual scrolling, the VERY LAST message (#60) is immediately visible on screen,
    // while message #1 is far off-screen at the top!
    expect(find.textContaining('Сообщение номер #60'), findsOneWidget);
    expect(find.textContaining('Сообщение номер #1\n'), findsNothing);

    ctrl.dispose();
  });

  testWidgets('Syntax highlighting & >28-line collapsible code blocks, LAN discovery card, Pin/Filter chips, Stop button, and Attachments UI', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 1. Test >28-line collapsible syntax-highlighted code block (#16)
    final longDartCode = List<String>.generate(
      36,
      (i) => 'final int item${i + 1} = ${(i + 1) * 10}; // line_${i + 1}',
    ).join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBodyView(data: '```dart\n$longDartCode\n```'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Развернуть все 36 строк'), findsOneWidget);
    expect(find.textContaining('line_35', findRichText: true), findsNothing);

    await tester.tap(find.text('Развернуть все 36 строк'));
    await tester.pumpAndSettle();
    expect(find.textContaining('line_35', findRichText: true), findsOneWidget);
    expect(find.text('Свернуть код'), findsOneWidget);

    // 2. Test ConnectScreen LAN auto-discovery card (#22)
    SharedPreferences.setMockInitialValues({});
    late WidgetFakeSocket sock;
    final ctrl = BridgeController(
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/mobile/upload') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'fileName': 'note.txt',
              'savedPath': '/Users/dev/remote-app/.antigravity-uploads/note.txt',
              'relativePath': '.antigravity-uploads/note.txt',
              'sizeBytes': 4,
              'isImage': false,
            }),
            200,
          );
        }
        return http.Response('{"ok":true}', 200);
      }),
      socketFactory: (_) => sock = WidgetFakeSocket(),
      lanScanner: () async => const [
        DiscoveredLanBridge(
          machineId: 'mach_lan_1',
          machineName: 'MacBook-M4.local',
          lanUrl: 'http://192.168.1.88:7443',
          lanIp: '192.168.1.88',
          port: 7443,
          source: 'mdns',
        ),
      ],
    );
    await ctrl.init();

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pumpAndSettle();

    expect(find.text('НАЙДЕНО В WI‑FI СЕТИ'), findsOneWidget);
    expect(find.text('MacBook-M4'), findsOneWidget);
    await tester.tap(find.text('Выбрать'));
    await tester.pumpAndSettle();
    expect(find.textContaining('192.168.1.88:7443'), findsWidgets);

    // 3. Connect and verify Session Filter Chips, Pinning (#21), Workspace Switcher (#20), Stop (#12), & Upload Preview (#11)
    await ctrl.connectToMachine(
      const SavedMachine(
        machineId: 'mach_lan_1',
        machineName: 'MacBook-M4',
        lanUrl: 'http://192.168.1.88:7443',
        cloudflareUrl: '',
        sessionId: 'mach_lan_1',
        deviceToken: 'tok_lan',
        lastConnectedAtMs: 1700000000000,
      ),
    );
    sock.emit('server.hello', {
      'approvalMode': 'observe',
      'activeWorkspace': '/Users/dev/remote-app',
      'workspaces': [
        {'path': '/Users/dev/.codex', 'name': '.codex', 'isDefault': false, 'isOpenInHost': false, 'sessionCount': 3},
        {'path': '/Users/dev/remote-app', 'name': 'remote-app', 'isDefault': true, 'isOpenInHost': true, 'sessionCount': 1},
        {'path': '/Users/dev/game-client', 'name': 'game-client', 'isDefault': false, 'isOpenInHost': true, 'sessionCount': 1},
      ],
      'sessions': [
        {
          'id': 's_work',
          'title': 'Сборка клиента',
          'status': 'working',
          'stepCount': 3,
          'lastActivity': 'flutter build',
          'artifactCount': 0,
          'updatedAtMs': 1700000500000,
          'workspaceHint': '/Users/dev/game-client',
          'workspaceName': 'game-client',
        },
        {
          'id': 's_chat',
          'title': 'Session ffc9762c',
          'status': 'idle',
          'stepCount': 5,
          'lastActivity': 'Готово',
          'artifactCount': 0,
          'updatedAtMs': 1700000100000,
          'workspaceHint': '/Users/dev/remote-app',
          'workspaceName': 'remote-app',
        },
      ],
    });
    await tester.pumpAndSettle();

    // Hidden `.codex` workspace is excluded, and raw `Session ffc9762c` is humanized!
    expect(find.text('.codex'), findsNothing);
    expect(find.text('Диалог #ffc976'), findsOneWidget);

    // Active workspace `remote-app` is sorted first in the filter bar
    await tester.tap(find.widgetWithText(InkWell, 'remote-app').first);
    await tester.pumpAndSettle();
    expect(find.text('Диалог #ffc976'), findsOneWidget);
    expect(find.text('Сборка клиента'), findsNothing);

    // Reset filter via `Все (2)` and pin `Диалог #ffc976`
    await tester.tap(find.text('Все (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.push_pin_outlined).last);
    await tester.pumpAndSettle();
    expect(ctrl.isSessionPinned('s_chat'), isTrue);
    expect(find.text('Закреплённые (1)'), findsOneWidget);

    // Open working session `Сборка клиента` -> verify single unified `Стоп` capsule & coalesced tool steps!
    await tester.tap(find.text('Сборка клиента'));
    await tester.pumpAndSettle();
    sock.emit('session.detail.result', {
      'detail': {
        'summary': {'id': 's_work', 'title': 'Сборка монополии', 'status': 'working'},
        'steps': [
          {
            'seq': 1,
            'stepIndex': 1,
            'role': 'assistant',
            'thinking': 'Шаг 1: проверяю зависимости',
            'content': '',
            'toolCalls': [
              {'name': 'run_command', 'summary': 'flutter pub get'},
            ],
          },
          {
            'seq': 2,
            'stepIndex': 2,
            'role': 'assistant',
            'thinking': 'Шаг 2: запускаю сборку',
            'content': '',
            'toolCalls': [
              {'name': 'run_command', 'summary': 'flutter build apk'},
            ],
          },
        ],
        'artifacts': const <Map<String, dynamic>>[],
      },
    });
    await tester.pumpAndSettle();

    // Two consecutive tool-only steps coalesce into ONE `Размышление` header with `· 2` badge!
    expect(find.text('Размышление'), findsOneWidget);
    expect(find.text('· 2'), findsOneWidget);
    expect(find.text('flutter pub get'), findsOneWidget);
    expect(find.text('flutter build apk'), findsOneWidget);

    // Only ONE `Стоп` button on screen when composer is empty
    expect(find.text('Стоп'), findsOneWidget);

    // Typing text while working shows BOTH Send-to-queue arrow AND compact Stop icon button!
    final chatInput = find.widgetWithText(TextField, 'Добавить сообщение в очередь…');
    await tester.enterText(chatInput, 'Ещё добавь тесты');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byTooltip('Остановить агента'), findsOneWidget);
    await tester.enterText(chatInput, '');
    await tester.pumpAndSettle();

    // Tapping `Стоп` sends `chat.stop`
    await tester.tap(find.text('Стоп'));
    await tester.pumpAndSettle();
    expect(sock.sent.any((e) => e['type'] == 'chat.stop'), isTrue);

    // Upload attachment and verify preview strip & send button enabled without typing text!
    await ctrl.uploadAttachmentBytes(
      fileName: 'note.txt',
      bytes: Uint8List.fromList([116, 101, 115, 116]),
    );
    await tester.pumpAndSettle();
    expect(find.text('note.txt'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(ctrl.pendingAttachments, isEmpty);
    expect(
      sock.sent.where((e) => e['type'] == 'chat.send').last['payload']['prompt'],
      contains('.antigravity-uploads/note.txt'),
    );

    ctrl.dispose();
  });

  testWidgets('Improvements cover syntax highlighter, workspace picker, stale pinned count, collapsible tools, drafts, search, pagination, settings, ANSI terminal, and PopScope', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 1. Language-aware CodeSyntaxHighlighter (#3)
    final dartSpans = CodeSyntaxHighlighter.highlight('i--; final x = 1;', 'dart');
    final hasGrayCommentInDart = dartSpans.any(
      (s) => s is TextSpan && (s.text?.contains('--;') ?? false) && s.style?.fontStyle == FontStyle.italic,
    );
    expect(hasGrayCommentInDart, isFalse);

    final pySpans = CodeSyntaxHighlighter.highlight('x = 1 # py note', 'python');
    final hasPyComment = pySpans.any(
      (s) => s is TextSpan && (s.text == '# py note') && s.style?.fontStyle == FontStyle.italic,
    );
    expect(hasPyComment, isTrue);

    final rustSpans = CodeSyntaxHighlighter.highlight('use crate::app;', 'rust');
    final hasCrateKeyword = rustSpans.any(
      (s) => s is TextSpan && s.text == 'crate' && s.style?.fontWeight == FontWeight.w600,
    );
    expect(hasCrateKeyword, isTrue);

    // 2. ANSI parser / stripper (#16)
    const ansiRaw = '\x1B[32mPASS\x1B[0m plain \x1B[1;31mFAIL\x1B[0m';
    expect(stripAnsi(ansiRaw), 'PASS plain FAIL');
    final ansiSpans = parseAnsiSpans(ansiRaw);
    expect(ansiSpans.length, 3);
    expect((ansiSpans[0] as TextSpan).text, 'PASS');
    expect((ansiSpans[0] as TextSpan).style?.color, isNotNull);

    // 3. Full interactive Cockpit coverage
    SharedPreferences.setMockInitialValues({});
    late WidgetFakeSocket sock;
    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (_) => sock = WidgetFakeSocket(),
    );
    await ctrl.init();
    await ctrl.togglePinSession('s_1');
    await ctrl.togglePinSession('stale_missing_id');

    await ctrl.connectToMachine(
      const SavedMachine(
        machineId: 'm_imp',
        machineName: 'MacMini.local',
        lanUrl: 'http://192.168.1.30:7443',
        cloudflareUrl: '',
        sessionId: 'm_imp',
        deviceToken: 'tok_imp',
        lastConnectedAtMs: 1700000000000,
      ),
    );
    sock.emit('server.hello', {
      'approvalMode': 'ask-mobile',
      'activeWorkspace': '/Users/dev/ws-two',
      'workspaces': [
        {'path': '/Users/dev/ws-one', 'name': 'ws-one', 'isDefault': true, 'isOpenInHost': true, 'sessionCount': 1},
        {'path': '/Users/dev/ws-two', 'name': 'ws-two', 'isDefault': false, 'isOpenInHost': true, 'sessionCount': 2},
      ],
      'sessions': [
        {
          'id': 's_1',
          'title': 'Первая задача',
          'status': 'working',
          'stepCount': 260,
          'lastActivity': 'Edit widgets',
          'artifactCount': 0,
          'updatedAtMs': 1700000200000,
        },
        {
          'id': 's_2',
          'title': 'Вторая задача',
          'status': 'idle',
          'stepCount': 4,
          'lastActivity': 'Готово',
          'artifactCount': 0,
          'updatedAtMs': 1700000100000,
        },
      ],
    });

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pumpAndSettle();

    // Pinned chip ignores `stale_missing_id` and counts only live session `s_1` -> `Закреплённые (1)` (#2)
    expect(find.text('Закреплённые (1)'), findsOneWidget);

    // Quick Stop button on working session card stops directly (#17)
    await tester.tap(find.byTooltip('Остановить сессию'));
    await tester.pumpAndSettle();
    expect(sock.sent.any((e) => e['type'] == 'chat.stop'), isTrue);

    // Workspace Picker highlights ONLY `ws-two` even though `ws-one` had stale `isDefault: true` (#1)
    await tester.tap(find.text('Git Diff'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ws-two').last);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // Settings sheet: change font scale & keepScreenOn (#21)
    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Настройки пульта'), findsOneWidget);
    await tester.tap(find.text('Крупный'));
    await tester.pumpAndSettle();
    expect(ctrl.chatFontScale, closeTo(1.15, 0.01));
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // Open session s_1 -> collapsible >4 tools, pagination button, search, copy, drafts, smart /plan prefix
    await tester.tap(find.text('Сессии'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Первая задача'));
    await tester.pumpAndSettle();

    sock.emit('session.detail.result', {
      'detail': {
        'summary': {'id': 's_1', 'title': 'Первая задача', 'status': 'idle'},
        'visibleStepCount': 270,
        'hasMoreSteps': true,
        'steps': [
          {
            'seq': 1,
            'stepIndex': 1,
            'role': 'assistant',
            'thinking': '',
            'content': '',
            'toolCalls': [
              for (var i = 1; i <= 6; i++) {'name': 'read_file', 'summary': 'Read file_$i.dart'},
            ],
          },
          {
            'seq': 2,
            'stepIndex': 2,
            'role': 'assistant',
            'thinking': '',
            'content': 'Уникальный ответ для поиска XYZ',
            'toolCalls': const <Map<String, dynamic>>[],
          },
        ],
        'artifacts': const <Map<String, dynamic>>[],
      },
    });
    await tester.pumpAndSettle();

    // >4 tools collapse into summary header (#7)
    expect(find.text('Выполнено 6 шагов · показать все'), findsOneWidget);
    expect(find.text('Read file_1.dart'), findsNothing);
    expect(find.text('Read file_6.dart'), findsOneWidget);
    await tester.tap(find.text('Выполнено 6 шагов · показать все'));
    await tester.pumpAndSettle();
    expect(find.text('Read file_1.dart'), findsOneWidget);

    // Load older steps button (#20) — in reverse:true ListView (AxisDirection.up), older items are scrolled upwards (-200)
    await tester.scrollUntilVisible(
      find.textContaining('Загрузить ранние шаги'),
      -200,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.up),
    );
    await tester.tap(find.textContaining('Загрузить ранние шаги'));
    await tester.pumpAndSettle();
    expect(
      sock.sent.any((e) => e['type'] == 'session.detail' && (e['payload']['maxSteps'] as int) == 500),
      isTrue,
    );

    // Dismissible error banner + smart `/plan ` prefix (#9)
    sock.emit('error', {'message': 'Временная ошибка'});
    await tester.pumpAndSettle();
    expect(find.text('Временная ошибка'), findsOneWidget);
    await tester.tap(find.byTooltip('Скрыть ошибку'));
    await tester.pumpAndSettle();
    expect(find.text('Временная ошибка'), findsNothing);

    // Ensure quick-preset chips bar is completely removed
    expect(find.text('Сжать контекст'), findsNothing);

    final composer = find.widgetWithText(TextField, 'Сообщение для Antigravity…');
    await tester.enterText(composer, '/plan мой текст');
    await tester.pump();
    expect(find.text('/plan мой текст'), findsOneWidget);

    // Per-session draft preserved when switching to s_2 and back (#9)
    ctrl.openSession('s_2');
    await tester.pumpAndSettle();
    expect(find.text('/plan мой текст'), findsNothing);
    ctrl.openSession('s_1');
    await tester.pumpAndSettle();
    expect(find.text('/plan мой текст'), findsOneWidget);

    // In-chat search (#21)
    await tester.tap(find.byTooltip('Поиск в чате'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Поиск по сообщениям чата…'), 'XYZ');
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.textContaining('Уникальный ответ', findRichText: true), findsOneWidget);

    // PopScope returns from Chat tab to Sessions tab on system back (#5)
    final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
    await widgetsAppState.didPopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Закреплённые (1)'), findsOneWidget);

    // ConnectedDevicesSheet: tap host header -> view paired devices, revoke secondary device
    sock.emit('devices.list.result', {
      'currentDeviceId': 'dev_phone_1',
      'devices': [
        {
          'id': 'dev_phone_1',
          'name': 'Phone-1',
          'platform': 'android',
          'online': true,
          'remoteAddress': '192.168.1.25',
          'lastSeenAt': DateTime.now().millisecondsSinceEpoch,
        },
        {
          'id': 'dev_old',
          'name': 'Backup Phone',
          'platform': 'android',
          'online': false,
          'lastSeenAt': DateTime.now().millisecondsSinceEpoch - 120000,
        },
      ],
    });
    await tester.tap(find.text('MacMini'));
    await tester.pumpAndSettle();
    expect(find.text('Устройства и подключение'), findsOneWidget);
    expect(find.text('Это устройство'), findsOneWidget);
    expect(find.text('Backup Phone'), findsOneWidget);

    await tester.tap(find.byTooltip('Отвязать устройство'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отвязать'));
    await tester.pumpAndSettle();
    expect(sock.sent.any((e) => e['type'] == 'devices.revoke'), isTrue);
    expect(find.text('Backup Phone'), findsNothing);

    ctrl.dispose();
  });

  testWidgets('ConnectScreen deduplicates paired LAN bridge into МОИ КОМПЬЮТЕРЫ with online badge', (tester) async {
    SharedPreferences.setMockInitialValues({
      'agy_remote_saved_machines_v1': jsonEncode([
        const SavedMachine(
          machineId: 'mach_lan_1',
          machineName: 'Workstation.local',
          lanUrl: 'http://192.168.1.88:7443',
          cloudflareUrl: '',
          sessionId: 'mach_lan_1',
          deviceToken: 'tok_1',
          lastConnectedAtMs: 1700000000000,
        ).toJson(),
      ]),
    });

    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      lanScanner: () async => const [
        DiscoveredLanBridge(
          machineId: 'mach_lan_1',
          machineName: 'Workstation.local',
          lanUrl: 'http://192.168.1.88:7443',
          lanIp: '192.168.1.88',
          port: 7443,
          source: 'mdns',
        ),
      ],
    );
    await ctrl.init();

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pumpAndSettle();

    expect(find.text('МОИ КОМПЬЮТЕРЫ (1)'), findsOneWidget);
    expect(find.text('Workstation'), findsOneWidget);
    expect(find.text('В сети'), findsOneWidget);
    expect(find.text('НАЙДЕНО В WI‑FI СЕТИ'), findsNothing);

    ctrl.dispose();
  });

  testWidgets('SessionsView shows clear connecting state and connection error actions when unreachable', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final slowReady = Completer<void>();
    final ctrl = BridgeController(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      socketFactory: (uri) => _FailingOrSlowSocket(readyFuture: slowReady.future),
    );
    await ctrl.init();

    const m = SavedMachine(
      machineId: 'mach_err',
      machineName: 'Studio-Mac.local',
      lanUrl: 'http://192.168.1.55:7443',
      cloudflareUrl: '',
      sessionId: 'mach_err',
      deviceToken: 'tok_err',
      lastConnectedAtMs: 1000,
    );
    final connectFut = ctrl.connectToMachine(m);

    await tester.pumpWidget(AntigravityRemoteApp(controller: ctrl));
    await tester.pump();
    expect(find.text('Подключение к Studio-Mac…'), findsOneWidget);

    slowReady.completeError(Exception('refused'));
    await connectFut;
    await tester.pump();

    expect(find.text('Не удалось подключиться к Studio-Mac'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(find.text('Выбрать другой ПК'), findsOneWidget);

    ctrl.dispose();
  });
}

class _FailingOrSlowSocket implements RpcSocketTransport {
  final Future<void> readyFuture;
  final _sc = StreamController<dynamic>.broadcast();
  _FailingOrSlowSocket({required this.readyFuture});

  @override
  Future<void> get ready => readyFuture;

  @override
  Stream<dynamic> get stream => _sc.stream;

  @override
  void send(String data) {}

  @override
  Future<void> close() async {}
}
