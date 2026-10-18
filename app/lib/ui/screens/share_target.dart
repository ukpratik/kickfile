import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/protocol.dart';
import '../../transfer/file_access.dart';
import '../format.dart';
import '../scope.dart';
import '../theme/tokens.dart';
import 'connection_help.dart';

/// Shared into kickFile from another app (US-009): pick the device, one tap sends.
Future<void> showShareTarget(BuildContext context, List<SendSource> sources) async {
  final s = context.services;
  final ui = context.ui;
  final files = sources.where((x) => x.kind == ItemKind.file).toList();
  final total = files.fold(0, (a, f) => a + f.size);
  final what = files.isEmpty ? 'text' : '${countFiles(files.length, names: files.map((f) => f.name))} · ${formatBytes(total)}';
  await showModalBottomSheet<void>(
    context: context,
    builder: (c) => ListenableBuilder(
      listenable: s.discovery,
      builder: (c, _) {
        final online = s.discovery.devices.where((e) => e.$2?.online ?? false).map((e) => e.$1).toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(KfSpace.s2, 0, KfSpace.s2, KfSpace.s2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(KfSpace.s3, 0, KfSpace.s3, KfSpace.s2),
                  child: Text('Send $what to…', style: Theme.of(c).textTheme.titleMedium),
                ),
                if (online.isEmpty)
                  ListTile(
                    leading: const Icon(LucideIcons.radar),
                    title: const Text('Looking for devices…'),
                    subtitle: const Text("Open kickFile on the other device. Don't see it?"),
                    onTap: () {
                      Navigator.pop(c);
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectionHelpScreen()));
                    },
                  ),
                for (final p in online)
                  ListTile(
                    leading: Icon(platformIcon(p.platform), color: Theme.of(c).colorScheme.primary),
                    title: Text(p.displayName),
                    subtitle: Text(p.platform.label),
                    onTap: () {
                      Navigator.pop(c);
                      ui.send(p, sources);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
