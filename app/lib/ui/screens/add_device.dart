// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/protocol.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'qr_screen.dart';

/// Download page (site/index.html): detects the visitor's OS and offers the right file. No tracking.
const kDownloadUrl = 'https://ukpratik.github.io/kickfile';
const kReleasesUrl = 'https://github.com/ukpratik/kickfile/releases/latest';

/// One way to install kickFile. [url] null means "Coming soon".
class InstallChannel {
  const InstallChannel(this.name, this.detail, {this.url});
  final String name;
  final String detail;
  final String? url;
}

class InstallPlatform {
  const InstallPlatform(this.platform, this.name, this.meta, this.icon, this.channels, {this.note, this.tip});
  final DevicePlatform platform;
  final String name;
  final String meta;
  final IconData icon;
  final List<InstallChannel> channels;
  final String? note;
  final (String, String)? tip;
}

/// Static on purpose: when a store listing goes live, give its channel a url (D-10, §8a).
const kInstallChannels = [
  InstallPlatform(DevicePlatform.android, 'Android phone', 'Android 8.0+ · APK', LucideIcons.smartphone, [
    InstallChannel('APK file', 'From GitHub Releases', url: kReleasesUrl),
    InstallChannel('F-Droid', 'Free and open-source app store'),
    InstallChannel('IzzyOnDroid', 'F-Droid compatible repository'),
    InstallChannel('Google Play', 'Play Store'),
  ], note: 'Needs Android 8.0 or later.'),
  InstallPlatform(
    DevicePlatform.macos,
    'Mac',
    'macOS 12+ · DMG',
    LucideIcons.laptop,
    [InstallChannel('DMG', 'From GitHub Releases', url: kReleasesUrl), InstallChannel('Homebrew', 'brew install --cask ukpratik/tap/kickfile', url: 'https://github.com/ukpratik/homebrew-tap')],
    note: 'Needs macOS 12 or later.',
    tip: ('First time you open it', 'macOS may block it. Go to System Settings › Privacy & Security › Open Anyway.'),
  ),
  InstallPlatform(DevicePlatform.windows, 'Windows PC', 'Windows 10/11 · Installer', LucideIcons.monitor, [
    InstallChannel('Installer or zip', 'From GitHub Releases', url: kReleasesUrl),
    InstallChannel('Scoop', 'scoop install ukpratik/kickfile', url: 'https://github.com/ukpratik/scoop-bucket'),
    InstallChannel('winget', 'winget install kickFile'),
    InstallChannel('Microsoft Store', 'Store app'),
  ], note: 'Needs Windows 10 or 11, 64-bit.'),
  InstallPlatform(DevicePlatform.linux, 'Linux PC', 'x64 · tar.gz', LucideIcons.monitor, [
    InstallChannel('tar.gz bundle', 'From GitHub Releases', url: kReleasesUrl),
    InstallChannel('Flathub', 'Flatpak'),
  ], note: 'Needs a 64-bit (x64) PC.'),
];

DevicePlatform get _thisPlatform => Platform.isAndroid
    ? DevicePlatform.android
    : Platform.isMacOS
    ? DevicePlatform.macos
    : Platform.isWindows
    ? DevicePlatform.windows
    : Platform.isLinux
    ? DevicePlatform.linux
    : DevicePlatform.ios;

/// "Get kickFile on your other devices" (US-019, M-15 / D-10). Replaces the M-10 sheet.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key, this.current, this.expanded = const {}});

  /// The platform this runs on; tests and renders override it.
  final DevicePlatform? current;

  /// Rows open at start (renders).
  final Set<DevicePlatform> expanded;

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  late final _open = {...widget.expanded};

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final current = widget.current ?? _thisPlatform;
    final others = kInstallChannels.where((p) => p.platform != current);
    final mine = kInstallChannels.where((p) => p.platform == current);
    return Scaffold(
      appBar: AppBar(title: const Text('Add a device')),
      body: ListView(
        padding: const EdgeInsets.all(KfSpace.gutter),
        children: [
          Text('Get kickFile on your other devices', style: tt.titleLarge),
          const SizedBox(height: KfSpace.s1),
          Text('Free, no account. Install it on the device you want to share files with.', style: tt.bodyMedium),
          const SizedBox(height: KfSpace.s4),
          _LinkCard(desktop: isDesktop),
          const SectionLabel('Or pick the device'),
          GroupCard(
            children: [
              for (final p in others) _platformRow(p),
              ListTile(
                minVerticalPadding: KfSpace.s3,
                leading: _tile(context, LucideIcons.smartphone),
                title: const Text('iPhone & iPad'),
                subtitle: const Text('Not available yet'),
                trailing: const _SoonChip('Coming later'),
              ),
              for (final p in mine) _platformRow(p, mine: true),
            ],
          ),
          const SizedBox(height: KfSpace.s4),
          KfBanner(
            tone: BannerTone.neutral,
            title: 'After installing',
            text: "Open kickFile on both devices, on the same Wi-Fi or your phone's hotspot. They find each other by themselves.",
            action: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 40), foregroundColor: cs.primary),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QrScreen())),
              child: const Text('Connect with a QR code'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _platformRow(InstallPlatform p, {bool mine = false}) {
    final open = _open.contains(p.platform);
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          expanded: open,
          child: ListTile(
            minVerticalPadding: KfSpace.s3,
            leading: _tile(context, p.icon, muted: mine),
            title: Text(p.name, style: mine ? TextStyle(color: cs.onSurfaceVariant) : null),
            subtitle: Text(mine ? "You're using it" : p.meta),
            trailing: AnimatedRotation(turns: open ? .5 : 0, duration: KfMotion.base, child: const Icon(LucideIcons.chevronDown, size: 20)),
            onTap: () => setState(() => open ? _open.remove(p.platform) : _open.add(p.platform)),
          ),
        ),
        AnimatedSize(
          duration: KfMotion.base,
          curve: KfMotion.standard,
          alignment: Alignment.topCenter,
          child: !open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(64, 0, KfSpace.s4, KfSpace.s3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in p.channels) _channel(c),
                      if (p.note != null)
                        Padding(
                          padding: const EdgeInsets.only(top: KfSpace.s1),
                          child: Text(p.note!, style: tt.bodySmall),
                        ),
                      if (p.tip != null)
                        Padding(
                          padding: const EdgeInsets.only(top: KfSpace.s2),
                          child: KfBanner(tone: BannerTone.info, title: p.tip!.$1, text: p.tip!.$2),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _channel(InstallChannel c) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final live = c.url != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KfSpace.s1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name, style: tt.titleSmall!.copyWith(color: live ? cs.onSurface : cs.onSurfaceVariant)),
                Text(c.detail, style: tt.bodySmall),
              ],
            ),
          ),
          if (live)
            TextButton(
              style: TextButton.styleFrom(minimumSize: Size(0, isDesktop ? 36 : 48)),
              onPressed: () => copyText(context, c.url!, done: 'Link copied. Open it on the other device.'),
              child: const Text('Copy link'),
            )
          else
            const _SoonChip('Coming soon'),
        ],
      ),
    );
  }
}

Widget _tile(BuildContext context, IconData icon, {bool muted = false}) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(color: muted ? cs.surfaceContainerHigh : cs.secondaryContainer, borderRadius: BorderRadius.circular(KfRadius.sm)),
    child: Icon(icon, size: 20, color: muted ? cs.onSurfaceVariant : cs.onSecondaryContainer),
  );
}

class _SoonChip extends StatelessWidget {
  const _SoonChip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: KfSpace.s2, vertical: 3),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(KfRadius.xs)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.clock, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text, style: Theme.of(context).textTheme.labelSmall!.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// QR + copyable link: the one primary path. Desktop puts the QR beside the text.
class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.desktop});
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final qr = Container(
      padding: const EdgeInsets.all(KfSpace.s2),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(KfRadius.md)),
      child: QrImageView(
        data: kDownloadUrl,
        size: desktop ? 112 : 176,
        backgroundColor: Colors.white,
        semanticsLabel: 'QR code for ukpratik.github.io/kickfile',
      ),
    );
    final caption = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: desktop ? 'Scan with your phone. ' : "Scan with your other phone's camera, ",
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: desktop ? 'Or open the link on another computer. ' : 'or open the link on a computer. '),
          const TextSpan(text: 'The page picks the right download.'),
        ],
      ),
      style: tt.bodyMedium,
      textAlign: desktop ? TextAlign.start : TextAlign.center,
    );
    final link = Wrap(
      spacing: KfSpace.s2,
      runSpacing: KfSpace.s2,
      alignment: desktop ? WrapAlignment.start : WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SelectableText('ukpratik.github.io/kickfile', style: tt.bodyLarge!.copyWith(fontWeight: FontWeight.w600)),
        FilledButton.tonalIcon(
          onPressed: () => copyText(context, kDownloadUrl, done: 'Link copied. Open it on the other device.'),
          icon: const Icon(LucideIcons.copy, size: 16),
          label: const Text('Copy link'),
        ),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KfSpace.s4),
        child: desktop
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  qr,
                  const SizedBox(width: KfSpace.s4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        caption,
                        const SizedBox(height: KfSpace.s3),
                        link,
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  qr,
                  const SizedBox(height: KfSpace.s3),
                  caption,
                  const SizedBox(height: KfSpace.s3),
                  link,
                ],
              ),
      ),
    );
  }
}
