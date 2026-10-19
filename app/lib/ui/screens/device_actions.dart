// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../storage/peers.dart';
import '../scope.dart';
import '../theme/theme.dart';

/// Long-press (mobile) / right-click (desktop) on a device row (US-010, M-12).
Future<void> showDeviceActions(BuildContext context, PeerRecord peer, Offset position) async {
  final s = context.services;
  final ui = context.ui;
  final online = ui.isOnline(peer);
  final items = <PopupMenuEntry<String>>[
    if (online) ...[
      const PopupMenuItem(value: 'files', child: Text('Send files…')),
      if (isDesktop) const PopupMenuItem(value: 'folder', child: Text('Send a folder…')),
      const PopupMenuItem(value: 'text', child: Text('Send text…')),
      const PopupMenuDivider(),
    ],
    if (peer.trusted)
      CheckedPopupMenuItem(value: 'auto', checked: peer.autoAccept, child: const Text('Auto-accept'))
    else
      const PopupMenuItem(value: 'trust', child: Text('Trust this device')),
    const PopupMenuItem(value: 'rename', child: Text('Rename…')),
    const PopupMenuItem(value: 'forget', child: Text('Forget')),
    PopupMenuItem(
      value: 'block',
      child: Text('Block…', style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ),
  ];
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final v = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    items: items,
  );
  if (!context.mounted || v == null) return;
  final peers = s.node.peers;
  switch (v) {
    case 'files':
      await ui.pickFilesFor(peer);
    case 'folder':
      await ui.pickFolderFor(peer);
    case 'text':
      await ui.textFor(peer);
    case 'auto':
      await peers.update(peer.fingerprint, (p) => p.copyWith(autoAccept: !p.autoAccept));
    case 'trust':
      await peers.update(peer.fingerprint, (p) => p.copyWith(trusted: true));
    case 'rename':
      final name = await _rename(context, peer);
      if (name != null) {
        await peers.update(peer.fingerprint, (p) => name.isEmpty ? p.copyWith(clearAlias: true) : p.copyWith(alias: name));
      }
    case 'forget':
      await peers.forget(peer.fingerprint);
      ui.toast('Forgot ${peer.displayName}. It will need to be accepted again.');
    case 'block':
      if (await confirmBlock(context, peer.displayName)) {
        await peers.update(peer.fingerprint, (p) => p.copyWith(blocked: true, trusted: false, autoAccept: false));
        ui.toast('Blocked ${peer.displayName}. Unblock it in Settings.');
      }
  }
}

Future<bool> confirmBlock(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Block $name?'),
        content: const Text('It won’t be able to send you anything. You can unblock it in Settings › Blocked devices.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Block'),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> _rename(BuildContext context, PeerRecord peer) {
  final c = TextEditingController(text: peer.displayName);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Rename device'),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(helperText: 'Only on this device. It announces itself as “${peer.name}”.'),
        onSubmitted: (v) => Navigator.pop(d, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, ''), child: const Text('Use its own name')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}
