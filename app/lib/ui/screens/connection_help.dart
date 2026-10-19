// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../net/netinfo.dart';
import '../scope.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'qr_screen.dart';

/// "Don't see your device?" (US-011, D-06 / M-09). No jargon anywhere.
class ConnectionHelpScreen extends StatefulWidget {
  const ConnectionHelpScreen({super.key});

  @override
  State<ConnectionHelpScreen> createState() => _ConnectionHelpScreenState();
}

class _ConnectionHelpScreenState extends State<ConnectionHelpScreen> {
  NetworkState? _net;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final n = await readNetwork();
    if (!mounted) return;
    setState(() {
      _net = n;
      _checking = false;
    });
    await context.services.discovery.refresh();
  }

  /// Windows: add inbound rules for kickFile on private and public networks (US-011 v2.2).
  Future<void> _allowFirewall() async {
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    final rule = "netsh advfirewall firewall add rule name='kickFile' dir=in action=allow program='$exe' enable=yes profile=private,public";
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        // Report netsh's own result, not the launcher's (BUG-019).
        '\$p = Start-Process -FilePath powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile","-Command","$rule; exit `\$LASTEXITCODE"; exit \$p.ExitCode',
      ]);
      if (!mounted) return;
      context.ui.toast(r.exitCode == 0
          ? 'kickFile is allowed. Try finding your device again.'
          : "Couldn't change the firewall. Ask an administrator to allow kickFile in Windows Security › Firewall.");
    } catch (_) {
      if (mounted) {
        context.ui.toast("Couldn't change the firewall. Ask an administrator to allow kickFile in Windows Security › Firewall.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final tt = Theme.of(context).textTheme;
    final net = _net;
    final visible = s.node.settings.value.visible;
    return Scaffold(
      appBar: AppBar(title: const Text("Don't see your device?")),
      body: ListView(
        padding: const EdgeInsets.all(KfSpace.gutter),
        children: [
          Text('Are both devices on the same Wi-Fi?', style: tt.titleMedium),
          const SizedBox(height: KfSpace.s1),
          Text(
            'Check the Wi-Fi settings on both. kickFile only finds devices on the same Wi-Fi or hotspot.',
            style: tt.bodyMedium,
          ),
          const SectionLabel('Checks'),
          GroupCard(
            children: [
              _CheckRow(
                running: _checking,
                ok: net != null && net.addresses.isNotEmpty,
                title: 'Connected to a network',
                problem: 'This device isn’t on Wi-Fi or Ethernet. Connect, or use a hotspot below.',
              ),
              _CheckRow(
                running: _checking,
                ok: net != null && !net.vpnActive,
                title: 'No VPN in the way',
                problem: 'A VPN is on. It may hide nearby devices. Turn it off while you send.',
              ),
              _CheckRow(
                running: false,
                ok: visible,
                title: 'This device is visible',
                problem: 'This device is hidden. Others can’t find it, but trusted devices and QR codes still work.',
                fix: TextButton(
                  onPressed: () async {
                    await s.node.settings.update((x) => x.copyWith(visible: true));
                    await s.discovery.updateBroadcast();
                    if (mounted) setState(() {});
                  },
                  child: const Text('Make visible'),
                ),
              ),
              if (Platform.isWindows)
                _ReminderRow(
                  icon: LucideIcons.shield,
                  title: 'Your laptop may be blocking kickFile',
                  text: 'If Windows asked about kickFile and you chose Cancel, allow it now. Windows will ask for an administrator.',
                  action: TextButton(onPressed: _allowFirewall, child: const Text('Allow it')),
                ),
              if (Platform.isLinux)
                const _ReminderRow(
                  icon: LucideIcons.shield,
                  title: 'Your firewall may be blocking kickFile',
                  text: 'If your computer asked about kickFile and you chose Cancel or Block, allow it in your firewall settings for private and public networks.',
                ),
              if (Platform.isMacOS)
                const _ReminderRow(
                  icon: LucideIcons.shield,
                  title: 'Allow local network access',
                  text: 'If macOS asked, choose Allow. Change it in System Settings › Privacy & Security › Local Network.',
                ),
              const _ReminderRow(
                icon: LucideIcons.smartphone,
                title: 'Is kickFile open on the other device?',
                text: 'Phones only receive while kickFile is open.',
              ),
              const _ReminderRow(
                icon: LucideIcons.network,
                title: 'Some networks keep devices apart',
                text: 'Office, hotel and public Wi-Fi often do. Use a QR code or your phone’s hotspot instead.',
              ),
            ],
          ),
          const SizedBox(height: KfSpace.s3),
          OutlinedButton.icon(onPressed: _check, icon: const Icon(LucideIcons.refreshCw, size: 18), label: const Text('Check again')),
          const SectionLabel('Still nothing?'),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QrScreen())),
            icon: const Icon(LucideIcons.qrCode, size: 18),
            label: const Text('Connect with a QR code'),
          ),
          const SectionLabel('No Wi-Fi? Use your phone’s hotspot'),
          const _HotspotGuide(),
          const SizedBox(height: KfSpace.s3),
          const KfBanner(
            tone: BannerTone.neutral,
            text: 'kickFile doesn’t use your mobile data. Other apps on your laptop might while it’s connected to your hotspot.',
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.running, required this.ok, required this.title, required this.problem, this.fix});
  final bool running, ok;
  final String title, problem;
  final Widget? fix;

  @override
  Widget build(BuildContext context) {
    final kf = KfColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(KfSpace.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 22,
            child: running
                ? const Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(ok ? LucideIcons.circleCheck : LucideIcons.triangleAlert, size: 20, color: ok ? kf.success : kf.warning),
          ),
          const SizedBox(width: KfSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tt.bodyLarge!.copyWith(fontWeight: FontWeight.w600)),
                Text(running ? 'Checking…' : (ok ? 'OK' : problem), style: tt.bodySmall),
                if (!running && !ok && fix != null) fix!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReminderRow extends StatelessWidget {
  const _ReminderRow({required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title, text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(KfSpace.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: KfSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tt.bodyLarge!.copyWith(fontWeight: FontWeight.w600)),
                Text(text, style: tt.bodySmall),
                ?action,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HotspotGuide extends StatefulWidget {
  const _HotspotGuide();
  @override
  State<_HotspotGuide> createState() => _HotspotGuideState();
}

class _HotspotGuideState extends State<_HotspotGuide> {
  String _phone = 'android';

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final steps = _phone == 'iphone'
        ? const [
            'On your iPhone, open Settings › Personal Hotspot and turn on Allow Others to Join.',
            'On your laptop, join the iPhone’s Wi-Fi network.',
            'Open kickFile on both. They find each other by themselves.',
          ]
        : const [
            'On your Android phone, open Settings › Network › Hotspot & tethering and turn on Wi-Fi hotspot.',
            'On your laptop, join the phone’s Wi-Fi network.',
            'Open kickFile on both. They find each other by themselves.',
          ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KfSpace.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'android', label: Text('Android phone')),
                ButtonSegment(value: 'iphone', label: Text('iPhone')),
              ],
              selected: {_phone},
              onSelectionChanged: (v) => setState(() => _phone = v.first),
            ),
            const SizedBox(height: KfSpace.s3),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: KfSpace.s2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(radius: 11, child: Text('${i + 1}', style: tt.labelMedium)),
                    const SizedBox(width: KfSpace.s3),
                    Expanded(child: Text(steps[i], style: tt.bodyMedium)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
