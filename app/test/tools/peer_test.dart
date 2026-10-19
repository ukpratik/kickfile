// SPDX-License-Identifier: GPL-3.0-or-later
@Tags(['tool'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/log.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/net/client.dart';
import 'package:kickfile/transfer/file_access.dart';
import 'package:kickfile/transfer/io_file_access.dart';
import 'package:kickfile/transfer/node.dart';
import 'package:kickfile/transfer/receiver.dart';
import 'package:kickfile/transfer/sender.dart';
import 'package:path/path.dart' as p;

/// A real kickFile engine on this computer, for device and emulator tests.
///   KF_PEER_DIR=/tmp/peer KF_PEER_SECONDS=600 flutter test test/tools/peer_test.dart
/// Optional: KF_SEND_HOST/KF_SEND_PORT + KF_SEND_FILE send a file to a device once it's paired.
void main() {
  final dir = Platform.environment['KF_PEER_DIR'];
  test('peer', () async {
    log.echo = true;
    final root = Directory(dir!)..createSync(recursive: true);
    final node = await KickNode.open(
      dataDir: Directory(p.join(root.path, 'data')),
      files: IoFileAccess(p.join(root.path, 'received')),
      defaultName: Platform.environment['KF_PEER_NAME'] ?? 'Test Mac peer',
      platform: DevicePlatform.macos,
    );
    await node.settings.update((s) => s.copyWith(onboarded: true));
    node.receiver.onRequest = (r) async {
      stdout.writeln('PEER request from ${r.senderName}: ${r.offer.fileCount} files, first contact ${r.firstContact}, code ${r.code}');
      return Decision.trustAuto;
    };
    node.receiver.completed.listen((s) {
      stdout.writeln('PEER received ${s.state.name}: ${s.doneFiles}/${s.fileCount} files');
      for (final f in s.files) {
        stdout.writeln('PEER file ${f.item.path} ${f.item.size} -> ${f.location}');
      }
      for (final t in s.items.values.where((i) => i.item.kind == ItemKind.text)) {
        stdout.writeln('PEER text "${t.item.text}"');
      }
    });
    await node.start(port: kDefaultPort, bindAddress: InternetAddress.anyIPv4);
    final secret = node.receiver.newPairingSecret();
    stdout.writeln('PEER ready fp=${node.fingerprint.substring(0, 12)} port=${node.port} shortcode-for-emulator=2-$secret');
    File(p.join(root.path, 'secret.txt')).writeAsStringSync(secret);
    File(p.join(root.path, 'pair-link.txt')).writeAsStringSync(
      'kickfile://c?v=1&a=10.0.2.2&p=${node.port}&fp=${node.fingerprint}&s=$secret&n=${Uri.encodeQueryComponent(node.info.name)}',
    );

    final sendHost = Platform.environment['KF_SEND_HOST'];
    final sendFile = Platform.environment['KF_SEND_FILE'];
    final deadline = DateTime.now().add(Duration(seconds: int.parse(Platform.environment['KF_PEER_SECONDS'] ?? '300')));
    var sent = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (File(p.join(root.path, 'stop')).existsSync()) break;
      if (!sent && sendHost != null && sendFile != null && File(p.join(root.path, 'go')).existsSync()) {
        sent = true;
        final port = int.parse(Platform.environment['KF_SEND_PORT'] ?? '$kDefaultPort');
        final info = await node.client.info(sendHost, port);
        stdout.writeln('PEER sending to ${info.name} (${info.fingerprint.substring(0, 12)})');
        final f = File(sendFile);
        final st = f.statSync();
        final job = node.transfers.send(
          to: PeerEndpoint(sendHost, port, info.fingerprint),
          peerName: info.name,
          peerPlatform: info.platform,
          sources: [SendSource(kind: ItemKind.file, relPath: p.basename(f.path), ref: f.path, size: st.size, mtime: st.modified.millisecondsSinceEpoch)],
        );
        while (!job.isFinished) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        stdout.writeln('PEER send finished: ${job.state.name} ${job.error ?? ''} in ${DateTime.now().difference(job.startedAt).inMilliseconds} ms');
        if (job.state == SendState.done) stdout.writeln('PEER send speed ${(job.totalBytes / 1e6 / (DateTime.now().difference(job.startedAt).inMilliseconds / 1000)).toStringAsFixed(1)} MB/s');
      }
    }
    await node.dispose();
  }, skip: dir == null, timeout: const Timeout(Duration(hours: 1)));
}
