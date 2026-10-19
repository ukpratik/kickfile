// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../scope.dart';
import '../theme/tokens.dart';
import '../widgets/activity_row.dart';
import '../widgets/common.dart';

/// Everything sent and received, newest first, kept 90 days / 500 entries (US-014, M-11).
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final history = context.services.node.history;
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final entries = history.entries;
        return Scaffold(
          appBar: AppBar(
            title: const Text('History'),
            actions: [
              if (entries.isNotEmpty)
                TextButton(onPressed: () => _clear(context), child: const Text('Clear history')),
              const SizedBox(width: KfSpace.s2),
            ],
          ),
          body: entries.isEmpty
              ? const Center(
                  child: EmptyState(
                    icon: LucideIcons.history,
                    title: 'Nothing here yet',
                    text: 'Files and text you send and receive show up here.',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(KfSpace.gutter),
                  children: [
                    GroupCard(children: [for (final e in entries) ActivityRow(entry: e)]),
                    const SizedBox(height: KfSpace.s3),
                    Text(
                      'Kept on this device for 90 days. Clearing history doesn’t delete any files.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
        );
      },
    );
  }

  Future<void> _clear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('The list is cleared. Received files stay where they are.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true && context.mounted) await context.services.node.history.clear();
  }
}
