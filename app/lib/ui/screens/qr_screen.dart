import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/errors.dart';
import '../../core/protocol.dart';
import '../../core/qr.dart';
import '../../storage/peers.dart';
import '../../transfer/receiver.dart';
import '../format.dart';
import '../scope.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'scan_screen.dart';

/// Show a QR code + short code (US-003, D-05 / M-08). Phones can also scan or type a code.
class QrScreen extends StatefulWidget {
  const QrScreen({super.key, this.startWithScan = false});
  final bool startWithScan;

  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> {
  PairingCode? _code;
  DateTime _createdAt = DateTime.now();
  Timer? _tick;
  PeerRecord? _connected;
  final _typed = TextEditingController();
  String? _typedError;
  bool _busy = false;
  ReceiveManager? _receiver;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_code == null) {
      _receiver = context.services.node.receiver;
      _refresh();
      _receiver!.onPaired = (p) {
        if (!mounted) return;
        final live = p.addresses.firstOrNull;
        if (live != null) {
          context.services.discovery.addReachable(
            DeviceInfo(fingerprint: p.fingerprint, name: p.name, platform: p.platform, port: p.port),
            live,
          );
        }
        setState(() => _connected = p);
      };
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_left <= Duration.zero && _connected == null) _refresh();
        setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _receiver
      ?..onPaired = null
      ..clearPairingSecret();
    _typed.dispose();
    super.dispose();
  }

  Duration get _left => kPairingSecretTtl - DateTime.now().difference(_createdAt);

  void _refresh() {
    final s = context.services;
    final secret = s.node.receiver.newPairingSecret();
    _createdAt = DateTime.now();
    _code = PairingCode(
      addresses: s.discovery.network.addresses.map((a) => a.ip).take(3).toList(),
      port: s.node.port,
      fingerprint: s.node.fingerprint,
      secret: secret,
      name: s.node.settings.value.deviceName,
    );
    setState(() {});
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (raw == null || !mounted) return;
    final s = context.services;
    setState(() => _busy = true);
    try {
      final peer = await s.node.pairWithCode(PairingCode.parse(raw));
      s.discovery.addReachable(
        DeviceInfo(fingerprint: peer.fingerprint, name: peer.name, platform: peer.platform, port: peer.port),
        peer.addresses.first,
      );
      if (mounted) setState(() => _connected = peer);
    } on KfError catch (e) {
      if (mounted) {
        setState(() => _typedError = e.code == KfErrorCode.badSecret
            ? 'This code has expired. Show a new one on the other device.'
            : errorText(e.code, device: 'that device'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectTyped() async {
    final s = context.services;
    final mine = s.discovery.network.primaryIp;
    final parsed = mine == null ? null : parseShortCode(_typed.text, mine);
    if (parsed == null) {
      setState(() => _typedError = 'Type the code shown on the other device, like 23-482913.');
      return;
    }
    setState(() {
      _busy = true;
      _typedError = null;
    });
    try {
      final peer = await s.node.pairWithShortCode(parsed.host, parsed.secret);
      s.discovery.addReachable(
        DeviceInfo(fingerprint: peer.fingerprint, name: peer.name, platform: peer.platform, port: peer.port),
        parsed.host,
      );
      if (mounted) setState(() => _connected = peer);
    } on KfError catch (e) {
      setState(() => _typedError = e.code == KfErrorCode.badSecret || e.code == KfErrorCode.notFound
          ? 'This code has expired or is wrong. Show a new one on the other device.'
          : errorText(e.code, device: 'that device'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final kf = KfColors.of(context);
    final code = _code;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect with a QR code')),
      body: ListView(
        padding: const EdgeInsets.all(KfSpace.gutter),
        children: [
          if (_connected != null)
            KfBanner(
              tone: BannerTone.success,
              title: 'Connected to ${_connected!.displayName}',
              text: 'You can send files both ways now. No code check needed.',
              action: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            )
          else if (code == null || code.addresses.isEmpty)
            const KfBanner(
              tone: BannerTone.warning,
              title: 'Not on a network',
              text: 'Connect to Wi-Fi or a hotspot first, then show the code.',
            )
          else ...[
            Text(
              isDesktop ? 'Scan this with kickFile on your phone' : 'Scan this with kickFile on the other device',
              style: tt.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: KfSpace.s4),
            Center(
              child: Container(
                padding: const EdgeInsets.all(KfSpace.s3),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(KfRadius.md)),
                child: Semantics(
                  label: 'QR code to connect to this device',
                  child: QrImageView(data: code.toUri(), size: 220, backgroundColor: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: KfSpace.s4),
            if (code.shortCode != null) ...[
              Text('No camera? Type this code on the other device:', style: tt.bodySmall, textAlign: TextAlign.center),
              const SizedBox(height: KfSpace.s2),
              Center(child: CodeDisplay(code.shortCode!, size: 24)),
            ],
            const SizedBox(height: KfSpace.s3),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(LucideIcons.clock, size: 14, color: kf.textTertiary),
                const SizedBox(width: 6),
                Text('New code in ${formatCountdown(_left)}', style: tt.bodySmall),
                TextButton(onPressed: _refresh, child: const Text('Refresh')),
              ],
            ),
          ],
          if (Platform.isAndroid || Platform.isIOS) ...[
            const SizedBox(height: KfSpace.s4),
            FilledButton.icon(
              onPressed: _scan,
              icon: const Icon(LucideIcons.scanLine, size: 18),
              label: const Text('Scan a code on the other device'),
            ),
          ],
          const SizedBox(height: KfSpace.s6),
          const Divider(),
          const SizedBox(height: KfSpace.s4),
          Text('Have a code from another device?', style: tt.titleMedium),
          const SizedBox(height: KfSpace.s2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _typed,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(hintText: '23-482913', errorText: _typedError, errorMaxLines: 3),
                  onSubmitted: (_) => _connectTyped(),
                ),
              ),
              const SizedBox(width: KfSpace.s2),
              FilledButton(
                onPressed: _busy ? null : _connectTyped,
                child: _busy
                    ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                    : const Text('Connect'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
