import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/cockpit_screen.dart';
import 'screens/connect_screen.dart';
import 'services/bridge_controller.dart';
import 'theme/telemetry_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(TelemetryColors.overlayStyle);

  final controller = BridgeController();
  await controller.init(autoConnect: true);
  runApp(AntigravityRemoteApp(controller: controller));
}

class AntigravityRemoteApp extends StatefulWidget {
  final BridgeController controller;

  const AntigravityRemoteApp({super.key, required this.controller});

  @override
  State<AntigravityRemoteApp> createState() => _AntigravityRemoteAppState();
}

class _AntigravityRemoteAppState extends State<AntigravityRemoteApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      widget.controller.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      widget.controller.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: TelemetryColors.overlayStyle,
      child: MaterialApp(
        title: 'Antigravity Remote',
        debugShowCheckedModeBanner: false,
        theme: buildTelemetryTheme(),
        home: ValueListenableBuilder<bool>(
          valueListenable: controller.hasActiveMachineNotifier,
          builder: (context, hasActiveMachine, _) {
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: hasActiveMachine
                  ? CockpitScreen(key: const ValueKey('cockpit'), controller: controller)
                  : ConnectScreen(key: const ValueKey('connect'), controller: controller),
            );
          },
        ),
      ),
    );
  }
}
