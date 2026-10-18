@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/errors.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/core/qr.dart';
import 'package:kickfile/core/sas.dart';
import 'package:kickfile/net/client.dart';
import 'package:kickfile/storage/history.dart';
import 'package:kickfile/transfer/file_access.dart';
import 'package:kickfile/transfer/receiver.dart';
import 'package:kickfile/transfer/sender.dart';
import 'package:path/path.dart' as p;

import '../support/nodes.dart';

Future<String> shaOf(File f) async => (await sha256.bind(f.openRead()).first).toString();

void main() {
  late TestDevice a; // sender
  late TestDevice b; // receiver

  setUp(() async {
    a = await TestDevice.create('Alice laptop');
    b = await TestDevice.create('Bob phone');
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  Future<SendJob> sendAndWait(TestDevice from, TestDevice to, List<SendSource> sources) async {
    final peer = await from.discover(to);
    final job = from.node.send(peer.copyWith(port: to.node.port), '127.0.0.1', sources);
    await waitFor(() => job.isFinished, timeout: const Duration(seconds: 60));
    return job;
  }

  test('first contact: trust prompt with matching code, then files, folders and text arrive intact', () async {
    final big = await a.makeFile('Trip/clip.mov', 3 * 1024 * 1024 + 17);
    final photo = await a.makeFile('Trip/sub/IMG_1.HEIC', 200 * 1024, seed: 2);
    final empty = await a.makeFile('zero.bin', 0);
    final weird = await a.makeFile('weird.txt', 10, seed: 3);
    final sources = [
      await a.source(big, 'Trip/clip.mov'),
      await a.source(photo, 'Trip/sub/IMG_1.HEIC'),
      const SendSource(kind: ItemKind.dir, relPath: 'Trip/empty'),
      await a.source(empty, 'zero.bin'),
      await a.source(weird, 'a:b?.txt'),
      const SendSource.text('https://example.com/ünïcode'),
    ];

    final job = await sendAndWait(a, b, sources);

    expect(job.state, SendState.done, reason: '${job.error}');
    expect(b.requests, hasLength(1));
    final req = b.requests.single;
    expect(req.firstContact, isTrue);
    expect(req.code, verificationCode(a.node.fingerprint, b.node.fingerprint));
    expect(req.offer.fileCount, 4);

    expect(await shaOf(b.received('Trip/clip.mov')), await shaOf(big));
    expect(await shaOf(b.received('Trip/sub/IMG_1.HEIC')), await shaOf(photo));
    expect(await b.received('zero.bin').length(), 0);
    expect(await b.received('a_b_.txt').exists(), isTrue);
    expect(await Directory(p.join(b.saveDir, 'Trip/empty')).exists(), isTrue);
    expect(await Directory(p.join(b.saveDir, '.kickfile-partial', job.id)).exists(), isFalse);

    // Both sides record it; the receiver keeps the text and file locations.
    final inEntry = b.node.history.byId(job.id, Direction.incoming)!;
    expect(inEntry.status, HistoryStatus.done);
    expect(inEntry.doneFiles, 4);
    expect(inEntry.items.where((i) => i.kind == ItemKind.text).single.text, 'https://example.com/ünïcode');
    expect(inEntry.items.firstWhere((i) => i.name == 'Trip/clip.mov').location, b.received('Trip/clip.mov').path);
    expect(a.node.history.byId(job.id, Direction.outgoing)!.status, HistoryStatus.done);

    // Trust & auto-accept was chosen, so the next send needs no prompt.
    expect(b.node.peers[a.node.fingerprint]!.trusted, isTrue);
    expect(b.node.peers[a.node.fingerprint]!.autoAccept, isTrue);
    await Future<void>.delayed(kRateLimit);
    final again = await sendAndWait(a, b, [await a.source(weird, 'weird.txt')]);
    expect(again.state, SendState.done);
    expect(b.requests, hasLength(1), reason: 'auto-accepted');
  });

  test('a name clash gets "(1)"', () async {
    final f = await a.makeFile('note.txt', 100);
    expect((await sendAndWait(a, b, [await a.source(f, 'note.txt')])).state, SendState.done);
    await Future<void>.delayed(kRateLimit);
    expect((await sendAndWait(a, b, [await a.source(f, 'note.txt')])).state, SendState.done);
    expect(await b.received('note.txt').exists(), isTrue);
    expect(await b.received('note (1).txt').exists(), isTrue);
  });

  test('decline: sender sees declined; Block stops later offers without asking', () async {
    final f = await a.makeFile('x.bin', 10);
    b.answer = (_) => Decision.decline;
    final job = await sendAndWait(a, b, [await a.source(f, 'x.bin')]);
    expect(job.state, SendState.declined);
    expect(await b.received('x.bin').exists(), isFalse);

    await Future<void>.delayed(kRateLimit);
    b.answer = (_) => Decision.block;
    await sendAndWait(a, b, [await a.source(f, 'x.bin')]);
    expect(b.requests.last.recentDeclines, 1);
    expect(b.node.peers.isBlocked(a.node.fingerprint), isTrue);

    await Future<void>.delayed(kRateLimit);
    final blocked = await sendAndWait(a, b, [await a.source(f, 'x.bin')]);
    expect(blocked.state, SendState.declined);
    expect(b.requests, hasLength(2), reason: 'blocked devices are not asked');
  });

  test('no answer within the timeout: sender sees timeout, receiver records "missed"', () async {
    await b.close();
    b = await TestDevice.create('Bob phone', offerTimeout: const Duration(seconds: 1));
    b.answer = (_) => null;
    final f = await a.makeFile('x.bin', 10);
    final job = await sendAndWait(a, b, [await a.source(f, 'x.bin')]);
    expect(job.state, SendState.timeout);
    expect(b.node.history.byId(job.id, Direction.incoming)!.status, HistoryStatus.missed);
  });

  test('busy while another device is waiting for an answer; rate limit per device', () async {
    final c = await TestDevice.create('Carol desktop');
    addTearDown(c.close);
    b.answer = (_) => null; // leave the first request hanging
    final f = await a.makeFile('x.bin', 10);
    final peerB = await a.discover(b);
    final first = a.node.send(peerB.copyWith(port: b.node.port), '127.0.0.1', [await a.source(f, 'x.bin')]);
    await waitFor(() => b.node.receiver.pending != null);

    final second = await sendAndWait(c, b, [await c.source(await c.makeFile('y.bin', 5), 'y.bin')]);
    expect(second.state, SendState.busy);

    b.node.receiver.pending!.answer(Decision.decline);
    await waitFor(() => first.isFinished);

    // Alice again within 5 s → rate limited.
    final third = await sendAndWait(a, b, [await a.source(f, 'x.bin')]);
    expect(third.state, SendState.failed);
    expect(third.error!.code, KfErrorCode.rateLimited);
  });

  test('sender cancels mid-transfer: receiver drops the partial and records cancelled', () async {
    await a.close();
    a = await TestDevice.create('Alice laptop', files: SlowFileAccess.new);
    final f = await a.makeFile('big.bin', 8 * 1024 * 1024);
    final peer = await a.discover(b);
    final job = a.node.send(peer.copyWith(port: b.node.port), '127.0.0.1', [await a.source(f, 'big.bin')]);
    await waitFor(() => job.sentBytes > 512 * 1024);
    await job.cancel();
    await waitFor(() => b.node.receiver.session == null);
    expect(job.state, SendState.cancelled);
    expect(job.cancelledByPeer, isFalse);
    // Let any late "paused" bookkeeping from the dropped upload settle; cancel must win.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(b.node.history.byId(job.id, Direction.incoming)!.status, HistoryStatus.cancelled);
    expect(File(p.join(b.root.path, 'data', 'partials', '${job.id}.json')).existsSync(), isFalse);
    expect(await b.received('big.bin').exists(), isFalse);
    expect(await Directory(p.join(b.saveDir, '.kickfile-partial', job.id)).exists(), isFalse);
  });

  test('receiver cancels: sender stops and says the other side cancelled', () async {
    await a.close();
    a = await TestDevice.create('Alice laptop', files: SlowFileAccess.new);
    final f = await a.makeFile('big.bin', 8 * 1024 * 1024);
    final peer = await a.discover(b);
    final job = a.node.send(peer.copyWith(port: b.node.port), '127.0.0.1', [await a.source(f, 'big.bin')]);
    await waitFor(() => (b.node.receiver.session?.receivedBytes ?? 0) > 512 * 1024);
    await b.node.receiver.cancelLocal();
    await waitFor(() => job.isFinished);
    expect(job.state, SendState.cancelled);
    expect(job.cancelledByPeer, isTrue);
  });

  test('connection drops mid-file: the sender pauses, then resumes from the received offset', () async {
    await a.close();
    a = await TestDevice.create('Alice laptop', files: SlowFileAccess.new);
    final f = await a.makeFile('video.mov', 10 * 1024 * 1024, seed: 9);
    final peer = await a.discover(b);
    final port = b.node.port;
    final job = a.node.send(peer.copyWith(port: port), '127.0.0.1', [await a.source(f, 'video.mov')]);
    await waitFor(() => (b.node.receiver.session?.receivedBytes ?? 0) > 2 * 1024 * 1024);

    await b.node.server.stop(); // Wi-Fi drops
    await waitFor(() => job.state == SendState.paused);
    await waitFor(() => b.node.receiver.pausedSessions.isNotEmpty);
    final partial = Directory(p.join(b.saveDir, '.kickfile-partial', job.id));
    final kept = await File(p.join(partial.path, 'i0.part')).length();
    expect(kept, greaterThan(1024 * 1024));

    await b.node.server.start(port: port, address: InternetAddress.loopbackIPv4); // back
    await waitFor(() => job.isFinished, timeout: const Duration(seconds: 60));
    expect(job.state, SendState.done, reason: '${job.error}');
    expect(await shaOf(b.received('video.mov')), await shaOf(f));
  });

  test('a file deleted before sending fails alone; the rest arrive (partial)', () async {
    final ok = await a.makeFile('ok.bin', 1000);
    final gone = await a.makeFile('gone.bin', 1000, seed: 4);
    final sources = [await a.source(gone, 'gone.bin'), await a.source(ok, 'ok.bin')];
    await gone.delete();
    final job = await sendAndWait(a, b, sources);
    expect(job.state, SendState.partial);
    expect(job.failedItems.single.error, KfErrorCode.sourceMissing);
    expect(await b.received('ok.bin').exists(), isTrue);
    expect(b.node.history.byId(job.id, Direction.incoming)!.status, HistoryStatus.partial);
  });

  group('protocol guards', () {
    late KfClient raw;
    setUp(() => raw = KfClient(a.node.identity));
    tearDown(() => raw.close());

    test('a wrong hash is rejected and the partial discarded', () async {
      b.answer = (_) => Decision.accept;
      const id = 'abcdef12-0000-4000-8000-000000000001';
      final offer = TransferOffer(
        id: id,
        senderName: 'Alice',
        senderPlatform: DevicePlatform.linux,
        items: [const OfferItem(id: 'i0', kind: ItemKind.file, path: 'x.bin', size: 3)],
      );
      await raw.offer(b.endpoint, offer);
      await raw.upload(b.endpoint, id, 'i0', 0, 3, Stream.value([1, 2, 3]));
      expect(
        () => raw.done(b.endpoint, id, 'i0', '0' * 64),
        throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.hashMismatch)),
      );
    });

    test('path traversal in an offer is refused', () async {
      final offer = TransferOffer(
        id: 'abcdef12-0000-4000-8000-000000000002',
        senderName: 'Alice',
        senderPlatform: DevicePlatform.linux,
        items: [const OfferItem(id: 'i0', kind: ItemKind.file, path: '../../etc/passwd', size: 3)],
      );
      expect(
        () => raw.offer(b.endpoint, offer),
        throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.invalidOffer)),
      );
      expect(b.requests, isEmpty);
    });

    test('unsigned requests are refused', () async {
      final http = HttpClient()..badCertificateCallback = (c, h, port) => true;
      addTearDown(() => http.close(force: true));
      final req = await http.postUrl(Uri.parse('https://127.0.0.1:${b.node.port}/v1/transfers'));
      req.write(jsonEncode({}));
      final res = await req.close();
      expect(res.statusCode, 401);
    });

    test('the client refuses a device whose certificate does not match the pin', () async {
      final wrong = PeerEndpoint('127.0.0.1', b.node.port, a.node.fingerprint);
      expect(
        () => raw.info('127.0.0.1', b.node.port, expectFingerprint: wrong.fingerprint),
        throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.identityMismatch)),
      );
    });
  });

  group('pairing and visibility', () {
    test('QR code pairs both ways and trusts, with no verification code later', () async {
      final secret = b.node.receiver.newPairingSecret();
      final code = PairingCode(
        addresses: const ['127.0.0.1'],
        port: b.node.port,
        fingerprint: b.node.fingerprint,
        secret: secret,
        name: 'Bob phone',
      );
      final parsed = PairingCode.parse(code.toUri());
      final peer = await a.node.pairWithCode(parsed);
      expect(peer.trusted, isTrue);
      expect(b.node.peers.isTrusted(a.node.fingerprint), isTrue);

      // The secret is single-use.
      expect(
        () => a.node.pairWithCode(parsed),
        throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.badSecret)),
      );

      b.answer = (_) => Decision.accept;
      final f = await a.makeFile('x.bin', 10);
      await sendAndWait(a, b, [await a.source(f, 'x.bin')]);
      expect(b.requests.single.firstContact, isFalse);
    });

    test('a wrong secret is refused', () async {
      b.node.receiver.newPairingSecret();
      final code = PairingCode(
        addresses: const ['127.0.0.1'],
        port: b.node.port,
        fingerprint: b.node.fingerprint,
        secret: '000000',
        name: 'Bob',
      );
      expect(
        () => a.node.pairWithCode(code),
        throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.badSecret)),
      );
      expect(b.node.peers.isTrusted(a.node.fingerprint), isFalse);
    });

    test('Hidden devices answer info only with a valid pairing secret', () async {
      await b.node.settings.update((s) => s.copyWith(visible: false));
      expect(
        () => a.node.client.info('127.0.0.1', b.node.port),
        throwsA(isA<KfError>()),
      );
      final secret = b.node.receiver.newPairingSecret();
      final info = await a.node.client.info('127.0.0.1', b.node.port, secret: secret);
      expect(info.fingerprint, b.node.fingerprint);
    });

    test('short code resolves against our subnet', () {
      expect(parseShortCode('23-482913', '192.168.1.40'), (host: '192.168.1.23', secret: '482913'));
      expect(parseShortCode('23 482 913', '10.0.0.5'), (host: '10.0.0.23', secret: '482913'));
      expect(parseShortCode('999-482913', '10.0.0.5'), isNull);
    });
  });
}
