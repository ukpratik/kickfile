import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/tokens.dart';
import '../widgets/common.dart';

/// Phone camera scanner for kickFile QR codes (US-003, M-08). Returns the raw `kickfile://` text.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;
  String? _invalid;

  void _onDetect(BarcodeCapture c) {
    if (_done) return;
    for (final b in c.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      if (raw.startsWith('kickfile://')) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
      if (_invalid != raw) setState(() => _invalid = raw);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan a kickFile code')),
    body: Column(
      children: [
        Expanded(
          child: ClipRect(
            child: MobileScanner(
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: EmptyState(
                  icon: LucideIcons.cameraOff,
                  title: 'Camera not available',
                  text: error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Allow the camera in Settings, or type the code shown under the QR instead.'
                      : 'Type the code shown under the QR instead.',
                  actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Type a code'))],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(KfSpace.gutter),
          child: _invalid == null
              ? Text(
                  'Point the camera at the QR code on the other device (Show QR).',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                )
              : const KfBanner(tone: BannerTone.warning, text: "That's not a kickFile code. Open Show QR on the other device."),
        ),
      ],
    ),
  );
}
