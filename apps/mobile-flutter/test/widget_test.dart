import 'package:antigravity_remote/main.dart';
import 'package:antigravity_remote/models/remote_models.dart';
import 'package:antigravity_remote/services/bridge_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('PairingQrPayload parses LAN and Cloudflare Edge query parameters', () {
    final parsed = PairingQrPayload.tryParse(
      'http://192.168.1.42:7443/pair?t=tok_secret&m=mach_09&n=HOME-PC&cf=https%3A%2F%2Fagy.example.workers.dev&s=mach_09',
    );
    expect(parsed, isNotNull);
    expect(parsed!.baseUrl, 'http://192.168.1.42:7443');
    expect(parsed.token, 'tok_secret');
    expect(parsed.machineId, 'mach_09');
    expect(parsed.machineName, 'HOME-PC');
    expect(parsed.cloudflareUrl, 'https://agy.example.workers.dev');
    expect(parsed.sessionId, 'mach_09');
  });

  testWidgets('ConnectScreen renders QR scanner CTA and manual PIN pairing form', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = BridgeController();
    await controller.init();

    await tester.pumpWidget(AntigravityRemoteApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Antigravity Remote'), findsOneWidget);
    expect(find.text('Сканировать QR-код'), findsOneWidget);
    expect(find.text('Связать по PIN'), findsOneWidget);
  });
}
