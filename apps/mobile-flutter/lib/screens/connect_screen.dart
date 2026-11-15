import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';

class ConnectScreen extends StatefulWidget {
  final BridgeController controller;

  const ConnectScreen({super.key, required this.controller});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _urlCtrl;
  final _pinCtrl = TextEditingController();
  final _pinFocus = FocusNode();
  final _sessionCtrl = TextEditingController();
  final _deviceCtrl = TextEditingController(text: 'Android Remote');
  bool _submitting = false;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    final saved = widget.controller.savedMachines;
    final initialUrl = saved.isNotEmpty && saved.first.lanUrl.isNotEmpty
        ? saved.first.lanUrl
        : 'http://192.168.1.';
    _urlCtrl = TextEditingController(text: initialUrl);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.controller.scanLanBridges();
      }
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _pinCtrl.dispose();
    _pinFocus.dispose();
    _sessionCtrl.dispose();
    _deviceCtrl.dispose();
    super.dispose();
  }

  Future<void> _openQrScanner() async {
    HapticFeedback.lightImpact();
    final scanned = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: TelemetryColors.bgCanvas,
      builder: (_) => const _QrScannerSheet(),
    );
    if (scanned == null || scanned.isEmpty || !mounted) return;
    HapticFeedback.mediumImpact();
    setState(() => _submitting = true);
    await widget.controller.pairFromQrUrl(
      scanned,
      deviceName: _deviceCtrl.text.trim().isEmpty ? 'Flutter Mobile' : _deviceCtrl.text.trim(),
    );
    if (mounted) setState(() => _submitting = false);
  }

  Future<void> _submitManualPair() async {
    final host = _urlCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    if (host.isEmpty || pin.isEmpty) return;
    HapticFeedback.lightImpact();
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    await widget.controller.pairWithEndpoint(
      baseUrl: host,
      pin: pin,
      sessionId: _sessionCtrl.text.trim(),
      deviceName: _deviceCtrl.text.trim().isEmpty ? 'Flutter Mobile' : _deviceCtrl.text.trim(),
    );
    if (mounted) setState(() => _submitting = false);
  }

  void _onTapDiscoveredBridge(DiscoveredLanBridge bridge) {
    final ctrl = widget.controller;
    HapticFeedback.lightImpact();
    final matchedSaved = ctrl.savedMachines
        .where((m) => bridge.machineId.isNotEmpty && m.machineId == bridge.machineId)
        .cast<SavedMachine?>()
        .firstWhere((_) => true, orElse: () => null);
    if (matchedSaved != null) {
      ctrl.connectToMachine(matchedSaved.copyWith(lanUrl: bridge.lanUrl));
      return;
    }
    setState(() {
      _urlCtrl.text = bridge.lanUrl;
    });
    _pinFocus.requestFocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Выбран ${bridge.machineName} (${bridge.lanIp}:${bridge.port}) — введите PIN или сканируйте QR'),
        duration: const Duration(milliseconds: 2200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;

    return Scaffold(
      body: Stack(
        children: [
          // Subtle top radial ambient glow
          Positioned(
            top: -120,
            left: -60,
            right: -60,
            child: IgnorePointer(
              child: Container(
                height: 320,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      TelemetryColors.accent.withValues(alpha: 0.22),
                      TelemetryColors.cyan.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),

          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                // Hero Brand Header
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [TelemetryColors.accent, Color(0xFF4F46E5)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: TelemetryColors.accent.withValues(alpha: 0.35),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.radar_rounded, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Antigravity Remote',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                              color: TelemetryColors.textPrimary,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Локальный и Cloudflare-пульт агента',
                            style: TextStyle(
                              fontSize: 13,
                              color: TelemetryColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Поиск Mac в Wi‑Fi сети',
                      onPressed: ctrl.scanningLan
                          ? null
                          : () {
                              HapticFeedback.selectionClick();
                              ctrl.scanLanBridges();
                            },
                      icon: ctrl.scanningLan
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: TelemetryColors.accentBright,
                              ),
                            )
                          : const Icon(
                              Icons.wifi_find_rounded,
                              color: TelemetryColors.accentBright,
                            ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Error Banner
                if (ctrl.lastError != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: TelemetryColors.danger.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: TelemetryColors.danger.withValues(alpha: 0.45)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.error_outline_rounded,
                            size: 18,
                            color: TelemetryColors.danger,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            ctrl.lastError!,
                            style: const TextStyle(
                              color: Color(0xFFFECDD3),
                              fontSize: 13,
                              height: 1.38,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Saved Workstations (Instant Reconnect)
                if (ctrl.savedMachines.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.only(left: 2, bottom: 10),
                    child: Text(
                      'ПРИВЯЗАННЫЕ КОМПЬЮТЕРЫ',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: TelemetryColors.textDim,
                      ),
                    ),
                  ),
                  for (final SavedMachine m in ctrl.savedMachines) ...[
                    _SavedMachineCard(
                      machine: m,
                      busy: _submitting,
                      onConnect: () {
                        HapticFeedback.lightImpact();
                        ctrl.connectToMachine(m);
                      },
                      onDelete: () {
                        HapticFeedback.selectionClick();
                        ctrl.removeMachine(m.machineId);
                      },
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 12),
                ],

                // Auto-Discovered LAN Bridges (#22 mDNS + UDP Broadcast)
                if (ctrl.discoveredBridges.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 10),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi_rounded, size: 14, color: TelemetryColors.live),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'НАЙДЕНО В WI‑FI СЕТИ',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: TelemetryColors.live,
                            ),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: ctrl.scanningLan ? null : () => ctrl.scanLanBridges(),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            child: Text(
                              'Обновить',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: TelemetryColors.accentBright,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final b in ctrl.discoveredBridges) ...[
                    _DiscoveredBridgeCard(
                      bridge: b,
                      isAlreadyPaired: ctrl.savedMachines.any(
                        (m) => b.machineId.isNotEmpty && m.machineId == b.machineId,
                      ),
                      onTap: () => _onTapDiscoveredBridge(b),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 12),
                ],

                // Primary QR Scan Hero Card
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        TelemetryColors.bgElevated,
                        TelemetryColors.bgPanel,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: TelemetryColors.borderStrong),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: TelemetryColors.live.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bolt_rounded, size: 13, color: TelemetryColors.live),
                                SizedBox(width: 3),
                                Text(
                                  'Мгновенная привязка',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: TelemetryColors.live,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Подключение по QR-коду',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Откройте панель Remote Control в Antigravity и наведите камеру на QR-код для автоматической настройки LAN и Cloudflare.',
                        style: TextStyle(
                          color: TelemetryColors.textSecondary,
                          fontSize: 13.5,
                          height: 1.42,
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _submitting ? null : _openQrScanner,
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.qr_code_scanner_rounded, size: 21),
                          label: const Text('Сканировать QR-код'),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Clean Manual PIN Pairing Card
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: TelemetryColors.bgPanel,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: TelemetryColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Подключение по 6-значному PIN',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Выберите найденный компьютер выше или укажите адрес и одноразовый PIN.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: TelemetryColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _urlCtrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5),
                        decoration: const InputDecoration(
                          labelText: 'Адрес Bridge (LAN или Cloudflare)',
                          hintText: 'http://192.168.1.7:7443',
                          prefixIcon: Icon(Icons.lan_outlined, size: 18, color: TelemetryColors.textDim),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pinCtrl,
                        focusNode: _pinFocus,
                        keyboardType: TextInputType.number,
                        maxLength: 7,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 6,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Одноразовый PIN',
                          counterText: '',
                          hintText: '000 000',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            foregroundColor: TelemetryColors.textSecondary,
                          ),
                          onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                          icon: Icon(
                            _showAdvanced
                                ? Icons.expand_less_rounded
                                : Icons.tune_rounded,
                            size: 16,
                          ),
                          label: const Text(
                            'Дополнительные параметры',
                            style: TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ),
                      if (_showAdvanced) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _deviceCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Имя этого смартфона',
                            prefixIcon: Icon(
                              Icons.smartphone_rounded,
                              size: 18,
                              color: TelemetryColors.textDim,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _sessionCtrl,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: 'Session / Machine ID (только Cloudflare)',
                            hintText: 'mach_...',
                            prefixIcon: Icon(
                              Icons.cloud_outlined,
                              size: 18,
                              color: TelemetryColors.textDim,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 46,
                        child: OutlinedButton(
                          onPressed: _submitting ? null : _submitManualPair,
                          child: Text(_submitting ? 'Подключение…' : 'Связать по PIN'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscoveredBridgeCard extends StatelessWidget {
  final DiscoveredLanBridge bridge;
  final bool isAlreadyPaired;
  final VoidCallback onTap;

  const _DiscoveredBridgeCard({
    required this.bridge,
    required this.isAlreadyPaired,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cleanName = TelemetryFormatters.cleanMachineName(bridge.machineName);
    return Material(
      color: TelemetryColors.bgPanel,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: TelemetryColors.live.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: TelemetryColors.live.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.wifi_tethering_rounded,
                  color: TelemetryColors.live,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cleanName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${bridge.lanIp}:${bridge.port} • ${bridge.source.toUpperCase()}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: TelemetryColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isAlreadyPaired
                      ? TelemetryColors.live.withValues(alpha: 0.18)
                      : TelemetryColors.bgElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isAlreadyPaired
                        ? TelemetryColors.live.withValues(alpha: 0.45)
                        : TelemetryColors.borderStrong,
                  ),
                ),
                child: Text(
                  isAlreadyPaired ? 'Войти' : 'Выбрать',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isAlreadyPaired ? TelemetryColors.live : TelemetryColors.accentBright,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedMachineCard extends StatelessWidget {
  final SavedMachine machine;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDelete;

  const _SavedMachineCard({
    required this.machine,
    required this.busy,
    required this.onConnect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cleanName = TelemetryFormatters.cleanMachineName(machine.machineName);
    final lastSeen = TelemetryFormatters.relativeTime(machine.lastConnectedAtMs);

    return Material(
      color: TelemetryColors.bgPanel,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: busy ? null : onConnect,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: TelemetryColors.borderStrong),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: TelemetryColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.laptop_mac_rounded,
                  color: TelemetryColors.accentBright,
                  size: 21,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cleanName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (machine.lanUrl.isNotEmpty)
                          Flexible(
                            child: Text(
                              machine.lanUrl.replaceFirst(RegExp(r'^https?://'), ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: TelemetryColors.textSecondary,
                              ),
                            ),
                          ),
                        if (lastSeen.isNotEmpty) ...[
                          const Text(
                            ' • ',
                            style: TextStyle(fontSize: 11.5, color: TelemetryColors.textDim),
                          ),
                          Text(
                            lastSeen,
                            style: const TextStyle(fontSize: 11.5, color: TelemetryColors.textDim),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Удалить устройство',
                onPressed: onDelete,
                icon: const Icon(Icons.close_rounded, size: 18, color: TelemetryColors.textDim),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: TelemetryColors.accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Text(
                  'Войти',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QrScannerSheet extends StatefulWidget {
  const _QrScannerSheet();

  @override
  State<_QrScannerSheet> createState() => _QrScannerSheetState();
}

class _QrScannerSheetState extends State<_QrScannerSheet> {
  final MobileScannerController _scannerCtrl = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 150,
    cameraResolution: const Size(1920, 1080),
    facing: CameraFacing.back,
  );
  bool _done = false;
  bool _torchOn = false;
  String? _scanHint;

  @override
  void dispose() {
    _scannerCtrl.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (!mounted) return;
    final parsed = PairingQrPayload.tryParse(raw);
    if (parsed != null && parsed.looksLikePairingCode) {
      _done = true;
      Navigator.of(context).pop(raw);
      return;
    }
    setState(() {
      _scanHint = raw.isEmpty
          ? 'Буфер обмена пуст — нажмите «Копировать ссылку» в панели на ПК'
          : 'В буфере нет ссылки сопряжения Antigravity Remote';
    });
  }

  String _describeScannerError(MobileScannerException error) {
    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        return 'Нет доступа к камере. Разрешите использование камеры для Antigravity Remote в настройках Android.';
      case MobileScannerErrorCode.unsupported:
        return 'Камера недоступна на этом устройстве. Используйте 6-значный PIN или вставьте ссылку из буфера.';
      default:
        final detail = error.errorDetails?.message?.trim() ?? '';
        return detail.isNotEmpty
            ? 'Не удалось запустить сканер камеры: $detail'
            : 'Не удалось запустить камеру. Попробуйте нажать «Повторить».';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.82,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: TelemetryColors.borderStrong,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Сканирование QR-кода',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17, letterSpacing: -0.3),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Наведите камеру на QR в боковой панели Remote Control',
                        style: TextStyle(fontSize: 12.5, color: TelemetryColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Вставить ссылку из буфера',
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(
                    Icons.content_paste_rounded,
                    color: TelemetryColors.textSecondary,
                  ),
                ),
                IconButton(
                  tooltip: 'Фонарик',
                  onPressed: () async {
                    try {
                      await _scannerCtrl.toggleTorch();
                      if (mounted) setState(() => _torchOn = !_torchOn);
                    } catch (_) {}
                  },
                  icon: Icon(
                    _torchOn ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                    color: _torchOn ? TelemetryColors.warn : TelemetryColors.textSecondary,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _scannerCtrl,
                  builder: (context, scannerState, _) {
                    final hasError = scannerState.error != null;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        MobileScanner(
                          controller: _scannerCtrl,
                          placeholderBuilder: (context, _) => Container(
                            color: TelemetryColors.bgPanel,
                            alignment: Alignment.center,
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: TelemetryColors.accentBright,
                                  ),
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'Запуск камеры…',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: TelemetryColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          errorBuilder: (context, error, _) => Container(
                            color: TelemetryColors.bgPanel,
                            padding: const EdgeInsets.all(24),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: TelemetryColors.danger.withValues(alpha: 0.14),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.videocam_off_rounded,
                                    color: TelemetryColors.danger,
                                    size: 26,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                const Text(
                                  'Ошибка сканера QR',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _describeScannerError(error),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    color: TelemetryColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  alignment: WrapAlignment.center,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: () => _scannerCtrl.start(),
                                      icon: const Icon(Icons.refresh_rounded, size: 18),
                                      label: const Text('Повторить'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _pasteFromClipboard,
                                      icon: const Icon(Icons.content_paste_rounded, size: 18),
                                      label: const Text('Из буфера'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          onDetect: (capture) {
                            if (_done) return;
                            for (final barcode in capture.barcodes) {
                              final raw = (barcode.rawValue ?? barcode.displayValue)?.trim();
                              if (raw == null || raw.isEmpty) continue;
                              final parsed = PairingQrPayload.tryParse(raw);
                              if (parsed != null && parsed.looksLikePairingCode) {
                                _done = true;
                                Navigator.of(context).pop(raw);
                                return;
                              }
                              if (_scanHint == null && mounted) {
                                setState(() {
                                  _scanHint = 'Это не QR-код Antigravity Remote — наведите на панель управления на ПК';
                                });
                              }
                            }
                          },
                        ),
                        if (!hasError)
                          IgnorePointer(
                            child: Center(
                              child: Container(
                                width: 244,
                                height: 244,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(28),
                                  border: Border.all(
                                    color: TelemetryColors.accentBright.withValues(alpha: 0.9),
                                    width: 2.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.42),
                                      spreadRadius: 400,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (_scanHint != null && !hasError)
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: TelemetryColors.bgPanel.withValues(alpha: 0.92),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: TelemetryColors.borderStrong),
                              ),
                              child: Text(
                                _scanHint!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: TelemetryColors.textPrimary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
