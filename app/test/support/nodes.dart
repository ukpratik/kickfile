import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/net/client.dart';
import 'package:kickfile/storage/peers.dart';
import 'package:kickfile/transfer/file_access.dart';
import 'package:kickfile/transfer/io_file_access.dart';
import 'package:kickfile/transfer/node.dart';
import 'package:kickfile/transfer/receiver.dart';
import 'package:path/path.dart' as p;

/// A device under test: a [KickNode] on loopback with its own temp folders.
class TestDevice {
  TestDevice._(this.node, this.root, this.saveDir);

  final KickNode node;
  final Directory root;
  final String saveDir;

  /// Every request the UI was asked about, in order.
  final requests = <IncomingRequest>[];

  /// What the UI answers. Null = never answer (time out).
  FutureOr<Decision>? Function(IncomingRequest r) answer = (_) => Decision.trustAuto;

  static Future<TestDevice> create(
    String name, {
    Duration offerTimeout = const Duration(seconds: 5),
    Duration staleAfter = const Duration(seconds: 30),
    Duration autoRetryFor = const Duration(seconds: 10),
    Duration stallAfter = const Duration(seconds: 15),
    DevicePlatform platform = DevicePlatform.linux,
    FileAccess Function(String saveDir)? files,
  }) async {
    final root = await Directory.systemTemp.createTemp('kf_${name}_');
    final saveDir = p.join(root.path, 'Downloads', 'kickFile');
    final node = await KickNode.open(
      dataDir: Directory(p.join(root.path, 'data')),
      files: files?.call(saveDir) ?? IoFileAccess(saveDir),
      defaultName: name,
      platform: platform,
      offerTimeout: offerTimeout,
      staleAfter: staleAfter,
      autoRetryFor: autoRetryFor,
      retryEvery: const Duration(milliseconds: 200),
      stallAfter: stallAfter,
    );
    final d = TestDevice._(node, root, saveDir);
    node.receiver.onRequest = (r) async {
      d.requests.add(r);
      final a = d.answer(r);
      if (a == null) return Completer<Decision>().future;
      return a;
    };
    await node.start(port: 0, bindAddress: InternetAddress.loopbackIPv4);
    return d;
  }

  PeerEndpoint get endpoint => PeerEndpoint('127.0.0.1', node.port, node.fingerprint);

  /// Makes [other] known to this device (as discovery would) and returns its record.
  Future<PeerRecord> discover(TestDevice other) =>
      node.peers.seen(other.node.info, addresses: ['127.0.0.1']);

  Future<File> makeFile(String rel, int size, {int seed = 1}) async {
    final f = File(p.join(root.path, 'src', rel));
    await f.parent.create(recursive: true);
    final rnd = Random(seed);
    final sink = f.openWrite();
    var left = size;
    while (left > 0) {
      final n = min(left, 1 << 16);
      sink.add(List<int>.generate(n, (_) => rnd.nextInt(256)));
      left -= n;
    }
    await sink.close();
    return f;
  }

  Future<SendSource> source(File f, String relPath) async {
    final st = await f.stat();
    return SendSource(
      kind: ItemKind.file,
      relPath: relPath,
      ref: f.path,
      size: st.size,
      mtime: st.modified.millisecondsSinceEpoch,
    );
  }

  File received(String rel) => File(p.join(saveDir, rel));

  Future<void> close() async {
    await node.dispose();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  }
}

/// Reads slowly so tests can act mid-transfer.
class SlowFileAccess extends IoFileAccess {
  SlowFileAccess(super.saveDir, {this.delay = const Duration(milliseconds: 4)});
  final Duration delay;

  @override
  Stream<List<int>> openRead(SendSource source, {int offset = 0}) async* {
    await for (final c in super.openRead(source, offset: offset)) {
      await Future<void>.delayed(delay);
      yield c;
    }
  }
}

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Receiving side whose disk "hangs" after [after] bytes: the server stops reading (stall test).
class HangingFileAccess extends IoFileAccess {
  HangingFileAccess(super.saveDir, {this.after = 1 << 20});
  final int after;

  @override
  Future<PartialWriter> openPartial(String partialRef, int offset) async =>
      _HangWriter(await super.openPartial(partialRef, offset), after);
}

class _HangWriter implements PartialWriter {
  _HangWriter(this.inner, this.after);
  final PartialWriter inner;
  final int after;
  int written = 0;

  @override
  Future<void> add(List<int> chunk) async {
    if (written >= after) return Completer<void>().future; // never completes
    written += chunk.length;
    await inner.add(chunk);
  }

  @override
  Future<void> close() => inner.close();
}
