import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/remote_models.dart';
import '../theme/telemetry_theme.dart';

class QrScannerSheet extends StatefulWidget {
  const QrScannerSheet({super.key});

  @override
  State<QrScannerSheet> createState() => _QrScannerSheetState();
}

class _QrScannerSheetState extends State<QrScannerSheet> {
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
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                          letterSpacing: -0.3,
                        ),
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
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                                  _scanHint =
                                      'Это не QR-код Antigravity Remote — наведите на панель управления на ПК';
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
