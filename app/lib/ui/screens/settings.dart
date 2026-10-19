import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../core/log.dart';
import '../../core/protocol.dart';
import '../../storage/settings.dart';
import '../format.dart';
import '../scope.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'connection_help.dart';

/// Settings (US-015, M-13 / D-07). Desktop: an in-window page.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.node.settings, s.node.peers]),
      builder: (context, _) {
        final v = s.node.settings.value;
        final tt = Theme.of(context).textTheme;
        final trusted = s.node.peers.trusted.toList();
        final blocked = s.node.peers.blocked.toList();
        Future<void> set(Settings Function(Settings) f) => s.node.settings.update(f);

        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(KfSpace.gutter, 0, KfSpace.gutter, KfSpace.s8),
            children: [
              const SectionLabel('This device'),
              GroupCard(
                children: [
                  ListTile(
                    title: const Text('Name'),
                    subtitle: Text(v.deviceName),
                    trailing: const Icon(LucideIcons.chevronRight, size: 18),
                    onTap: () => _rename(context),
                  ),
                  SwitchListTile(
                    title: const Text('Visible to nearby devices'),
                    subtitle: Text(
                      v.visible
                          ? 'Devices on this Wi-Fi can find this one.'
                          : 'Hidden. Trusted devices and QR codes still work.',
                    ),
                    value: v.visible,
                    onChanged: (on) async {
                      await set((x) => x.copyWith(visible: on));
                      await s.discovery.updateBroadcast();
                    },
                  ),
                ],
              ),
              const SectionLabel('Receiving'),
              GroupCard(
                children: [
                  // BUG-013: Android picks these folders so the gallery and Files find them.
                  if (Platform.isAndroid) ...const [
                    ListTile(title: Text('Photos and videos'), subtitle: Text('Pictures/kickFile · Movies/kickFile')),
                    ListTile(title: Text('Other files'), subtitle: Text('Download/kickFile')),
                  ],
                  if (isDesktop)
                    ListTile(
                      title: const Text('Save files to'),
                      subtitle: Text(s.saveDir, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: TextButton(onPressed: () => _chooseFolder(context), child: const Text('Change')),
                    ),
                  if (isDesktop && v.saveDir != null)
                    ListTile(
                      title: const Text('Use the default folder'),
                      subtitle: Text(s.defaultSaveDir),
                      onTap: () => s.setSaveDir(null),
                    ),
                  if (Platform.isMacOS || Platform.isWindows)
                    SwitchListTile(
                      title: Text(Platform.isMacOS ? 'Show received files in Finder' : 'Show received files in their folder'),
                      value: v.revealAutomatically,
                      onChanged: (on) => set((x) => x.copyWith(revealAutomatically: on)),
                    ),
                  if (isDesktop)
                    SwitchListTile(
                      title: const Text('Keep receiving when the window is closed'),
                      subtitle: Text(Platform.isMacOS ? 'kickFile stays in the menu bar.' : 'kickFile stays running in the background.'),
                      value: v.keepInBackground,
                      onChanged: (on) => set((x) => x.copyWith(keepInBackground: on)),
                    ),
                  if (Platform.isWindows || Platform.isLinux)
                    SwitchListTile(
                      title: const Text('Start kickFile when you sign in'),
                      value: v.launchAtLogin,
                      onChanged: (on) async {
                        final shell = context.ui.shell;
                        await set((x) => x.copyWith(launchAtLogin: on));
                        await shell?.setLaunchAtLogin(on);
                      },
                    ),
                ],
              ),
              const SectionLabel('Trusted devices'),
              if (trusted.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('Devices you trust can send without the code check. Choose Trust when one sends you something.', style: tt.bodySmall),
                )
              else
                GroupCard(
                  children: [
                    for (final t in trusted)
                      ListTile(
                        leading: Icon(platformIcon(t.platform)),
                        title: Text(t.displayName),
                        subtitle: Text(t.autoAccept ? '${t.platform.label} · Auto-accept' : t.platform.label),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Options',
                          onSelected: (a) async {
                            if (a == 'auto') {
                              await s.node.peers.update(t.fingerprint, (p) => p.copyWith(autoAccept: !p.autoAccept));
                            } else if (a == 'forget') {
                              await s.node.peers.forget(t.fingerprint);
                            }
                          },
                          itemBuilder: (_) => [
                            CheckedPopupMenuItem(value: 'auto', checked: t.autoAccept, child: const Text('Auto-accept')),
                            const PopupMenuItem(value: 'forget', child: Text('Forget')),
                          ],
                        ),
                      ),
                  ],
                ),
              if (blocked.isNotEmpty) ...[
                const SectionLabel('Blocked devices'),
                GroupCard(
                  children: [
                    for (final b in blocked)
                      ListTile(
                        leading: Icon(platformIcon(b.platform)),
                        title: Text(b.displayName),
                        subtitle: Text(b.platform.label),
                        trailing: TextButton(
                          onPressed: () => s.node.peers.update(b.fingerprint, (p) => p.copyWith(blocked: false)),
                          child: const Text('Unblock'),
                        ),
                      ),
                  ],
                ),
              ],
              const SectionLabel('Appearance'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(KfSpace.s3),
                  child: SegmentedButton<ThemeChoice>(
                    segments: const [
                      ButtonSegment(value: ThemeChoice.system, label: Text('System')),
                      ButtonSegment(value: ThemeChoice.light, label: Text('Light')),
                      ButtonSegment(value: ThemeChoice.dark, label: Text('Dark')),
                    ],
                    selected: {v.theme},
                    onSelectionChanged: (sel) => set((x) => x.copyWith(theme: sel.first)),
                  ),
                ),
              ),
              const SectionLabel('Help'),
              GroupCard(
                children: [
                  ListTile(
                    leading: const Icon(LucideIcons.circleQuestionMark),
                    title: const Text('Connection help'),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectionHelpScreen())),
                  ),
                  ListTile(
                    leading: const Icon(LucideIcons.fileText),
                    title: const Text('Export logs'),
                    subtitle: const Text('Saves a diagnostic file you can choose to share. No file names inside.'),
                    onTap: () => _exportLogs(context),
                  ),
                  ListTile(
                    leading: const Icon(LucideIcons.lock),
                    title: const Text('Privacy'),
                    onTap: () => _privacy(context),
                  ),
                  ListTile(
                    leading: const Icon(LucideIcons.info),
                    title: const Text('About kickFile'),
                    subtitle: Text('Version 1.0.0 · protocol v$kProtocolVersion'),
                    onTap: () => showLicensePage(context: context, applicationName: 'kickFile', applicationVersion: '1.0.0'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _rename(BuildContext context) async {
    final s = context.services;
    final c = TextEditingController(text: s.node.settings.value.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: kMaxNameChars,
          decoration: const InputDecoration(helperText: 'Name it so your other devices recognise it.'),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await s.node.settings.update((x) => x.copyWith(deviceName: cleanDeviceName(name)));
    await s.discovery.updateBroadcast();
  }

  Future<void> _chooseFolder(BuildContext context) async {
    final s = context.services;
    final dir = await getDirectoryPath(initialDirectory: s.saveDir, confirmButtonText: 'Save here');
    if (dir != null) await s.setSaveDir(dir);
  }

  Future<void> _exportLogs(BuildContext context) async {
    final ui = context.ui;
    final fa = context.services.files;
    final files = log.files();
    if (files.isEmpty) {
      ui.toast('No logs yet.');
      return;
    }
    try {
      final text = StringBuffer();
      for (final f in files) {
        text.write(await f.readAsString());
      }
      final bytes = utf8.encode(text.toString());
      if (Platform.isAndroid) {
        // BUG-014: no save dialog on Android; write to Download/kickFile like a received file.
        final ref = await fa.createPartial('logs', 'logs', 'kickfile-logs.txt', bytes.length);
        final w = await fa.openPartial(ref, 0);
        await w.add(bytes);
        await w.close();
        await fa.finalize(ref, 'kickfile-logs.txt');
        ui.toast('Logs saved to Download/kickFile');
        return;
      }
      final loc = await getSaveLocation(suggestedName: 'kickfile-logs.txt');
      if (loc == null) return;
      await File(loc.path).writeAsBytes(bytes, flush: true);
      ui.toast('Logs saved to ${p.basename(loc.path)}');
    } catch (_) {
      ui.toast("Couldn't save the logs. Try again.");
    }
  }

  void _privacy(BuildContext context) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Privacy'),
      content: const SingleChildScrollView(
        child: Text(
          'kickFile has no account and no servers. Files go straight from one of your devices to another over your local network, encrypted.\n\n'
          'Nearby devices on the same network can see this device’s name while it’s visible.\n\n'
          'History, trusted devices and settings stay on this device. kickFile collects no analytics.',
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
    ),
  );
}
