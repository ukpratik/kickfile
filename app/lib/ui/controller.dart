// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/android_bridge.dart';
import '../app/desktop_shell.dart';
import '../app/services.dart';
import '../core/protocol.dart';
import '../net/client.dart';
import '../storage/peers.dart';
import '../transfer/file_access.dart';
import '../transfer/io_file_access.dart';
import '../transfer/sender.dart';
import 'format.dart';
import 'screens/text_compose.dart';

/// UI-side actions shared by screens: start sends, pick files, open results.
class UiController extends ChangeNotifier {
  UiController(this.s);

  final AppServices s;

  /// Desktop window/tray glue; null on mobile.
  DesktopShell? shell;
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// Finished cards the user dismissed (job ids, incoming transfer ids).
  final dismissed = <String>{};

  BuildContext? get ctx => navigatorKey.currentContext;

  void dismiss(String id) {
    dismissed.add(id);
    final job = s.node.transfers.jobs.where((j) => j.id == id).firstOrNull;
    if (job != null) s.node.transfers.dismiss(job);
    notifyListeners();
  }

  void toast(String text, {String? action, VoidCallback? onAction, Duration duration = const Duration(seconds: 4)}) {
    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: duration,
          action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
        ),
      );
  }

  PeerEndpoint? endpointFor(PeerRecord p) {
    final live = s.discovery.live(p.fingerprint);
    if (live?.online ?? false) return live!.endpoint;
    if (p.addresses.isNotEmpty) return PeerEndpoint(p.addresses.first, p.port, p.fingerprint);
    return null;
  }

  bool isOnline(PeerRecord p) => s.discovery.live(p.fingerprint)?.online ?? false;

  SendJob? send(PeerRecord p, List<SendSource> sources) {
    if (sources.isEmpty) return null;
    final ep = endpointFor(p);
    if (ep == null || !isOnline(p)) {
      toast("${p.displayName} is offline. Open kickFile on it, on the same Wi-Fi.");
      return null;
    }
    final fileCount = sources.where((x) => x.kind == ItemKind.file).length;
    if (sources.length > kMaxItems) {
      toast('That’s more than ${kMaxItems ~/ 1000},000 items. Send them in smaller batches.');
      return null;
    }
    if (fileCount == 0 && sources.every((x) => x.kind == ItemKind.dir)) {
      toast('That folder is empty.');
    }
    return s.node.transfers.send(to: ep, peerName: p.displayName, peerPlatform: p.platform, sources: sources);
  }

  Future<void> pickFilesFor(PeerRecord p) async {
    if (Platform.isAndroid) return _sendPicked(p, AndroidBridge.pickFiles());
    final files = await openFiles();
    if (files.isEmpty) return;
    send(p, await sourcesFromPaths(files.map((f) => f.path).toList()));
  }

  Future<void> pickMediaFor(PeerRecord p) async {
    if (Platform.isAndroid) {
      await _askMediaLocation();
      return _sendPicked(p, AndroidBridge.pickMedia());
    }
    const group = XTypeGroup(
      label: 'Photos & videos',
      extensions: ['jpg', 'jpeg', 'png', 'heic', 'heif', 'gif', 'webp', 'dng', 'mov', 'mp4', 'm4v', 'mkv', 'avi', 'webm', '3gp'],
      mimeTypes: ['image/*', 'video/*'],
      uniformTypeIdentifiers: ['public.image', 'public.movie'],
    );
    final files = await openFiles(acceptedTypeGroups: const [group]);
    if (files.isEmpty) return;
    send(p, await sourcesFromPaths(files.map((f) => f.path).toList()));
  }

  Future<void> pickFolderFor(PeerRecord p) async {
    if (Platform.isAndroid) return _sendPicked(p, AndroidBridge.pickFolder());
    final dir = await getDirectoryPath(confirmButtonText: 'Send');
    if (dir == null) return;
    send(p, await sourcesFromPaths([dir]));
  }

  Future<void> _sendPicked(PeerRecord p, Future<List<SendSource>> picked) async {
    try {
      final sources = await picked;
      if (sources.isNotEmpty) send(p, sources);
    } catch (e) {
      toast("Couldn't open the picker. Try again.");
    }
  }

  /// Android 10+: keep GPS data in photos you send (PRD §7). Asked once, before the first photo pick.
  Future<void> _askMediaLocation() async {
    final settings = s.node.settings;
    if (settings.value.promptsShown.contains('media_location')) return;
    await settings.markPromptShown('media_location');
    final st = await Permission.accessMediaLocation.request();
    if (!st.isGranted) toast('Photos will be sent without their location data.');
  }

  Future<void> textFor(PeerRecord p) async {
    final c = ctx;
    if (c == null) return;
    final text = await composeText(c, p.displayName);
    if (text == null || text.isEmpty) return;
    send(p, [SendSource.text(text)]);
  }

  /// Files and folders (walked recursively) from paths the user picked or dropped.
  Future<List<SendSource>> sourcesFromPaths(List<String> paths) async {
    final out = <SendSource>[];
    final io = s.files is IoFileAccess ? s.files as IoFileAccess : IoFileAccess(s.saveDir);
    for (final path in paths) {
      final type = await FileSystemEntity.type(path, followLinks: true);
      if (type == FileSystemEntityType.directory) {
        await for (final src in io.expandFolder(path)) {
          out.add(src);
          if (out.length > kMaxItems) return out;
        }
      } else if (type == FileSystemEntityType.file) {
        final st = await File(path).stat();
        out.add(
          SendSource(
            kind: ItemKind.file,
            relPath: path.split(Platform.pathSeparator).last,
            ref: path,
            size: st.size,
            mtime: st.modified.millisecondsSinceEpoch,
          ),
        );
      }
    }
    return out;
  }

  /// Retry the same items (declined, busy, failed) or only those that failed (partial).
  void retry(SendJob job, {bool failedOnly = false}) {
    final peer = s.node.peers[job.endpoint.fingerprint];
    if (peer == null) return;
    final sources = failedOnly
        ? [for (final i in job.failedItems) i.source]
        : job.sources;
    dismiss(job.id);
    send(peer, sources);
  }

  Future<void> open(String? location, {String? name}) async {
    if (location == null) return toast('This file was moved or deleted.');
    if (await s.os.open(location, name: name)) return;
    if (Platform.isAndroid) {
      // BUG-012: Android tells us when no app handles the type.
      final ext = (name ?? '').contains('.') ? name!.split('.').last : null;
      toast(
        ext == null ? 'No app on this phone opens this file.' : 'No app on this phone opens .$ext files.',
        action: 'Show in folder',
        onAction: () => reveal(location),
      );
      return;
    }
    toast('This file was moved or deleted.');
  }

  Future<void> reveal(String? location) async {
    if (location == null || !await s.os.reveal(location)) toast('This file was moved or deleted.');
  }

  String get revealLabel => Platform.isMacOS
      ? 'Show in Finder'
      : Platform.isWindows
      ? 'Show in folder'
      : 'Show in folder';

  String sizeLine(int bytes, int files) => '${countFiles(files)} · ${formatBytes(bytes)}';
}
