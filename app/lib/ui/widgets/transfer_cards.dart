import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/errors.dart';
import '../../core/protocol.dart';
import '../../core/sas.dart';
import '../../transfer/receiver.dart';
import '../../transfer/sender.dart';
import '../format.dart';
import '../scope.dart';
import '../theme/tokens.dart';
import 'common.dart';

/// The card for one outgoing transfer, in every state of the design (D-03).
class SendJobCard extends StatelessWidget {
  const SendJobCard({super.key, required this.job});
  final SendJob job;

  @override
  Widget build(BuildContext context) {
    final ui = context.ui;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final kf = KfColors.of(context);
    final peer = job.peerName;
    final what = job.fileCount == 0
        ? 'text'
        : countFiles(job.fileCount, names: job.items.map((i) => i.offerItem.path));
    final pct = job.totalBytes == 0 ? 0.0 : job.sentBytes / job.totalBytes;
    final trusted = context.services.node.peers.isTrusted(job.endpoint.fingerprint);

    Widget progress({Color? color}) => Padding(
      padding: const EdgeInsets.only(top: KfSpace.s3),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(value: pct, minHeight: 4, color: color),
      ),
    );

    Widget bytesLine(String right) => Padding(
      padding: const EdgeInsets.only(top: KfSpace.s2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${(pct * 100).floor()}% · ${formatBytes(job.sentBytes)} of ${formatBytes(job.totalBytes)}',
              style: tt.bodySmall!.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface),
            ),
          ),
          Text(right, style: tt.bodySmall),
        ],
      ),
    );

    final List<Widget> body;
    final List<Widget> actions;
    switch (job.state) {
      case SendState.waiting:
        final left = const Duration(seconds: 60) - DateTime.now().difference(job.startedAt);
        final first = job.items.first.offerItem;
        body = [
          _Title(icon: LucideIcons.hourglass, title: 'Waiting for $peer to accept…'),
          Text(
            job.fileCount == 0 ? 'Text' : (job.fileCount == 1 ? '${first.name} · ${formatBytes(job.totalBytes)}' : '$what · ${formatBytes(job.totalBytes)}'),
            style: tt.bodySmall,
          ),
          if (!trusted) ...[
            const SizedBox(height: KfSpace.s3),
            Text('$peer will ask you to check', style: tt.bodySmall),
            const SizedBox(height: KfSpace.s2),
            Row(
              children: [
                CodeDisplay(verificationCode(context.services.node.fingerprint, job.endpoint.fingerprint), size: 28),
                const Spacer(),
                Text(formatCountdown(left), style: tt.labelLarge),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: KfSpace.s2),
              child: Text(formatCountdown(left), style: tt.labelLarge),
            ),
        ];
        actions = [OutlinedButton(onPressed: job.cancel, child: const Text('Cancel'))];
      case SendState.active:
        final cur = job.current?.offerItem;
        final idx = job.current == null ? 0 : job.fileItems.toList().indexOf(job.current!) + 1;
        body = [
          _Title(icon: LucideIcons.arrowUpFromLine, title: 'Sending $what to $peer'),
          if (cur != null)
            Text(
              job.fileCount > 1 ? '${cur.name} · ${isImageName(cur.name) ? 'photo' : 'file'} $idx of ${job.fileCount}' : cur.name,
              style: tt.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          progress(),
          bytesLine('${formatSpeed(job.meter.bytesPerSecond)} · ${formatEta(job.meter.eta(job.totalBytes - job.sentBytes))}'),
          if (job.peerPlatform == DevicePlatform.ios || job.peerPlatform == DevicePlatform.android)
            Padding(
              padding: const EdgeInsets.only(top: KfSpace.s2),
              child: Row(
                children: [
                  Icon(LucideIcons.info, size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(child: Text('Keep kickFile open on $peer until this finishes', style: tt.bodySmall)),
                ],
              ),
            ),
        ];
        actions = [OutlinedButton(onPressed: () => _confirmCancel(context, job), child: const Text('Cancel'))];
      case SendState.paused:
        final waiting = job.waitingForResume;
        body = [
          _Title(
            icon: LucideIcons.pause,
            color: kf.warning,
            title: waiting ? 'Paused · $what to $peer' : 'Reconnecting to $peer…',
          ),
          Text(
            job.error?.code == KfErrorCode.noSpace
                ? '$peer is out of space. Free up some space and tap Resume.'
                : waiting
                ? 'Open kickFile on $peer, on the same Wi-Fi, then resume. Files already sent are skipped.'
                : 'Connection dropped · resumes by itself for 30 s',
            style: tt.bodySmall,
          ),
          progress(color: kf.warning),
          bytesLine(waiting ? 'Kept for 24 h' : 'Paused'),
        ];
        actions = [
          if (waiting) FilledButton(onPressed: () => job.resume(at: ui.endpointFor(context.services.node.peers[job.endpoint.fingerprint]!)), child: const Text('Resume')),
          TextButton(onPressed: job.cancel, child: const Text('Cancel transfer')),
        ];
      case SendState.done:
        final took = (job.finishedAt ?? DateTime.now()).difference(job.startedAt);
        body = [
          _Title(icon: LucideIcons.circleCheck, color: kf.success, title: job.fileCount == 0 ? 'Sent to $peer' : 'Done · ${formatBytes(job.totalBytes)} in ${formatDuration(took)}'),
          Text(job.fileCount == 0 ? 'Text' : '$what to $peer · full quality, checked', style: tt.bodySmall),
        ];
        actions = [TextButton(onPressed: () => ui.dismiss(job.id), child: const Text('Dismiss'))];
      case SendState.partial:
        final failed = job.failedItems;
        final took = (job.finishedAt ?? DateTime.now()).difference(job.startedAt);
        body = [
          _Title(icon: LucideIcons.triangleAlert, color: kf.warning, title: '${job.doneFiles} of ${job.fileCount} sent to $peer'),
          Text('${formatBytes(job.sentBytes)} in ${formatDuration(took)} · ${failed.length} didn\'t send', style: tt.bodySmall),
          const SizedBox(height: KfSpace.s2),
          for (final f in failed.take(5))
            Padding(
              padding: const EdgeInsets.only(top: KfSpace.s1),
              child: Row(
                children: [
                  Icon(fileIcon(f.offerItem.name), size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '${f.offerItem.name}  ', style: tt.bodySmall!.copyWith(color: cs.onSurface)),
                          TextSpan(text: errorText(f.error, device: 'this device'), style: tt.bodySmall),
                        ],
                      ),
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
          if (failed.length > 5) Text('and ${failed.length - 5} more', style: tt.bodySmall),
        ];
        actions = [
          FilledButton(onPressed: () => ui.retry(job, failedOnly: true), child: const Text('Retry failed')),
          TextButton(onPressed: () => ui.dismiss(job.id), child: const Text('Done')),
        ];
      case SendState.cancelled:
        body = [
          _Title(icon: LucideIcons.circleX, title: job.cancelledByPeer ? '$peer stopped the transfer' : 'Stopped sending to $peer'),
          Text('${job.doneFiles} of ${job.fileCount} sent', style: tt.bodySmall),
        ];
        actions = [TextButton(onPressed: () => ui.dismiss(job.id), child: const Text('Dismiss'))];
      case SendState.declined || SendState.timeout || SendState.busy || SendState.failed:
        final code = switch (job.state) {
          SendState.declined => KfErrorCode.declined,
          SendState.timeout => KfErrorCode.timeout,
          SendState.busy => KfErrorCode.busy,
          _ => job.error?.code,
        };
        body = [
          _Title(icon: LucideIcons.circleAlert, color: job.state == SendState.failed ? cs.error : null, title: errorText(code, device: peer)),
          Text('$what · ${formatBytes(job.totalBytes)}', style: tt.bodySmall),
        ];
        actions = [
          if (job.state != SendState.declined && code != KfErrorCode.versionMismatch)
            FilledButton.tonal(onPressed: () => ui.retry(job), child: const Text('Try again')),
          TextButton(onPressed: () => ui.dismiss(job.id), child: const Text('Dismiss')),
        ];
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KfSpace.s4),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...body,
              const SizedBox(height: KfSpace.s3),
              Wrap(spacing: KfSpace.s2, runSpacing: KfSpace.s2, children: actions),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context, SendJob job) async {
    // Under 10 s it stops at once; after that it asks first (US-006 v2.2).
    if (DateTime.now().difference(job.startedAt) < const Duration(seconds: 10)) {
      await job.cancel();
      return;
    }
    final left = job.fileCount - job.doneFiles;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop sending?'),
        content: Text('$left ${left == 1 ? 'file' : 'files'} left. ${job.peerName} keeps the ${job.doneFiles} it already has.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep sending')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error, foregroundColor: Theme.of(c).colorScheme.onError),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (ok == true) await job.cancel();
  }
}

/// Receiving now (D-03 "Receiving").
class IncomingCard extends StatelessWidget {
  const IncomingCard({super.key, required this.session});
  final IncomingSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final pct = s.totalBytes == 0 ? 0.0 : s.receivedBytes / s.totalBytes;
    final names = s.offer.items.where((i) => i.kind == ItemKind.file).map((i) => i.path);
    final what = s.fileCount == 1 ? names.first.split('/').last : countFiles(s.fileCount, names: names);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KfSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Title(icon: LucideIcons.arrowDownToLine, title: 'Receiving $what from ${s.senderName}'),
            Text('${countFiles(s.fileCount)} · saving to ${context.services.saveDir}', style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            Padding(
              padding: const EdgeInsets.only(top: KfSpace.s3),
              child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: pct, minHeight: 4)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: KfSpace.s2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${(pct * 100).floor()}% · ${formatBytes(s.receivedBytes)} of ${formatBytes(s.totalBytes)}',
                      style: tt.bodySmall!.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface),
                    ),
                  ),
                  Text('${formatSpeed(s.meter.bytesPerSecond)} · ${formatEta(s.meter.eta(s.totalBytes - s.receivedBytes))}', style: tt.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: KfSpace.s3),
            OutlinedButton(onPressed: () => context.services.node.receiver.cancelLocal(s.id), child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

/// Done / partial / cancelled summary for something we received.
class ReceivedCard extends StatelessWidget {
  const ReceivedCard({super.key, required this.session});
  final IncomingSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final ui = context.ui;
    final tt = Theme.of(context).textTheme;
    final kf = KfColors.of(context);
    final took = DateTime.now().difference(s.createdAt);
    final files = s.files.where((f) => f.done).toList();
    final texts = s.items.values.where((i) => i.item.kind == ItemKind.text).toList();
    final firstLoc = files.isEmpty ? null : files.first.location;
    final (icon, color, title) = switch (s.state) {
      SessionState.cancelled => (LucideIcons.circleX, null, s.cancelledByPeer ? '${s.senderName} stopped sending' : 'Stopped receiving'),
      SessionState.partial => (LucideIcons.triangleAlert, kf.warning, '${s.doneFiles} of ${s.fileCount} received'),
      _ => (
        LucideIcons.circleCheck,
        kf.success,
        s.fileCount == 0 ? 'Text from ${s.senderName}' : 'Done · ${formatBytes(s.totalBytes)} in ${formatDuration(took)}',
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KfSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Title(icon: icon, color: color, title: title),
            if (s.state == SessionState.done && s.fileCount > 0)
              Text('From ${s.senderName} · full quality, checked', style: tt.bodySmall),
            for (final t in texts.take(1))
              Padding(
                padding: const EdgeInsets.only(top: KfSpace.s2),
                child: Text(t.item.text ?? '', maxLines: 4, overflow: TextOverflow.ellipsis, style: tt.bodyLarge),
              ),
            const SizedBox(height: KfSpace.s3),
            Wrap(
              spacing: KfSpace.s2,
              runSpacing: KfSpace.s2,
              children: [
                if (texts.isNotEmpty) ...[
                  FilledButton.tonal(onPressed: () => copyText(context, texts.first.item.text ?? ''), child: const Text('Copy')),
                  if (Uri.tryParse(texts.first.item.text?.trim() ?? '')?.hasScheme ?? false)
                    TextButton(onPressed: () => ui.s.os.open(texts.first.item.text!.trim()), child: const Text('Open link')),
                ],
                if (files.length == 1) FilledButton.tonal(onPressed: () => ui.open(firstLoc), child: const Text('Open')),
                if (files.isNotEmpty) TextButton(onPressed: () => ui.reveal(firstLoc), child: Text(ui.revealLabel)),
                TextButton(onPressed: () => ui.dismiss('in:${s.id}'), child: const Text('Dismiss')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.icon, required this.title, this.color});
  final IconData icon;
  final String title;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 18, color: color ?? Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(width: KfSpace.s2),
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
      ],
    ),
  );
}
