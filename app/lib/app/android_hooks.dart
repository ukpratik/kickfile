import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/errors.dart';
import '../core/log.dart';
import '../core/protocol.dart';
import '../core/qr.dart';
import '../transfer/file_access.dart';
import '../transfer/receiver.dart';
import '../ui/controller.dart';
import '../ui/format.dart';
import 'android_bridge.dart';
import 'notifier.dart';
import 'services.dart';

/// Android glue: share sheet and kickfile:// links in, foreground-service progress out,
/// and no announcing while the app is in the background (A-08, NFR-010).
class AndroidHooks with WidgetsBindingObserver {
  AndroidHooks(this.s, this.ui, {required this.onShare, required this.onPaired});

  final AppServices s;
  final UiController ui;

  /// Files or text shared into kickFile: the UI asks which device.
  final void Function(List<SendSource> sources) onShare;
  final void Function(String deviceName) onPaired;

  StreamSubscription<Map<String, Object?>>? _intents;
  Timer? _progress;
  bool _fg = false;
  bool _askedNotifications = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(_legacyStorage());
    _intents = AndroidBridge.intents.listen(_onIntent, onError: (Object e) => log.warn('android', 'intent ${e.runtimeType}'));
    _progress = Timer.periodic(const Duration(seconds: 1), (_) => _updateForeground());
    s.node.receiver.completed.listen((_) => _askNotificationsOnce());
    s.node.transfers.jobChanges.listen((j) {
      if (j.isFinished) _askNotificationsOnce();
    });
  }

  /// Android 8–9 save to Download/kickFile directly and need the storage permission (PRD §7).
  Future<void> _legacyStorage() async {
    if (await AndroidBridge.sdkInt() > 28) return;
    final st = await Permission.storage.request();
    if (!st.isGranted) {
      ui.toast('kickFile can’t save received files without storage access. Allow it in Settings › Apps › kickFile.', duration: const Duration(seconds: 8));
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _intents?.cancel();
    _progress?.cancel();
  }

  Future<void> _onIntent(Map<String, Object?> e) async {
    switch (e['type']) {
      case 'share':
        final items = (e['items'] as List? ?? const [])
            .map((m) => AndroidBridge.sourceFromMap((m! as Map).cast<String, Object?>()))
            .toList();
        if (items.isNotEmpty) onShare(items);
        final skipped = (e['skipped'] as num?)?.toInt() ?? 0;
        if (skipped > 0) ui.toast("$skipped ${skipped == 1 ? 'file' : 'files'} couldn't be read and won't be sent.");
      case 'share_failed':
        ui.toast("kickFile couldn't read the shared files. Try sending from kickFile instead.");
      case 'text':
        final t = e['text'] as String?;
        if (t != null && t.isNotEmpty) onShare([SendSource.text(t.length > kMaxTextChars ? t.substring(0, kMaxTextChars) : t)]);
      case 'link':
        try {
          final code = PairingCode.parse(e['uri']! as String);
          final peer = await s.node.pairWithCode(code);
          s.discovery.addReachable(
            DeviceInfo(fingerprint: peer.fingerprint, name: peer.name, platform: peer.platform, port: peer.port),
            peer.addresses.first,
          );
          onPaired(peer.displayName);
        } on KfError catch (err) {
          ui.toast(errorText(err.code, device: 'that device'));
        }
    }
  }

  /// "Get notified when files arrive?" after the first completed transfer (PRD §7).
  Future<void> _askNotificationsOnce() async {
    if (_askedNotifications) return;
    _askedNotifications = true;
    final settings = s.node.settings;
    if (settings.value.promptsShown.contains('notifications')) return;
    await settings.markPromptShown('notifications');
    await s.notifier.requestPermission();
  }

  Future<void> _updateForeground() async {
    final job = s.node.transfers.activeJobs.firstOrNull;
    final inc = s.node.receiver.session;
    String? title;
    String? text;
    var pct = -1;
    if (inc != null && inc.state == SessionState.active) {
      title = 'Receiving from ${inc.senderName}';
      pct = inc.totalBytes == 0 ? -1 : inc.receivedBytes * 100 ~/ inc.totalBytes;
      text = '${formatBytes(inc.receivedBytes)} of ${formatBytes(inc.totalBytes)}';
    } else if (job != null) {
      title = job.state.name == 'waiting' ? 'Waiting for ${job.peerName}' : 'Sending to ${job.peerName}';
      pct = job.totalBytes == 0 ? -1 : job.sentBytes * 100 ~/ job.totalBytes;
      text = '${formatBytes(job.sentBytes)} of ${formatBytes(job.totalBytes)}';
    }
    try {
      if (title != null) {
        _fg = true;
        await AndroidBridge.foreground(title, text ?? '', pct);
      } else if (_fg) {
        _fg = false;
        await AndroidBridge.stopForeground();
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(s.discovery.resumeForeground());
        unawaited(s.notifier.cancel(Notifier.doneId));
      case AppLifecycleState.paused:
        if (!s.transferring) unawaited(s.discovery.pauseBackground());
      default:
        break;
    }
  }
}
