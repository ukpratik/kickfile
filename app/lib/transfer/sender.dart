import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/log.dart';
import '../core/names.dart';
import '../core/protocol.dart';
import '../net/client.dart';
import '../net/server.dart' show OfferAnswer;
import 'file_access.dart';
import 'models.dart';

enum SendState {
  /// Offer sent, waiting for the other device to accept (US-004 waiting state).
  waiting,
  active,

  /// Connection lost; retrying automatically for [SendJob.autoRetryFor], then waiting for Resume.
  paused,
  done,
  partial,
  failed,
  cancelled,
  declined,
  timeout,
  busy,
}

class SendItem {
  SendItem(this.source, this.offerItem);
  final SendSource source;
  final OfferItem offerItem;
  int sent = 0;
  bool done = false;
  KfErrorCode? error;
}

/// One outgoing transfer to one device (US-004, US-006, US-012).
class SendJob extends ChangeNotifier {
  SendJob({
    required this.id,
    required this.endpoint,
    required this.peerName,
    required this.peerPlatform,
    required this.me,
    required this.sources,
    required this.client,
    required this.files,
    this.autoRetryFor = const Duration(seconds: 30),
    this.retryEvery = const Duration(seconds: 3),
  });

  final String id;
  PeerEndpoint endpoint;
  final String peerName;
  final DevicePlatform peerPlatform;
  final DeviceInfo me;
  final List<SendSource> sources;
  final KfClient client;
  final FileAccess files;
  final Duration autoRetryFor;
  final Duration retryEvery;

  SendState state = SendState.waiting;
  KfError? error;
  bool cancelledByPeer = false;
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;
  final meter = SpeedMeter();
  late final List<SendItem> items;
  late final TransferOffer offer;
  SendItem? current;

  final _handle = UploadHandle();
  Completer<void>? _resumeSignal;
  bool _cancelled = false;
  bool _started = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Iterable<SendItem> get fileItems => items.where((i) => i.offerItem.kind == ItemKind.file);
  int get totalBytes => offer.totalBytes;
  int get sentBytes => fileItems.fold(0, (a, i) => a + (i.done ? i.offerItem.size : i.sent));
  int get fileCount => offer.fileCount;
  int get doneFiles => fileItems.where((i) => i.done).length;
  List<SendItem> get failedItems => items.where((i) => i.error != null).toList();
  bool get isFinished => const {
    SendState.done,
    SendState.partial,
    SendState.failed,
    SendState.cancelled,
    SendState.declined,
    SendState.timeout,
    SendState.busy,
  }.contains(state);

  void _build() {
    var n = 0;
    items = [
      for (final s in sources)
        SendItem(
          s,
          OfferItem(
            id: 'i${n++}',
            kind: s.kind,
            path: s.kind == ItemKind.text ? s.relPath : _cleanPath(s.relPath),
            size: s.kind == ItemKind.file ? s.size : 0,
            mtime: s.mtime,
            text: s.text,
          ),
        ),
    ];
    offer = TransferOffer(
      id: id,
      senderName: me.name,
      senderPlatform: me.platform,
      items: [for (final i in items) i.offerItem],
    );
    offer.validate();
  }

  /// Runs the whole transfer. Completes when the job reaches a final state.
  Future<void> run() async {
    if (_started) return;
    _started = true;
    try {
      _build();
    } on KfError catch (e) {
      return _finish(SendState.failed, e);
    }
    var everAccepted = false;
    while (true) {
      try {
        await _attempt(firstTime: !everAccepted, onAccepted: () => everAccepted = true);
        return;
      } on KfError catch (e) {
        if (_cancelled) return _finish(SendState.cancelled);
        switch (e.code) {
          case KfErrorCode.declined:
            return _finish(SendState.declined, e);
          case KfErrorCode.timeout:
            return _finish(SendState.timeout, e);
          case KfErrorCode.busy when !everAccepted:
            return _finish(SendState.busy, e);
          case KfErrorCode.cancelled:
            cancelledByPeer = true;
            return _finish(SendState.cancelled, e);
          case KfErrorCode.unreachable || KfErrorCode.io || KfErrorCode.busy || KfErrorCode.unknownTransfer
              when everAccepted:
            if (!await _waitToRetry(e)) return _finish(SendState.cancelled);
          default:
            return _finish(SendState.failed, e);
        }
      }
    }
  }

  /// Stops on both sides (US-006).
  Future<void> cancel() async {
    if (isFinished) return;
    _cancelled = true;
    _handle.abort();
    _resumeSignal?.complete();
    try {
      await client.cancel(endpoint, id);
    } catch (_) {
      // Best effort: the receiver times out anyway.
    }
    if (state == SendState.paused || state == SendState.waiting) _finish(SendState.cancelled);
  }

  /// The user tapped Resume on a paused transfer (US-012).
  void resume({PeerEndpoint? at}) {
    if (at != null) endpoint = at;
    final r = _resumeSignal;
    if (r != null && !r.isCompleted) r.complete();
  }

  Future<bool> _waitToRetry(KfError e) async {
    error = e;
    _set(SendState.paused);
    final deadline = DateTime.now().add(autoRetryFor);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(retryEvery);
      if (_cancelled) return false;
      try {
        await client.info(endpoint.host, endpoint.port, expectFingerprint: endpoint.fingerprint);
        return true;
      } on KfError {
        // Still away.
      }
    }
    _resumeSignal = Completer<void>();
    notifyListeners();
    await _resumeSignal!.future;
    _resumeSignal = null;
    return !_cancelled;
  }

  bool get waitingForResume => _resumeSignal != null;

  Future<void> _attempt({required bool firstTime, required void Function() onAccepted}) async {
    _set(firstTime ? SendState.waiting : SendState.active);
    final OfferAnswer answer = await client.offer(endpoint, offer);
    onAccepted();
    if (_cancelled) throw KfError(KfErrorCode.cancelled);
    error = null;
    _set(SendState.active);
    meter.reset();

    for (final item in items) {
      if (item.offerItem.kind != ItemKind.file) {
        item.done = true;
        continue;
      }
      if (item.done || item.error != null) continue;
      if (answer.done.contains(item.offerItem.id)) {
        item.done = true;
        continue;
      }
      await _sendItem(item, answer.offsets[item.offerItem.id] ?? 0);
    }
    await client.finish(endpoint, id);
    _finish(failedItems.isEmpty ? SendState.done : SendState.partial);
  }

  Future<void> _sendItem(SendItem item, int offset, {bool retried = false}) async {
    final src = item.source;
    final size = item.offerItem.size;
    final st = await files.stat(src);
    if (st == null) {
      item.error = KfErrorCode.sourceMissing;
      return;
    }
    if (st.size != size || (src.mtime != 0 && st.mtime != src.mtime)) {
      item.error = KfErrorCode.sourceChanged;
      return;
    }
    if (offset < 0 || offset > size) offset = 0;
    current = item;

    final hasher = offset == 0 ? Hasher() : await Hasher.ofStream(_prefix(files.openRead(src), offset));
    item.sent = offset;
    notifyListeners();

    final counted = files.openRead(src, offset: offset).map((chunk) {
      if (_cancelled) throw KfError(KfErrorCode.cancelled);
      hasher.add(chunk);
      item.sent += chunk.length;
      if (item.sent > size) throw KfError(KfErrorCode.sourceChanged);
      _tick();
      return chunk;
    });
    try {
      await client.upload(endpoint, id, item.offerItem.id, offset, size - offset, counted, handle: _handle);
    } on KfError catch (e) {
      if (e.code == KfErrorCode.sourceChanged) {
        item.error = e.code;
        return;
      }
      if (e.code == KfErrorCode.offsetMismatch && !retried) {
        final received = e.data?['received'];
        return _sendItem(item, received is int ? received : 0, retried: true);
      }
      rethrow;
    }
    if (hasher.bytes != size) {
      item.error = KfErrorCode.sourceChanged;
      return;
    }
    try {
      await client.done(endpoint, id, item.offerItem.id, hasher.finish());
      item.done = true;
    } on KfError catch (e) {
      if (e.code != KfErrorCode.hashMismatch) rethrow;
      log.warn('send', 'hash mismatch, retrying from 0');
      if (retried) {
        item.error = KfErrorCode.hashMismatch;
        return;
      }
      return _sendItem(item, 0, retried: true);
    }
    notifyListeners();
  }

  void _tick() {
    meter.sample(sentBytes);
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 100)) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  void _set(SendState s) {
    state = s;
    notifyListeners();
  }

  void _finish(SendState s, [KfError? e]) {
    if (isFinished) return;
    state = s;
    error = e ?? error;
    finishedAt = DateTime.now();
    current = null;
    log.info('send', 'finished ${s.name} $doneFiles/$fileCount');
    notifyListeners();
  }
}

/// Names from this device's file system made safe for any receiver (`a:b?.txt` → `a_b_.txt`).
String _cleanPath(String relPath) => relPath
    .split('/')
    .where((s) => s.isNotEmpty && s != '.' && s != '..')
    .map(sanitizeSegment)
    .join('/');

/// The first [n] bytes of [s].
Stream<List<int>> _prefix(Stream<List<int>> s, int n) async* {
  var left = n;
  await for (final c in s) {
    if (left <= 0) break;
    if (c.length <= left) {
      yield c;
      left -= c.length;
    } else {
      yield c.sublist(0, left);
      left = 0;
    }
  }
}
