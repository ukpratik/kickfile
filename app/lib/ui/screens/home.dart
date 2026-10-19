import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/discovery.dart';
import '../../core/protocol.dart';
import '../../net/netinfo.dart';
import '../../storage/peers.dart';
import '../../transfer/receiver.dart';
import '../../transfer/sender.dart';
import '../format.dart';
import '../scope.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/activity_row.dart';
import '../widgets/common.dart';
import '../widgets/device_row.dart';
import '../widgets/transfer_cards.dart';
import 'add_device.dart';
import 'connection_help.dart';
import 'device_actions.dart';
import 'history.dart';
import 'qr_screen.dart';
import 'settings.dart';
import 'source_sheet.dart';

/// One screen on mobile, one compact window on desktop (D-02 / M-02).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.previewDropTarget});

  /// Renders the "drop onto this device" state for docs and videos (no real drag).
  @visibleForTesting
  final String? previewDropTarget;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _rowKeys = <String, GlobalKey>{};
  Timer? _ticker;
  bool _dragging = false;
  String? _dropFp;

  @override
  void initState() {
    super.initState();
    if (widget.previewDropTarget != null) {
      _dragging = true;
      _dropFp = widget.previewDropTarget;
    }
    // Countdowns and "searching" need a 1 s heartbeat.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _announceProgress();
      setState(() {});
    });
  }

  /// Screen readers hear progress at 25 % steps, not every update (NFR-011).
  final _announced = <String, int>{};
  void _announceProgress() {
    final s = context.services;
    final items = <(String, String, int, int)>[
      for (final j in s.node.transfers.activeJobs) (j.id, 'Sending to ${j.peerName}', j.sentBytes, j.totalBytes),
      if (s.node.receiver.session case final r? when r.state == SessionState.active)
        (r.id, 'Receiving from ${r.senderName}', r.receivedBytes, r.totalBytes),
    ];
    for (final (id, what, done, total) in items) {
      if (total <= 0) continue;
      final quarter = (done * 4 ~/ total).clamp(0, 4);
      if (quarter > (_announced[id] ?? 0) && quarter < 4) {
        _announced[id] = quarter;
        unawaited(SemanticsService.sendAnnouncement(View.of(context), '$what, ${quarter * 25} percent', TextDirection.ltr));
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final ui = context.ui;
    return ListenableBuilder(
      listenable: Listenable.merge([
        s.discovery,
        s.node.peers,
        s.node.transfers,
        s.node.receiver,
        s.node.history,
        s.node.settings,
        ui,
      ]),
      builder: (context, _) {
        final list = _content(context);
        final body = isDesktop
            ? DropTarget(
                onDragEntered: (d) => setState(() => _dragging = true),
                onDragUpdated: (d) => _hover(d.globalPosition),
                onDragExited: (_) => setState(() {
                  _dragging = false;
                  _dropFp = null;
                }),
                onDragDone: _onDrop,
                child: list,
              )
            : RefreshIndicator(onRefresh: s.discovery.refresh, child: list);
        return Scaffold(
          appBar: _appBar(context),
          body: SafeArea(top: false, bottom: false, child: body),
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.fromLTRB(KfSpace.gutter, 0, KfSpace.gutter, KfSpace.s2),
            child: isDesktop
                ? TextButton.icon(
                    onPressed: () => _push(const ConnectionHelpScreen()),
                    icon: const Icon(LucideIcons.circleQuestionMark, size: 18),
                    label: const Text("Don't see your device?"),
                  )
                : OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => _push(const ConnectionHelpScreen()),
                    icon: const Icon(LucideIcons.circleQuestionMark, size: 18),
                    label: const Text("Don't see your device?"),
                  ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    final s = context.services;
    final tt = Theme.of(context).textTheme;
    final settings = s.node.settings.value;
    if (isDesktop) {
      return AppBar(
        toolbarHeight: 64,
        titleSpacing: KfSpace.gutter,
        title: Row(
          children: [
            const KfMark(size: 32),
            const SizedBox(width: KfSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(settings.deviceName, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    '${_networkWord(s.discovery.network)} · ${settings.visible ? 'Visible' : 'Hidden'}',
                    style: tt.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () => _push(const QrScreen()),
            icon: const Icon(LucideIcons.qrCode, size: 18),
            label: const Text('Show QR'),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(LucideIcons.ellipsis),
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'history', child: Text('History')),
              PopupMenuItem(value: 'add', child: Text('Add a device')),
              PopupMenuItem(value: 'help', child: Text('Connection help')),
            ],
          ),
          const SizedBox(width: KfSpace.s2),
        ],
      );
    }
    return AppBar(
      titleSpacing: KfSpace.gutter,
      title: const Row(children: [KfMark(), SizedBox(width: KfSpace.s2), Text('kickFile')]),
      actions: [
        IconButton(tooltip: 'Show QR code', onPressed: () => _push(const QrScreen()), icon: const Icon(LucideIcons.qrCode)),
        IconButton(tooltip: 'Settings', onPressed: () => _push(const SettingsScreen()), icon: const Icon(LucideIcons.settings)),
      ],
    );
  }

  void _menu(String v) => switch (v) {
    'settings' => _push(const SettingsScreen()),
    'history' => _push(const HistoryScreen()),
    'add' => _push(const AddDeviceScreen()),
    _ => _push(const ConnectionHelpScreen()),
  };

  Future<void> _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  String _networkWord(NetworkState n) => switch (n.kind) {
    LinkKind.wifi => 'On Wi-Fi',
    LinkKind.ethernet => 'On Ethernet',
    LinkKind.other => 'On a network',
    LinkKind.none => 'Not on a network',
  };

  Widget _content(BuildContext context) {
    final s = context.services;
    final ui = context.ui;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final devices = s.discovery.devices;
    final jobs = s.node.transfers.jobs.where((j) => !ui.dismissed.contains(j.id)).toList();
    final incoming = s.node.receiver.session;
    final finished = s.node.receiver.lastFinished;
    final recent = s.node.history.entries.take(5).toList();
    final network = s.discovery.network;

    // BUG-002: every transfer still moving gets a card, but only ONE finished card shows
    // (the newest). A fully successful one collapses into Recent after 6 s; anything that
    // needs attention (text, partial, failed, paused, out of space) stays until dismissed.
    final now = DateTime.now();
    bool expired(DateTime? at, bool clean) =>
        clean && at != null && now.difference(at) > const Duration(seconds: 6);
    final live = jobs.where((j) => !j.isFinished).toList();
    final done = <(DateTime, Widget)>[
      for (final j in jobs.where((j) => j.isFinished))
        if (!expired(j.finishedAt, j.state == SendState.done || (j.state == SendState.cancelled && !j.cancelledByPeer)))
          (j.finishedAt ?? now, SendJobCard(job: j)),
      if (finished != null &&
          !ui.dismissed.contains('in:${finished.id}') &&
          !expired(finished.finishedAt, finished.state == SessionState.done && finished.fileCount > 0 && finished.offer.items.every((i) => i.kind != ItemKind.text)))
        (finished.finishedAt ?? now, ReceivedCard(session: finished)),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    final noSpace = s.node.receiver.pausedSessions.where((p) => p.outOfSpace && !ui.dismissed.contains('nospace:${p.id}')).firstOrNull;

    final cards = <Widget>[
      if (incoming != null && incoming.state == SessionState.active) IncomingCard(session: incoming),
      ?(noSpace == null ? null : OutOfSpaceCard(session: noSpace)),
      for (final j in live) SendJobCard(job: j),
      ?done.firstOrNull?.$2,
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(KfSpace.gutter, KfSpace.s2, KfSpace.gutter, KfSpace.s6),
      children: [
        if (!isDesktop) _StatusCard(network: network),
        if (network.kind == LinkKind.none) ...[
          const SizedBox(height: KfSpace.s3),
          const KfBanner(
            tone: BannerTone.warning,
            icon: LucideIcons.wifiOff,
            title: 'Not on a network',
            text: 'Connect to Wi-Fi, or turn on your phone’s hotspot and join it from your laptop.',
          ),
        ] else if (network.vpnActive) ...[
          const SizedBox(height: KfSpace.s3),
          const KfBanner(tone: BannerTone.warning, text: 'A VPN may hide nearby devices.'),
        ],
        for (final c in cards) Padding(padding: const EdgeInsets.only(top: KfSpace.s3), child: c),
        // BUG-016: desktop first run, until a first device is known (d01).
        if (isDesktop && s.node.peers.all.isEmpty) ...[
          const SizedBox(height: KfSpace.s3),
          const _GetPhoneCard(),
        ],
        SectionLabel('Devices', trailing: s.discovery.searching ? const SearchingShimmer() : null),
        GroupCard(
          children: [
            if (devices.isEmpty)
              EmptyState(
                icon: LucideIcons.radar,
                title: s.discovery.searching ? 'Looking for devices on this Wi-Fi…' : 'No devices yet',
                text: 'Open kickFile on the other device, on the same Wi-Fi or hotspot.',
                actions: [
                  OutlinedButton.icon(
                    onPressed: () => _push(const QrScreen()),
                    icon: const Icon(LucideIcons.qrCode, size: 18),
                    label: const Text('Connect with a QR code'),
                  ),
                ],
              ),
            for (final (peer, live) in devices)
              DeviceRow(
                key: _rowKeys.putIfAbsent(peer.fingerprint, GlobalKey.new),
                peer: peer,
                live: live,
                activity: _activityFor(peer, jobs, incoming),
                dropTarget: _dropFp == peer.fingerprint,
                onTap: () => _tapDevice(peer, live),
                onMenu: (pos) => showDeviceActions(context, peer, pos),
              ),
            AddDeviceRow(onTap: () => _push(const AddDeviceScreen())),
          ],
        ),
        if (isDesktop)
          Padding(
            padding: const EdgeInsets.only(top: KfSpace.s3),
            child: DottedHint(
              active: _dragging && _dropFp == null,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Drop files anywhere to send', style: tt.labelMedium!.copyWith(color: cs.onSurface)),
                    TextSpan(text: ' · or click a device to choose files', style: tt.bodySmall),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        SectionLabel(
          'Recent',
          trailing: recent.isEmpty
              ? null
              : TextButton(onPressed: () => _push(const HistoryScreen()), child: const Text('See all')),
        ),
        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('Files you send and receive show up here.', style: tt.bodySmall),
          )
        else
          GroupCard(children: [for (final e in recent) ActivityRow(entry: e)]),
      ],
    );
  }

  RowActivity _activityFor(PeerRecord p, List<SendJob> jobs, IncomingSession? incoming) => RowActivity(
    job: jobs.where((j) => j.endpoint.fingerprint == p.fingerprint && !j.isFinished).firstOrNull,
    incoming: incoming?.senderFingerprint == p.fingerprint ? incoming : null,
  );

  Future<void> _tapDevice(PeerRecord peer, LiveDevice? live) async {
    final ui = context.ui;
    if (!(live?.online ?? false)) {
      ui.toast('${peer.displayName} is offline. Open kickFile on it, on the same Wi-Fi.');
      return;
    }
    if (live?.versionMismatch ?? false) {
      ui.toast('Update kickFile on ${peer.displayName} to send files.');
      return;
    }
    if (isDesktop) {
      await ui.pickFilesFor(peer);
    } else {
      await showSourceSheet(context, peer);
    }
  }

  // ---- desktop drag and drop (D-02) ----

  void _hover(Offset global) {
    String? hit;
    for (final e in _rowKeys.entries) {
      final box = e.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global) && (context.services.discovery.live(e.key)?.online ?? false)) hit = e.key;
    }
    if (hit != _dropFp || !_dragging) {
      setState(() {
        _dragging = true;
        _dropFp = hit;
      });
    }
  }

  Future<void> _onDrop(DropDoneDetails d) async {
    final s = context.services;
    final ui = context.ui;
    final target = _dropFp;
    setState(() {
      _dragging = false;
      _dropFp = null;
    });
    final paths = d.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
    if (paths.isEmpty) return;
    final sources = await ui.sourcesFromPaths(paths);
    if (!mounted || sources.isEmpty) return;

    PeerRecord? peer = target == null ? null : s.node.peers[target];
    if (peer == null) {
      final online = s.discovery.devices.where((e) => e.$2?.online ?? false).map((e) => e.$1).toList();
      if (online.isEmpty) {
        await _push(const ConnectionHelpScreen());
        return;
      }
      if (online.length == 1) {
        // One device online: send straight away, with Undo (US-004 v2.2).
        final job = ui.send(online.first, sources);
        if (job != null) {
          ui.toast(
            'Sending to ${online.first.displayName}',
            action: 'Undo',
            duration: const Duration(seconds: 5),
            onAction: () {
              unawaited(job.cancel());
              ui.dismiss(job.id);
            },
          );
        }
        return;
      }
      peer = await _chooseDevice(online, sources.length);
      if (peer == null) return;
    }
    ui.send(peer, sources);
  }

  Future<PeerRecord?> _chooseDevice(List<PeerRecord> online, int count) => showDialog<PeerRecord>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('Send ${count == 1 ? '1 item' : '$count items'} to…'),
      children: [
        for (final p in online)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, p),
            child: Row(
              children: [
                Icon(platformIcon(p.platform), size: 20),
                const SizedBox(width: KfSpace.s3),
                Expanded(child: Text(p.displayName)),
              ],
            ),
          ),
      ],
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.network});
  final NetworkState network;

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final visible = s.node.settings.value.visible;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final word = switch (network.kind) {
      LinkKind.wifi => 'On Wi-Fi',
      LinkKind.ethernet => 'On Ethernet',
      LinkKind.other => 'On a network',
      LinkKind.none => 'Not on a network',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KfSpace.s3),
        child: Row(
          children: [
            Icon(network.kind == LinkKind.none ? LucideIcons.wifiOff : LucideIcons.wifi, color: cs.primary),
            const SizedBox(width: KfSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(word, style: tt.bodyLarge!.copyWith(fontWeight: FontWeight.w600)),
                  Text('Ready to receive while kickFile is open', style: tt.bodySmall),
                ],
              ),
            ),
            ActionChip(
              avatar: Icon(visible ? LucideIcons.eye : LucideIcons.eyeOff, size: 16),
              label: Text(visible ? 'Visible' : 'Hidden'),
              onPressed: () async {
                await s.node.settings.update((x) => x.copyWith(visible: !visible));
                await s.discovery.updateBroadcast();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _GetPhoneCard extends StatelessWidget {
  const _GetPhoneCard();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KfSpace.s4),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(KfRadius.sm)),
              child: QrImageView(data: kDownloadUrl, size: 96, backgroundColor: Colors.white),
            ),
            const SizedBox(width: KfSpace.s4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Get kickFile on your phone', style: tt.titleMedium),
                  const SizedBox(height: 2),
                  Text("Scan with your phone's camera. The page picks the right store.", style: tt.bodySmall),
                  const SizedBox(height: KfSpace.s2),
                  Text('Already have it? Open kickFile on your phone, on the same Wi-Fi.', style: tt.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dashed "Drop files anywhere" hint; highlights while dragging over the window.
class DottedHint extends StatelessWidget {
  const DottedHint({super.key, required this.child, this.active = false});
  final Widget child;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: KfMotion.fast,
      padding: const EdgeInsets.symmetric(vertical: KfSpace.s3, horizontal: KfSpace.s3),
      decoration: BoxDecoration(
        color: active ? cs.secondaryContainer : null,
        borderRadius: BorderRadius.circular(KfRadius.md),
        border: Border.all(color: active ? cs.primary : cs.outline, width: active ? 1.5 : 1),
      ),
      child: Center(child: child),
    );
  }
}
