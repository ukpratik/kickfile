import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/log.dart';
import '../core/protocol.dart';
import '../transfer/file_access.dart';
import '../transfer/io_file_access.dart';
import '../transfer/node.dart';
import '../transfer/receiver.dart';
import 'android_bridge.dart';
import 'discovery.dart';
import 'notifier.dart';
import 'os_actions.dart';

DevicePlatform get currentPlatform {
  if (Platform.isAndroid) return DevicePlatform.android;
  if (Platform.isIOS) return DevicePlatform.ios;
  if (Platform.isMacOS) return DevicePlatform.macos;
  if (Platform.isWindows) return DevicePlatform.windows;
  if (Platform.isLinux) return DevicePlatform.linux;
  return DevicePlatform.unknown;
}

/// Everything the UI talks to. Created once in main().
class AppServices {
  AppServices._(this.node, this.discovery, this.notifier, this.files, this.defaultSaveDir);

  final KickNode node;
  final Discovery discovery;
  final Notifier notifier;
  final FileAccess files;
  final String defaultSaveDir;
  final os = const OsActions();

  /// Set by tests and by `KF_PROFILE` to run two copies on one computer.
  static String? profile = Platform.environment['KF_PROFILE'];

  static Future<AppServices> init({FileAccess Function(String saveDir)? filesFor, String? defaultName}) async {
    var support = (await getApplicationSupportDirectory()).path;
    if (profile != null) support = p.join(support, 'profiles', profile!);
    await Directory(p.join(support, 'logs')).create(recursive: true);
    log.attach(File(p.join(support, 'logs', 'kickfile.log')));
    log.echo = kDebugMode;
    log.info('app', 'start ${currentPlatform.name}');

    final String defaultSave;
    final FileAccess files;
    final String name;
    if (Platform.isAndroid) {
      // Photos and videos go to the gallery, everything else to Download/kickFile (US-007).
      defaultSave = 'Download/kickFile';
      files = filesFor?.call(defaultSave) ?? AndroidFileAccess();
      name = defaultName ?? await AndroidBridge.deviceName() ?? 'Android phone';
    } else {
      final downloads = (await getDownloadsDirectory())?.path ??
          p.join(Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? support, 'Downloads');
      defaultSave = p.join(downloads, profile == null ? 'kickFile' : 'kickFile-$profile');
      files = filesFor?.call(defaultSave) ?? IoFileAccess(defaultSave);
      name = defaultName ?? await desktopDeviceName();
    }

    final node = await KickNode.open(
      dataDir: Directory(support),
      files: files,
      defaultName: name,
      platform: currentPlatform,
    );
    if (files is IoFileAccess) files.saveDir = node.settings.value.saveDir ?? defaultSave;
    await node.start();

    final discovery = Discovery(node);
    final notifier = Notifier();
    await notifier.init();
    final s = AppServices._(node, discovery, notifier, files, defaultSave);
    s._keepAwake();
    unawaited(discovery.start());
    return s;
  }

  /// Tests: wire an already-open node without plugins (no discovery start, no notifications).
  @visibleForTesting
  factory AppServices.test(KickNode node, String saveDir) =>
      AppServices._(node, Discovery(node), Notifier(), node.files, saveDir);

  String get saveDir => files is IoFileAccess ? (files as IoFileAccess).saveDir : defaultSaveDir;

  Future<void> setSaveDir(String? dir) async {
    await node.settings.update((s) => dir == null ? s.copyWith(clearSaveDir: true) : s.copyWith(saveDir: dir));
    if (files is IoFileAccess) (files as IoFileAccess).saveDir = dir ?? defaultSaveDir;
  }

  bool get transferring =>
      node.transfers.hasActiveTransfer || node.receiver.session?.state == SessionState.active;

  /// No sleep while files move (US-006).
  void _keepAwake() {
    var on = false;
    void update() {
      final want = transferring;
      if (want == on) return;
      on = want;
      unawaited(WakelockPlus.toggle(enable: want).catchError((Object _) {}));
    }

    node.transfers.addListener(update);
    node.receiver.addListener(update);
  }

  Future<void> shutdown() async {
    await discovery.stop();
    await node.dispose();
  }
}
