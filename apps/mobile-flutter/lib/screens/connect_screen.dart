import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import '../widgets/machine_cards.dart';
import '../widgets/qr_scanner_sheet.dart';

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
  bool _showManualPair = false;

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
        widget.controller.probeSavedMachines();
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
      builder: (_) => const QrScannerSheet(),
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

  Future<void> _pastePairingFromClipboard() async {
    HapticFeedback.selectionClick();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (!mounted) return;
    final parsed = PairingQrPayload.tryParse(raw);
    if (parsed != null && parsed.looksLikePairingCode) {
      setState(() => _submitting = true);
      await widget.controller.pairFromQrUrl(
        raw,
        deviceName: _deviceCtrl.text.trim().isEmpty ? 'Flutter Mobile' : _deviceCtrl.text.trim(),
      );
      if (mounted) setState(() => _submitting = false);
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          raw.isEmpty
              ? 'Буфер обмена пуст — скопируйте ссылку из панели Remote Control'
              : 'В буфере нет ссылки сопряжения Antigravity Remote',
        ),
        duration: const Duration(milliseconds: 2200),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
      _showManualPair = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pinFocus.requestFocus();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Выбран ${bridge.machineName} (${bridge.lanIp}:${bridge.port}) — введите PIN или сканируйте QR',
        ),
        duration: const Duration(milliseconds: 2200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showEditMachineDialog(SavedMachine m) async {
    final result = await showDialog<({String name, String lan, String cf})>(
      context: context,
      builder: (_) => _EditMachineDialog(machine: m),
    );
    if (result != null) {
      await widget.controller.updateSavedMachine(
        m.machineId,
        machineName: result.name,
        lanUrl: result.lan,
        cloudflareUrl: result.cf,
      );
    }
  }

  Future<void> _confirmRemoveMachine(SavedMachine m) async {
    final cleanName = TelemetryFormatters.cleanMachineName(m.machineName);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить устройство?'),
        content: Text('Удалить «$cleanName» из списка привязанных компьютеров?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TelemetryColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.removeMachine(m.machineId);
    }
  }

  bool _isMachineOnlineLan(BridgeController ctrl, SavedMachine m) {
    if (ctrl.machineLanReachable[m.machineId] == true) return true;
    return ctrl.discoveredBridges.any(
      (b) => b.machineId.isNotEmpty && b.machineId == m.machineId,
    );
  }

  Widget _buildManualPinCard() {
    return Container(
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
            style: TextStyle(fontSize: 12.5, color: TelemetryColors.textSecondary),
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
              prefixIcon: Icon(
                Icons.lan_outlined,
                size: 18,
                color: TelemetryColors.textDim,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pinCtrl,
            focusNode: _pinFocus,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [_PinCodeFormatter()],
            maxLength: 7,
            textAlign: TextAlign.center,
            onSubmitted: (_) => _submitManualPair(),
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
                _showAdvanced ? Icons.expand_less_rounded : Icons.tune_rounded,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;

    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final hasSaved = ctrl.savedMachines.isNotEmpty;
        final sortedMachines = List<SavedMachine>.from(ctrl.savedMachines)
          ..sort((a, b) {
            final aOn = _isMachineOnlineLan(ctrl, a);
            final bOn = _isMachineOnlineLan(ctrl, b);
            if (aOn != bOn) return aOn ? -1 : 1;
            return b.lastConnectedAtMs.compareTo(a.lastConnectedAtMs);
          });

        final pairedIds = ctrl.savedMachines
            .map((m) => m.machineId)
            .where((id) => id.isNotEmpty)
            .toSet();
        final unpairedBridges = ctrl.discoveredBridges
            .where((b) => b.machineId.isEmpty || !pairedIds.contains(b.machineId))
            .toList();

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
                child: RefreshIndicator(
                  color: TelemetryColors.accentBright,
                  backgroundColor: TelemetryColors.bgElevated,
                  onRefresh: () async {
                    await Future.wait([
                      ctrl.scanLanBridges(force: true),
                      ctrl.probeSavedMachines(),
                    ]);
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
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

                      const SizedBox(height: 22),

                      // Error Banner
                      if (ctrl.lastError != null) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: TelemetryColors.danger.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: TelemetryColors.danger.withValues(alpha: 0.45),
                            ),
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
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                tooltip: 'Скрыть ошибку',
                                onPressed: ctrl.clearError,
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  color: Color(0xFFFECDD3),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Saved Workstations ("МОИ КОМПЬЮТЕРЫ")
                      if (hasSaved) ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 2, bottom: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'МОИ КОМПЬЮТЕРЫ (${sortedMachines.length})',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.8,
                                    color: TelemetryColors.textDim,
                                  ),
                                ),
                              ),
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: ctrl.scanningLan
                                    ? null
                                    : () {
                                        HapticFeedback.selectionClick();
                                        ctrl.scanLanBridges(force: true);
                                        ctrl.probeSavedMachines();
                                      },
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Text(
                                    'Проверить',
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
                        for (final SavedMachine m in sortedMachines) ...[
                          SavedMachineCard(
                            machine: m,
                            isOnlineLan: _isMachineOnlineLan(ctrl, m),
                            isConnecting: ctrl.connectingMachineId == m.machineId,
                            busy: _submitting,
                            onConnect: () {
                              HapticFeedback.lightImpact();
                              ctrl.connectToMachine(m);
                            },
                            onEdit: () => _showEditMachineDialog(m),
                            onDelete: () {
                              HapticFeedback.selectionClick();
                              _confirmRemoveMachine(m);
                            },
                          ),
                          const SizedBox(height: 10),
                        ],
                        const SizedBox(height: 10),
                      ],

                      // Newly Discovered Unpaired LAN Bridges (#22 mDNS + UDP Broadcast)
                      if (unpairedBridges.isNotEmpty) ...[
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
                        for (final b in unpairedBridges) ...[
                          DiscoveredBridgeCard(
                            bridge: b,
                            isAlreadyPaired: false,
                            onTap: () => _onTapDiscoveredBridge(b),
                          ),
                          const SizedBox(height: 10),
                        ],
                        const SizedBox(height: 10),
                      ],

                      if (!hasSaved) ...[
                        // First-Launch Onboarding: Full QR + Manual PIN
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [TelemetryColors.bgElevated, TelemetryColors.bgPanel],
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
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: TelemetryColors.live.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(99),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.bolt_rounded,
                                          size: 13,
                                          color: TelemetryColors.live,
                                        ),
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
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 50,
                                      child: FilledButton.icon(
                                        onPressed: _submitting ? null : _openQrScanner,
                                        style: FilledButton.styleFrom(
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(14),
                                          ),
                                        ),
                                        icon: const Icon(Icons.qr_code_scanner_rounded, size: 21),
                                        label: const Text('Сканировать QR-код'),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    height: 50,
                                    width: 50,
                                    child: OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                      ),
                                      onPressed: _submitting ? null : _pastePairingFromClipboard,
                                      child: const Tooltip(
                                        message: 'Вставить ссылку из буфера',
                                        child: Icon(Icons.content_paste_rounded, size: 20),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildManualPinCard(),
                      ] else ...[
                        // Returning User Compact "Добавить компьютер" Strip
                        const Padding(
                          padding: EdgeInsets.only(left: 2, bottom: 10),
                          child: Text(
                            'ДОБАВИТЬ КОМПЬЮТЕР',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: TelemetryColors.textDim,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: TelemetryColors.bgPanel,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: TelemetryColors.border),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _submitting ? null : _openQrScanner,
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                                  label: const Text('QR-код'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    HapticFeedback.selectionClick();
                                    setState(() => _showManualPair = !_showManualPair);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    side: BorderSide(
                                      color: _showManualPair
                                          ? TelemetryColors.accent
                                          : TelemetryColors.borderStrong,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  icon: const Icon(Icons.pin_outlined, size: 18),
                                  label: const Text('По PIN'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 44,
                                height: 44,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: _submitting ? null : _pastePairingFromClipboard,
                                  child: const Tooltip(
                                    message: 'Вставить ссылку из буфера',
                                    child: Icon(Icons.content_paste_rounded, size: 18),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_showManualPair) ...[
                          const SizedBox(height: 12),
                          _buildManualPinCard(),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EditMachineDialog extends StatefulWidget {
  final SavedMachine machine;

  const _EditMachineDialog({required this.machine});

  @override
  State<_EditMachineDialog> createState() => _EditMachineDialogState();
}

class _EditMachineDialogState extends State<_EditMachineDialog> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: TelemetryFormatters.cleanMachineName(widget.machine.machineName),
  );
  late final TextEditingController _lanCtrl =
      TextEditingController(text: widget.machine.lanUrl);
  late final TextEditingController _cfCtrl =
      TextEditingController(text: widget.machine.cloudflareUrl);

  @override
  void dispose() {
    _nameCtrl.dispose();
    _lanCtrl.dispose();
    _cfCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Параметры компьютера'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _lanCtrl,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: const InputDecoration(labelText: 'LAN адрес'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _cfCtrl,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: const InputDecoration(labelText: 'Cloudflare URL'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            name: _nameCtrl.text,
            lan: _lanCtrl.text,
            cf: _cfCtrl.text,
          )),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _PinCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final clipped = digits.length > 6 ? digits.substring(0, 6) : digits;
    final formatted = clipped.length > 3
        ? '${clipped.substring(0, 3)} ${clipped.substring(3)}'
        : clipped;
    return TextSelection.collapsed(offset: formatted.length).isValid
        ? TextEditingValue(
            text: formatted,
            selection: TextSelection.collapsed(offset: formatted.length),
          )
        : TextEditingValue(text: formatted);
  }
}
