// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../storage/peers.dart';
import '../scope.dart';
import '../theme/tokens.dart';

/// Mobile: tap a device → choose what to send (tap 2 of 3, US-004, M-03).
Future<void> showSourceSheet(BuildContext context, PeerRecord peer) async {
  final ui = context.ui;
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(KfSpace.s2, 0, KfSpace.s2, KfSpace.s2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(KfSpace.s3, 0, KfSpace.s3, KfSpace.s2),
              child: Text('Send to ${peer.displayName}', style: Theme.of(c).textTheme.titleMedium),
            ),
            _option(c, 'media', LucideIcons.image, 'Photos & videos'),
            _option(c, 'files', LucideIcons.file, 'Files'),
            if (Platform.isAndroid || Platform.isMacOS || Platform.isWindows || Platform.isLinux)
              _option(c, 'folder', LucideIcons.folder, 'Folder'),
            _option(c, 'text', LucideIcons.type, 'Text'),
          ],
        ),
      ),
    ),
  );
  switch (choice) {
    case 'media':
      await ui.pickMediaFor(peer);
    case 'files':
      await ui.pickFilesFor(peer);
    case 'folder':
      await ui.pickFolderFor(peer);
    case 'text':
      await ui.textFor(peer);
  }
}

Widget _option(BuildContext c, String value, IconData icon, String label) => ListTile(
  leading: Icon(icon, color: Theme.of(c).colorScheme.primary),
  title: Text(label),
  onTap: () => Navigator.pop(c, value),
);
