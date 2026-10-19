// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/discovery.dart';
import '../../storage/peers.dart';
import '../../transfer/receiver.dart';
import '../../transfer/sender.dart';
import '../format.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'common.dart';

/// What a row shows for one device right now.
class RowActivity {
  const RowActivity({this.job, this.incoming});
  final SendJob? job;
  final IncomingSession? incoming;
}

class DeviceRow extends StatelessWidget {
  const DeviceRow({
    super.key,
    required this.peer,
    required this.live,
    required this.onTap,
    required this.onMenu,
    this.activity = const RowActivity(),
    this.dropTarget = false,
  });

  final PeerRecord peer;
  final LiveDevice? live;
  final RowActivity activity;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;

  /// Desktop: a drag is hovering over this row.
  final bool dropTarget;

  bool get online => live?.online ?? false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kf = KfColors.of(context);
    final tt = Theme.of(context).textTheme;
    final job = activity.job;
    final inc = activity.incoming;

    var ring = RingMode.none;
    double value = 0;
    String meta;
    Color? metaColor;
    Widget? trailing;

    if (dropTarget) {
      meta = 'Drop to send to ${peer.displayName}';
      metaColor = cs.primary;
    } else if (job != null && !job.isFinished) {
      switch (job.state) {
        case SendState.waiting:
          final left = const Duration(seconds: 60) - DateTime.now().difference(job.startedAt);
          ring = RingMode.countdown;
          value = clamp01(left.inMilliseconds / 60000);
          meta = 'Waiting for accept · ${formatCountdown(left)}';
        case SendState.paused:
          ring = RingMode.paused;
          value = job.totalBytes == 0 ? 0 : job.sentBytes / job.totalBytes;
          meta = job.waitingForResume ? 'Paused · ${(value * 100).floor()}%' : 'Reconnecting… · ${(value * 100).floor()}%';
          metaColor = kf.warning;
        default:
          ring = RingMode.progress;
          value = job.totalBytes == 0 ? 0 : job.sentBytes / job.totalBytes;
          meta = 'Sending ${countFiles(job.fileCount, names: job.items.map((i) => i.offerItem.path))} · ${(value * 100).floor()}%';
      }
    } else if (inc != null && inc.state == SessionState.active) {
      ring = RingMode.progress;
      value = inc.totalBytes == 0 ? 0 : inc.receivedBytes / inc.totalBytes;
      meta = 'Sending to you · ${(value * 100).floor()}%';
    } else if (live?.versionMismatch ?? false) {
      meta = '${peer.platform.label} · Update needed';
      metaColor = kf.warning;
    } else {
      final parts = [
        peer.platform.label,
        online ? 'Online' : 'Offline',
        if (peer.trusted && peer.autoAccept && online) 'Auto-accept',
        if (peer.trusted && !online) 'Trusted',
      ];
      meta = parts.join(' · ');
    }
    if (online && ring == RingMode.none && !dropTarget && !(live?.versionMismatch ?? false)) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Send', style: tt.labelLarge!.copyWith(color: cs.primary)),
          const SizedBox(width: 4),
          Icon(LucideIcons.arrowUpRight, size: 18, color: cs.primary),
        ],
      );
    }

    final status = online ? 'online' : 'offline';
    return Semantics(
      button: true,
      label: '${peer.displayName}, ${peer.platform.label}, $status${peer.trusted ? ', trusted' : ''}. $meta',
      hint: online ? 'Send files' : null,
      excludeSemantics: true,
      child: GestureDetector(
        onSecondaryTapUp: (d) => onMenu(d.globalPosition),
        onLongPressStart: isDesktop ? null : (d) => onMenu(d.globalPosition),
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: KfMotion.fast,
            decoration: BoxDecoration(
              border: dropTarget ? Border.all(color: cs.primary, width: 1.5) : null,
              color: dropTarget ? cs.secondaryContainer.withValues(alpha: 0.5) : null,
              borderRadius: dropTarget ? BorderRadius.circular(KfRadius.md) : null,
            ),
            padding: EdgeInsets.fromLTRB(8, isDesktop ? 4 : 8, 12, isDesktop ? 4 : 8),
            child: Row(
              children: [
                DeviceTile(
                  icon: platformIcon(peer.platform),
                  ring: ring,
                  value: value,
                  dimmed: !online && ring == RingMode.none,
                  dashed: dropTarget,
                ),
                const SizedBox(width: KfSpace.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              peer.displayName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodyLarge!.copyWith(
                                fontWeight: FontWeight.w600,
                                color: online || ring != RingMode.none ? cs.onSurface : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (peer.trusted) ...[
                            const SizedBox(width: 6),
                            Icon(LucideIcons.shieldCheck, size: 15, color: cs.primary),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (ring == RingMode.none && !dropTarget) StatusDot(online: online),
                          if (dropTarget) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(LucideIcons.arrowDownToLine, size: 14, color: cs.primary)),
                          Flexible(
                            child: Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodySmall!.copyWith(color: metaColor),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AddDeviceRow extends StatelessWidget {
  const AddDeviceRow({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, isDesktop ? 8 : 12, 12, isDesktop ? 8 : 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(KfRadius.sm),
                border: Border.all(color: cs.primary, width: 1.2),
              ),
              child: Icon(LucideIcons.plus, color: cs.primary, size: 22),
            ),
            const SizedBox(width: KfSpace.s3 + 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Add a device', style: tt.bodyLarge!.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
                  Text('Get kickFile on another phone or laptop', style: tt.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
