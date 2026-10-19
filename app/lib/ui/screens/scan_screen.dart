// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/tokens.dart';
import '../widgets/common.dart';

/// Phone camera scanner for kickFile QR codes (US-003, M-08). Returns the raw `kickfile://` text.
/// Uses zxing-cpp (open source, no Google services) so the app qualifies for F-Droid.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;
  String? _invalid;
  bool _cameraError = false;

  void _onScan(Code code) {
    final raw = code.text;
    if (_done || raw == null || !code.isValid) return;
    if (raw.startsWith('kickfile://')) {
      _done = true;
      Navigator.of(context).pop(raw);
      return;
    }
    if (_invalid != raw) setState(() => _invalid = raw);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan a kickFile code')),
    body: Column(
      children: [
        Expanded(
          child: _cameraError
              ? Center(
                  child: EmptyState(
                    icon: LucideIcons.cameraOff,
                    title: 'Camera not available',
                    text: 'Allow the camera in Settings, or type the code shown under the QR instead.',
                    actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Type a code'))],
                  ),
                )
              : ClipRect(
                  child: ReaderWidget(
                    onScan: _onScan,
                    codeFormat: Format.qrCode,
                    showGallery: false,
                    showToggleCamera: false,
                    tryHarder: true,
                    onControllerCreated: (CameraController? c, Exception? error) {
                      if (error != null && mounted) setState(() => _cameraError = true);
                    },
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
