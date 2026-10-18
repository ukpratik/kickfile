import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/protocol.dart';
import '../../storage/history.dart';
import '../format.dart';
import '../scope.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'common.dart';

/// One line of Recent / History (US-014).
class ActivityRow extends StatelessWidget {
  const ActivityRow({super.key, required this.entry});
  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final ui = context.ui;
    final cs = Theme.of(context).colorScheme;
    final kf = KfColors.of(context);
    final tt = Theme.of(context).textTheme;
    final incoming = e.direction == Direction.incoming;
    final files = e.items.where((i) => i.kind == ItemKind.file).toList();
    final text = e.items.where((i) => i.kind == ItemKind.text).firstOrNull;
    final single = files.length == 1 ? files.first : null;

    final what = text != null && files.isEmpty
        ? '“${_short(text.text ?? '')}”'
        : single != null
        ? single.name.split('/').last
        : countFiles(e.fileCount, names: files.map((f) => f.name));

    final title = switch (e.status) {
      HistoryStatus.missed when incoming => '${e.peerName} tried to send ${countFiles(e.fileCount)}',
      _ => incoming ? '$what from ${e.peerName}' : '$what to ${e.peerName}',
    };

    final (IconData icon, Color? iconColor, Color? bg) = switch (e.status) {
      HistoryStatus.done || HistoryStatus.active || HistoryStatus.waiting =>
        (incoming ? LucideIcons.arrowDownToLine : LucideIcons.arrowUpFromLine, null, null),
      HistoryStatus.paused => (LucideIcons.pause, kf.warning, kf.warningSoft),
      HistoryStatus.missed => (LucideIcons.clock, kf.warning, kf.warningSoft),
      HistoryStatus.partial || HistoryStatus.expired => (LucideIcons.triangleAlert, kf.warning, kf.warningSoft),
      _ => (LucideIcons.circleX, cs.onSurfaceVariant, null),
    };

    final statusWord = switch (e.status) {
      HistoryStatus.done => incoming ? 'Received' : 'Sent',
      HistoryStatus.active => incoming ? 'Receiving' : 'Sending',
      HistoryStatus.waiting => 'Waiting',
      HistoryStatus.paused => 'Paused',
      HistoryStatus.partial => '${e.doneFiles} of ${e.fileCount} ${incoming ? 'received' : 'sent'}',
      HistoryStatus.expired => "Didn't finish · ${e.doneFiles} of ${e.fileCount} files received",
      HistoryStatus.failed => "Didn't send",
      HistoryStatus.cancelled => 'Cancelled',
      HistoryStatus.declined => 'Declined',
      HistoryStatus.missed => 'Missed',
      HistoryStatus.busy => 'Busy',
    };
    final meta = [
      statusWord,
      if (e.totalBytes > 0) formatBytes(e.totalBytes),
      formatWhen(e.finishedAt ?? e.startedAt),
    ].join(' · ');

    Widget? action;
    if (incoming && e.status == HistoryStatus.done || e.status == HistoryStatus.partial && incoming) {
      if (text != null && files.isEmpty) {
        action = FilledButton.tonal(onPressed: () => copyText(context, text.text ?? ''), child: const Text('Copy'));
      } else if (single?.location != null) {
        action = FilledButton.tonal(onPressed: () => ui.open(single!.location), child: const Text('Open'));
      } else if (files.isNotEmpty && files.first.location != null) {
        action = TextButton(onPressed: () => ui.reveal(files.first.location), child: const Text('Show'));
      }
    }

    return InkWell(
      onTap: () => _openDetails(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, isDesktop ? 6 : 10, 12, isDesktop ? 6 : 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: bg ?? cs.surfaceContainerHigh, shape: BoxShape.circle),
              child: Icon(icon, size: 16, color: iconColor ?? cs.onSurfaceVariant),
            ),
            const SizedBox(width: KfSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyLarge!.copyWith(fontWeight: FontWeight.w600)),
                  Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall!.copyWith(color: iconColor ?? tt.bodySmall!.color)),
                ],
              ),
            ),
            if (action != null) ...[const SizedBox(width: KfSpace.s2), action],
          ],
        ),
      ),
    );
  }

  void _openDetails(BuildContext context) {
    final e = entry;
    final ui = context.ui;
    final items = e.items.where((i) => i.kind != ItemKind.dir).toList();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                e.direction == Direction.incoming ? 'From ${e.peerName}' : 'To ${e.peerName}',
                style: Theme.of(c).textTheme.titleMedium,
              ),
              const SizedBox(height: KfSpace.s2),
              for (final i in items.take(200))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(i.kind == ItemKind.text ? LucideIcons.messageSquareText : fileIcon(i.name)),
                  title: Text(i.kind == ItemKind.text ? (i.text ?? '') : i.name, maxLines: 3, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    i.kind == ItemKind.text ? 'Text' : '${formatBytes(i.size)}${i.ok ? '' : ' · ${i.error == null ? 'not received' : errorText(null)}'}',
                  ),
                  onTap: i.kind == ItemKind.text
                      ? () => copyText(c, i.text ?? '')
                      : (i.location == null ? null : () => ui.open(i.location)),
                  trailing: i.location == null
                      ? null
                      : IconButton(tooltip: ui.revealLabel, icon: const Icon(LucideIcons.folderOpen), onPressed: () => ui.reveal(i.location)),
                ),
              if (items.length > 200) Text('and ${items.length - 200} more', style: Theme.of(c).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  String _short(String t) {
    final one = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 40 ? '${one.substring(0, 40)}…' : one;
  }
}
