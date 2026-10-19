@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/auth.dart';
import 'package:kickfile/core/errors.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/storage/history.dart';
import 'package:kickfile/storage/json_store.dart';
import 'package:kickfile/transfer/file_access.dart';
import 'package:kickfile/transfer/io_file_access.dart';
import 'package:kickfile/transfer/receiver.dart';
import 'package:kickfile/transfer/sender.dart';
import 'package:path/path.dart' as p;

import '../support/nodes.dart';

/// Regression tests for the 2026-10-19 test round (BUG-001..BUG-017).
void main() {
  late TestDevice a;
  late TestDevice b;

  setUp(() async {
    a = await TestDevice.create('Alice laptop');
    b = await TestDevice.create('Bob phone');
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  Future<SendJob> start(TestDevice from, TestDevice to, List<int> sizes) async {
    final peer = await from.discover(to);
    final sources = [
      for (var i = 0; i < sizes.length; i++) await from.source(await from.makeFile('f$i.bin', sizes[i], seed: i + 1), 'f$i.bin'),
    ];
    return from.node.send(peer.copyWith(port: to.node.port), '127.0.0.1', sources);
  }

  test('BUG-001: the receiver\'s duration is frozen at finish and close to the sender\'s', () async {
    final job = await start(a, b, [2 * 1024 * 1024]);
    await waitFor(() => job.isFinished && b.node.receiver.lastFinished != null);
    final s = b.node.receiver.lastFinished!;
    final first = s.clock.elapsed;
    expect(s.finishedAt, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(s.clock.elapsed, first, reason: 'must not keep counting');
    expect(job.clock.elapsed, isNot(Duration.zero));
    // The sender no longer counts the wait for accept: both are well under the 1.5 s we waited.
    expect(job.clock.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('BUG-008: cancel while the receiver is asking closes the prompt; a late Accept does nothing', () async {
    b.answer = (_) => null; // the user hasn't answered yet
    final job = await start(a, b, [1000]);
    await waitFor(() => b.node.receiver.pending != null);
    final req = b.node.receiver.pending!;
    await job.cancel();
    await waitFor(() => req.answered);
    expect(req.cancelledBySender, isTrue);
    req.answer(Decision.accept); // too late
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(b.node.receiver.session, isNull);
    expect(job.state, SendState.cancelled);
  });

  test('BUG-010: a reinstalled trusted device (new key, same name) gets the identity-changed warning', () async {
    b.answer = (_) => Decision.trustAuto;
    final first = await start(a, b, [100]);
    await waitFor(() => first.isFinished);
    expect(b.node.peers.isTrusted(a.node.fingerprint), isTrue);

    // "Reinstall" Alice: new identity, same name and platform. Bob's discovery sees it first.
    final reinstalled = await TestDevice.create('Alice laptop');
    addTearDown(reinstalled.close);
    await b.node.peers.seen(reinstalled.node.info, addresses: ['127.0.0.1']);
    b.answer = (_) => Decision.decline;
    await Future<void>.delayed(kRateLimit);
    final job = await start(reinstalled, b, [100]);
    await waitFor(() => job.isFinished);
    expect(b.requests.last.identityChangedFrom?.fingerprint, a.node.fingerprint);
  });

  test('BUG-004: an upload that stops moving is aborted and the sender shows Reconnecting', () async {
    await a.close();
    await b.close();
    a = await TestDevice.create('Alice laptop', stallAfter: const Duration(seconds: 2), autoRetryFor: const Duration(seconds: 2));
    b = await TestDevice.create('Bob phone', files: (d) => HangingFileAccess(d, after: 1 << 20));
    final job = await start(a, b, [8 * 1024 * 1024]);
    final states = <SendState>{};
    job.addListener(() => states.add(job.state));
    await waitFor(() => states.contains(SendState.paused), timeout: const Duration(seconds: 30));
    expect(job.meter.bytesPerSecond, 0, reason: 'speed must not stay frozen at the last value');
    await job.cancel();
  });

  test('Cancel during a stalled upload stops at once (found while fixing BUG-004)', () async {
    await a.close();
    await b.close();
    a = await TestDevice.create('Alice laptop'); // default 15 s stall: cancel must not wait for it
    b = await TestDevice.create('Bob phone', files: (d) => HangingFileAccess(d, after: 1 << 20));
    final job = await start(a, b, [8 * 1024 * 1024]);
    await waitFor(() => (b.node.receiver.session?.receivedBytes ?? 0) >= 1 << 20);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final t = Stopwatch()..start();
    await job.cancel();
    await waitFor(() => job.isFinished, timeout: const Duration(seconds: 5));
    expect(job.state, SendState.cancelled);
    expect(t.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('BUG-006: a stale upload handler for the same item cannot pause or corrupt the newer one', () async {
    b.answer = (_) => Decision.accept;
    final r = b.node.receiver;
    final caller = Caller(a.node.fingerprint, a.node.identity.certDer, '127.0.0.1');
    const id = 'abcdef12-0000-4000-8000-0000000000b6';
    final data = List<int>.generate(300 * 1024, (i) => i % 251);
    await r.offer(
      caller,
      TransferOffer(
        id: id,
        senderName: 'Alice laptop',
        senderPlatform: DevicePlatform.macos,
        items: [OfferItem(id: 'i0', kind: ItemKind.file, path: 'x.bin', size: data.length)],
      ),
    );
    // Old connection: sends a little, then hangs (half-open socket).
    final old = StreamController<List<int>>();
    final oldUpload = r.upload(caller, id, 'i0', 0, data.length, old.stream).catchError((Object _) => 0);
    old.add(data.sublist(0, 1000));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Reconnect: a fresh upload of the whole item finishes and is verified.
    await r.upload(caller, id, 'i0', 0, data.length, Stream.value(data));
    await r.done(caller, id, 'i0', sha256.convert(data).toString());
    // Now the old socket finally errors.
    old.addError(const SocketException('reset'));
    await old.close();
    await oldUpload;
    expect(r.session?.state, SessionState.active, reason: 'the stale handler must not pause the session');
    await r.finish(caller, id);
    final saved = File(p.join(b.saveDir, 'x.bin'));
    expect(sha256.convert(await saved.readAsBytes()).toString(), sha256.convert(data).toString());
  });

  test('BUG-007: outgoing rows left at Sending become "interrupted" on load', () async {
    final dir = await Directory.systemTemp.createTemp('kf_hist_');
    addTearDown(() => dir.delete(recursive: true));
    final file = JsonFile(File(p.join(dir.path, 'history.json')));
    final h = await HistoryStore.load(file);
    await h.put(
      HistoryEntry(
        id: 'x',
        direction: Direction.outgoing,
        peerFingerprint: 'a' * 64,
        peerName: 'Bob',
        peerPlatform: DevicePlatform.android,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        status: HistoryStatus.active,
        totalBytes: 10,
        items: const [],
      ),
    );
    final again = await HistoryStore.load(file);
    expect(again.entries.single.status, HistoryStatus.interrupted);
  });

  test('BUG-017: running out of space mid-transfer pauses the sender for Resume instead of failing', () async {
    await b.close();
    b = await TestDevice.create('Bob phone', files: (d) => _FullDisk(d, after: 512 * 1024));
    final job = await start(a, b, [4 * 1024 * 1024]);
    await waitFor(() => job.waitingForResume || job.isFinished);
    expect(job.state, SendState.paused);
    expect(job.error?.code, KfErrorCode.noSpace);
    await waitFor(() => b.node.receiver.pausedSessions.any((s) => s.outOfSpace));
    await job.cancel();
  });
}

/// Disk that fills up after [after] bytes.
class _FullDisk extends IoFileAccess {
  _FullDisk(super.saveDir, {required this.after});
  final int after;
  int total = 0;
  bool full = false;

  @override
  Future<int?> freeBytes() async => full ? 0 : null;

  @override
  Future<PartialWriter> openPartial(String partialRef, int offset) async {
    final w = await super.openPartial(partialRef, offset);
    return _Limited(w, this);
  }
}

class _Limited implements PartialWriter {
  _Limited(this.inner, this.fs);
  final PartialWriter inner;
  final _FullDisk fs;

  @override
  Future<void> add(List<int> chunk) async {
    if (fs.total + chunk.length > fs.after) {
      fs.full = true;
      throw KfError(KfErrorCode.noSpace);
    }
    fs.total += chunk.length;
    await inner.add(chunk);
  }

  @override
  Future<void> close() => inner.close();
}
