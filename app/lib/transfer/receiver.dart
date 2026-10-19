// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/auth.dart';
import '../core/errors.dart';
import '../core/log.dart';
import '../core/protocol.dart';
import '../core/sas.dart';
import '../net/server.dart';
import '../storage/history.dart';
import '../storage/json_store.dart';
import '../storage/peers.dart';
import 'file_access.dart';
import 'models.dart';

const _writeBatch = 1 << 20;

/// The user's answer to an incoming request (US-005, US-008, US-010).
enum Decision { accept, trust, trustAuto, decline, block }

/// A transfer waiting for the user to accept it.
class IncomingRequest {
  IncomingRequest({
    required this.offer,
    required this.senderFingerprint,
    required this.firstContact,
    required this.code,
    required this.expiresAt,
    required this.recentDeclines,
    this.peer,
    this.identityChangedFrom,
  });

  final TransferOffer offer;
  final String senderFingerprint;
  final PeerRecord? peer;

  /// Not trusted yet: show the trust prompt with [code].
  final bool firstContact;
  final String code;

  /// A trusted device with this name now has a different key.
  final PeerRecord? identityChangedFrom;
  final DateTime expiresAt;

  /// Declines from this device in the last 10 minutes (Block shows at 3).
  final int recentDeclines;

  final _answer = Completer<Decision>();
  bool get answered => _answer.isCompleted;

  /// The sender cancelled before anyone answered (the prompt closes with a note).
  bool cancelledBySender = false;
  Future<Decision> get decision => _answer.future;

  void answer(Decision d) {
    if (!_answer.isCompleted) _answer.complete(d);
  }

  String get senderName => peer?.displayName ?? offer.senderName;
}

enum SessionState { active, paused, done, partial, cancelled }

class ReceivedItem {
  ReceivedItem(this.item, {this.done = false});
  final OfferItem item;

  /// Bumped by every upload; a stale handler (old half-open socket) sees a newer value
  /// and backs off without flushing, hashing or pausing (BUG-006).
  int gen = 0;
  String? partialRef;
  int received = 0;
  Hasher? hasher;
  bool done;
  String? location;
  String? error;
}

/// One incoming transfer (accepted).
class IncomingSession {
  IncomingSession({
    required this.offer,
    required this.senderFingerprint,
    required this.senderName,
    required this.senderPlatform,
    required this.items,
    required this.createdAt,
  });

  final TransferOffer offer;
  final String senderFingerprint;
  final String senderName;
  final DevicePlatform senderPlatform;
  final Map<String, ReceivedItem> items;
  final DateTime createdAt;
  SessionState state = SessionState.active;
  DateTime lastActivity = DateTime.now();

  /// Time spent actually receiving (accept → finish, minus paused time) (BUG-001).
  final clock = ActiveClock()..start();
  DateTime? finishedAt;

  /// Paused because this device ran out of space (BUG-017).
  bool get outOfSpace => error == KfErrorCode.noSpace;
  final meter = SpeedMeter();
  ReceivedItem? current;
  KfErrorCode? error;
  bool cancelledByPeer = false;

  String get id => offer.id;
  Iterable<ReceivedItem> get files => items.values.where((i) => i.item.kind == ItemKind.file);
  int get totalBytes => offer.totalBytes;
  int get receivedBytes => files.fold(0, (a, i) => a + (i.done ? i.item.size : i.received));
  int get fileCount => offer.fileCount;
  int get doneFiles => files.where((i) => i.done).length;
  bool get allDone => items.values.every((i) => i.done);
}

/// Accepts offers, writes files and keeps resumable state (ServerPolicy for KfServer).
class ReceiveManager extends ChangeNotifier implements ServerPolicy {
  ReceiveManager({
    required this.files,
    required this.peers,
    required this.history,
    required this.manifestDir,
    required this.myFingerprint,
    required this.infoOf,
    required this.hiddenOf,
    this.offerTimeout = kOfferTimeout,
    this.staleAfter = const Duration(seconds: 30),
  });

  final FileAccess files;
  final PeerStore peers;
  final HistoryStore history;
  final Directory manifestDir;
  final String myFingerprint;
  final DeviceInfo Function() infoOf;
  final bool Function() hiddenOf;
  final Duration offerTimeout;
  final Duration staleAfter;

  /// The UI's prompt. Null (no UI) means every non-auto request is declined.
  Future<Decision> Function(IncomingRequest request)? onRequest;

  /// Called after a successful QR/short-code pairing (to close the QR screen).
  void Function(PeerRecord peer)? onPaired;

  /// A verified request arrived from [fingerprint] at [host]: it's reachable (BUG-011).
  void Function(String fingerprint, String? host)? onPeerContact;

  IncomingRequest? pending;
  IncomingSession? session;

  /// The last finished/cancelled session, for the "Done · Open" state.
  IncomingSession? lastFinished;
  final _completed = StreamController<IncomingSession>.broadcast();
  Stream<IncomingSession> get completed => _completed.stream;

  final _paused = <String, IncomingSession>{};
  final _cancelledIds = <String>{};
  final _lastOffer = <String, DateTime>{};
  final _declines = <String, List<DateTime>>{};
  String? _secret;
  DateTime? _secretAt;
  int _secretMisses = 0;
  Timer? _ticker;
  Timer? _saveTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Iterable<IncomingSession> get pausedSessions => _paused.values;

  /// Loads partial manifests, expires old ones, starts the stale-session check.
  Future<void> start() async {
    await manifestDir.create(recursive: true);
    await for (final f in manifestDir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final s = await _loadManifest(JsonFile(f));
      if (s != null) {
        s.state = SessionState.paused;
        _paused[s.id] = s;
        await _history(s, HistoryStatus.paused);
      }
    }
    await expirePartials();
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) => _checkStale());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _saveTimer?.cancel();
    _completed.close();
    super.dispose();
  }

  // ---------------- pairing ----------------

  /// A new one-time 6-digit secret for the QR code / short code (US-003).
  String newPairingSecret() {
    _secret = (Random.secure().nextInt(900000) + 100000).toString();
    _secretAt = DateTime.now();
    _secretMisses = 0;
    return _secret!;
  }

  void clearPairingSecret() => _secret = null;

  @override
  bool checkPairingSecret(String secret) {
    final at = _secretAt;
    final ok = _secret != null && secret == _secret && at != null && DateTime.now().difference(at) < kPairingSecretTtl;
    // A 6-digit secret can't survive guessing: after too many wrong tries it stops working (reopen Show QR for a new one).
    if (!ok && _secret != null && ++_secretMisses >= kPairingSecretMaxMisses) _secret = null;
    return ok;
  }

  @override
  Future<void> pair(Caller caller, String secret, DeviceInfo callerInfo) async {
    if (!checkPairingSecret(secret)) throw KfError(KfErrorCode.badSecret);
    _secret = null;
    await peers.seen(callerInfo);
    final p = await peers.update(caller.fingerprint, (p) => p.copyWith(trusted: true, blocked: false));
    onPaired?.call(p);
    notifyListeners();
  }

  // ---------------- ServerPolicy ----------------

  @override
  DeviceInfo info() => infoOf();

  @override
  bool get hidden => hiddenOf();

  @override
  bool isTrusted(String fingerprint) => peers.isTrusted(fingerprint);

  @override
  Future<OfferAnswer> offer(Caller caller, TransferOffer offer) async {
    final fp = caller.fingerprint;
    if (peers.isBlocked(fp)) throw KfError(KfErrorCode.declined);
    if (_cancelledIds.contains(offer.id)) throw KfError(KfErrorCode.cancelled);

    final existing = (session?.id == offer.id) ? session : _paused[offer.id];
    if (existing != null) {
      if (existing.senderFingerprint != fp) throw KfError(KfErrorCode.invalidOffer, 'id in use');
      return _resume(existing);
    }

    final now = DateTime.now();
    final last = _lastOffer[fp];
    if (last != null && now.difference(last) < kRateLimit) throw KfError(KfErrorCode.rateLimited);
    _lastOffer[fp] = now;
    onPeerContact?.call(fp, caller.host);

    // Before the busy check: no await may sit between that check and `pending = req`.
    final free = await files.freeBytes();
    if (free != null && free < offer.totalBytes + 64 * 1024 * 1024) {
      throw KfError(KfErrorCode.noSpace, null, {'needed': offer.totalBytes, 'free': free});
    }
    if (_busy) throw KfError(KfErrorCode.busy);

    final record = peers[fp];
    final changedFrom = peers.identityChangedFor(fp, offer.senderName, offer.senderPlatform);
    final auto = record != null && record.trusted && record.autoAccept && !record.blocked;

    Decision decision;
    if (auto) {
      decision = Decision.accept;
    } else {
      final ask = onRequest;
      if (ask == null) throw KfError(KfErrorCode.declined);
      final req = IncomingRequest(
        offer: offer,
        senderFingerprint: fp,
        peer: record,
        firstContact: !(record?.trusted ?? false),
        code: verificationCode(fp, myFingerprint),
        expiresAt: now.add(offerTimeout),
        recentDeclines: _recentDeclines(fp),
        identityChangedFrom: changedFrom,
      );
      pending = req;
      notifyListeners();
      try {
        decision = await Future.any([ask(req), req.decision]).timeout(offerTimeout);
      } on TimeoutException {
        req.answer(Decision.decline);
        pending = null;
        notifyListeners();
        await _historyMissed(offer, fp);
        throw KfError(KfErrorCode.timeout);
      }
      req.answer(decision);
      pending = null;
      notifyListeners();
      // The sender cancelled (or pressed Undo) while we were asking.
      if (req.cancelledBySender || _cancelledIds.contains(offer.id)) throw KfError(KfErrorCode.cancelled);
    }

    final seenInfo = DeviceInfo(
      fingerprint: fp,
      name: offer.senderName,
      platform: offer.senderPlatform,
      port: record?.port ?? kDefaultPort,
    );
    switch (decision) {
      case Decision.decline:
        (_declines[fp] ??= []).add(DateTime.now());
        throw KfError(KfErrorCode.declined);
      case Decision.block:
        await peers.seen(seenInfo);
        await peers.update(fp, (p) => p.copyWith(blocked: true, trusted: false, autoAccept: false));
        throw KfError(KfErrorCode.declined);
      case Decision.trust:
      case Decision.trustAuto:
        await peers.seen(seenInfo);
        await peers.update(fp, (p) => p.copyWith(trusted: true, autoAccept: decision == Decision.trustAuto));
      case Decision.accept:
        await peers.seen(seenInfo);
    }
    if (_busy) throw KfError(KfErrorCode.busy);
    return _accept(offer, fp);
  }

  bool get _busy {
    if (pending != null) return true;
    final s = session;
    return s != null &&
        s.state == SessionState.active &&
        DateTime.now().difference(s.lastActivity) < staleAfter;
  }

  int _recentDeclines(String fp) {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    final list = _declines[fp]?..removeWhere((t) => t.isBefore(cutoff));
    return list?.length ?? 0;
  }

  Future<OfferAnswer> _accept(TransferOffer offer, String fp) async {
    _pauseCurrent();
    final record = peers[fp];
    final items = <String, ReceivedItem>{};
    for (final i in offer.items) {
      final r = ReceivedItem(i, done: i.kind != ItemKind.file);
      if (i.kind == ItemKind.dir) {
        try {
          await files.createDir(i.path);
        } catch (e) {
          r.error = 'io';
        }
      }
      items[i.id] = r;
    }
    final s = IncomingSession(
      offer: offer,
      senderFingerprint: fp,
      senderName: record?.displayName ?? offer.senderName,
      senderPlatform: offer.senderPlatform,
      items: items,
      createdAt: DateTime.now(),
    );
    session = s;
    await _history(s, HistoryStatus.active);
    await _saveManifest(s);
    notifyListeners();
    log.info('recv', 'accepted ${offer.fileCount} files, ${offer.totalBytes} bytes');
    return OfferAnswer(
      offsets: {for (final r in s.files) r.item.id: 0},
      done: {for (final r in items.values) if (r.done) r.item.id},
    );
  }

  Future<OfferAnswer> _resume(IncomingSession s) async {
    // Paused because this device was full: only resume once there's room (BUG-017).
    // The sender learns it here, since a 507 can't reach it while it's still uploading.
    if (s.outOfSpace) {
      final free = await files.freeBytes();
      final remaining = s.totalBytes - s.receivedBytes;
      if (free != null && free < remaining) {
        throw KfError(KfErrorCode.noSpace, null, {'needed': remaining, 'free': free});
      }
    }
    if (session != s) {
      if (_busy) throw KfError(KfErrorCode.busy);
      _pauseCurrent();
      _paused.remove(s.id);
      session = s;
    }
    s.state = SessionState.active;
    s.clock.start();
    s.lastActivity = DateTime.now();
    s.error = null;
    final offsets = <String, int>{};
    for (final r in s.files) {
      if (r.done) continue;
      r.received = r.partialRef == null ? 0 : await files.partialLength(r.partialRef!);
      if (r.received > r.item.size) r.received = 0;
      offsets[r.item.id] = r.received;
    }
    await _history(s, HistoryStatus.active);
    notifyListeners();
    log.info('recv', 'resumed ${s.doneFiles}/${s.fileCount}');
    return OfferAnswer(offsets: offsets, done: {for (final r in s.items.values) if (r.done) r.item.id});
  }

  IncomingSession _sessionFor(Caller caller, String transferId) {
    if (_cancelledIds.contains(transferId)) throw KfError(KfErrorCode.cancelled);
    var s = session?.id == transferId ? session : null;
    if (s == null) {
      final paused = _paused[transferId];
      if (paused == null) throw KfError(KfErrorCode.unknownTransfer);
      if (paused.senderFingerprint != caller.fingerprint) throw KfError(KfErrorCode.unauthorized);
      if (_busy) throw KfError(KfErrorCode.busy);
      _pauseCurrent();
      _paused.remove(transferId);
      session = s = paused..state = SessionState.active;
      s.clock.start();
    }
    if (s.senderFingerprint != caller.fingerprint) throw KfError(KfErrorCode.unauthorized);
    if (s.state == SessionState.cancelled) throw KfError(KfErrorCode.cancelled);
    return s;
  }

  @override
  Future<int> upload(
    Caller caller,
    String transferId,
    String itemId,
    int offset,
    int length,
    Stream<List<int>> body,
  ) async {
    final s = _sessionFor(caller, transferId);
    onPeerContact?.call(caller.fingerprint, caller.host);
    final r = s.items[itemId] ?? (throw KfError(KfErrorCode.notFound));
    if (r.item.kind != ItemKind.file) throw KfError(KfErrorCode.invalidOffer, 'not a file');
    if (r.done) return r.item.size;
    if (offset != 0 && offset != r.received) {
      throw KfError(KfErrorCode.offsetMismatch, null, {'received': r.received});
    }
    if (offset + length != r.item.size) throw KfError(KfErrorCode.invalidOffer, 'length');

    final g = ++r.gen;
    r.partialRef ??= await files.createPartial(s.id, itemId, r.item.path, r.item.size);
    final writer = await files.openPartial(r.partialRef!, offset);
    if (offset == 0) {
      r.hasher = Hasher();
    } else if (r.hasher == null || r.hasher!.bytes != offset) {
      r.hasher = await Hasher.ofStream(files.readPartial(r.partialRef!));
    }
    r.received = offset;
    s.current = r;
    s.state = SessionState.active;
    s.lastActivity = DateTime.now();
    notifyListeners();

    // TLS hands us ~4 KB pieces; write in 1 MiB batches (one disk call each).
    final buf = BytesBuilder(copy: true);
    bool stale() => r.gen != g;
    Future<void> flush() async {
      if (buf.isEmpty || stale()) return;
      final bytes = buf.takeBytes();
      await writer.add(bytes);
      r.received += bytes.length;
      s.lastActivity = DateTime.now();
      _tick(s);
    }

    Object? failure;
    try {
      await for (final chunk in body) {
        if (s.state == SessionState.cancelled) throw KfError(KfErrorCode.cancelled);
        if (stale()) throw KfError(KfErrorCode.unreachable, 'superseded');
        r.hasher!.add(chunk);
        buf.add(chunk);
        if (buf.length >= _writeBatch) await flush();
      }
    } catch (e) {
      failure = e;
    } finally {
      try {
        if (failure == null || failure is! KfError) await flush();
      } catch (e) {
        failure ??= e;
      }
      await writer.close();
    }

    if (s.state == SessionState.cancelled) throw KfError(KfErrorCode.cancelled);
    // A newer upload of this item took over: leave the session to it.
    if (stale()) throw KfError(KfErrorCode.unreachable, 'superseded');
    if (failure is KfError && failure.code == KfErrorCode.noSpace) {
      s.error = KfErrorCode.noSpace;
      await _pause(s);
      throw failure;
    }
    if (failure != null || r.received != offset + length) {
      // The sender went away mid-file. Keep the partial for resume.
      r.hasher = null;
      await _pause(s);
      throw KfError(KfErrorCode.unreachable, 'incomplete upload');
    }
    _scheduleSave(s);
    return r.received;
  }

  @override
  Future<void> done(Caller caller, String transferId, String itemId, String sha256) async {
    final s = _sessionFor(caller, transferId);
    final r = s.items[itemId] ?? (throw KfError(KfErrorCode.notFound));
    if (r.done) return;
    final ref = r.partialRef;
    if (ref == null || r.received != r.item.size) {
      throw KfError(KfErrorCode.offsetMismatch, null, {'received': r.received});
    }
    final actual = (r.hasher ?? await Hasher.ofStream(files.readPartial(ref))).finish();
    r.hasher = null;
    if (actual != sha256) {
      await files.discard(ref);
      r.partialRef = null;
      r.received = 0;
      log.warn('recv', 'hash mismatch');
      throw KfError(KfErrorCode.hashMismatch);
    }
    try {
      r.location = await files.finalize(ref, r.item.path, mtime: r.item.mtime);
      r.partialRef = null;
      r.done = true;
    } on KfError catch (e) {
      r.error = e.code.wire;
      rethrow;
    }
    s.lastActivity = DateTime.now();
    _scheduleSave(s);
    notifyListeners();
  }

  @override
  Future<void> finish(Caller caller, String transferId) async {
    final s = _sessionFor(caller, transferId);
    s.state = s.allDone ? SessionState.done : SessionState.partial;
    await _close(s, s.allDone ? HistoryStatus.done : HistoryStatus.partial);
    log.info('recv', 'finished ${s.doneFiles}/${s.fileCount}');
  }

  @override
  Future<void> cancel(Caller caller, String transferId) async {
    final s = session?.id == transferId ? session : _paused[transferId];
    if (s == null) {
      final p = pending;
      if (p != null && p.offer.id == transferId && p.senderFingerprint == caller.fingerprint) {
        _cancelledIds.add(transferId);
        p.cancelledBySender = true;
        p.answer(Decision.decline);
      }
      return;
    }
    if (s.senderFingerprint != caller.fingerprint) throw KfError(KfErrorCode.unauthorized);
    s.cancelledByPeer = true;
    await _cancel(s);
  }

  /// The receiving user tapped Cancel (US-006).
  Future<void> cancelLocal([String? transferId]) async {
    final s = transferId == null ? session : (session?.id == transferId ? session : _paused[transferId]);
    if (s != null) await _cancel(s);
  }

  /// Deletes partial transfers older than 24 h (US-012).
  Future<void> expirePartials() async {
    final cutoff = DateTime.now().subtract(kPartialTtl);
    for (final s in _paused.values.toList()) {
      if (s.createdAt.isAfter(cutoff)) continue;
      _paused.remove(s.id);
      await files.removeTransferPartials(s.id);
      await _manifestFile(s.id).delete();
      await _history(s, HistoryStatus.expired, finished: true);
    }
  }

  // ---------------- internals ----------------

  Future<void> _cancel(IncomingSession s) async {
    s.state = SessionState.cancelled;
    _cancelledIds.add(s.id);
    if (_cancelledIds.length > 200) _cancelledIds.remove(_cancelledIds.first);
    for (final r in s.files) {
      if (r.partialRef != null) await files.discard(r.partialRef!);
      r.partialRef = null;
    }
    await _close(s, HistoryStatus.cancelled);
  }

  Future<void> _close(IncomingSession s, HistoryStatus status) async {
    _saveTimer?.cancel();
    s.clock.stop();
    s.finishedAt = DateTime.now();
    if (session == s) session = null;
    _paused.remove(s.id);
    await files.removeTransferPartials(s.id);
    await _manifestFile(s.id).delete();
    _manifests.remove(s.id);
    await _history(s, status, finished: true);
    lastFinished = s;
    _completed.add(s);
    notifyListeners();
  }

  void _pauseCurrent() {
    final cur = session;
    if (cur != null && cur.state == SessionState.active) {
      unawaited(_pause(cur));
    }
  }

  Future<void> _pause(IncomingSession s) async {
    if (s.state != SessionState.active) return;
    s.state = SessionState.paused;
    s.clock.stop();
    if (session == s) session = null;
    _paused[s.id] = s;
    await _saveManifest(s);
    // A cancel or finish may have landed while we were writing: don't overwrite its result.
    if (s.state != SessionState.paused) return;
    await _history(s, HistoryStatus.paused);
    notifyListeners();
  }

  void _checkStale() {
    final s = session;
    if (s != null &&
        s.state == SessionState.active &&
        DateTime.now().difference(s.lastActivity) > staleAfter) {
      unawaited(_pause(s));
    }
  }

  void _tick(IncomingSession s) {
    s.meter.sample(s.receivedBytes);
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 100)) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  Future<void> _historyMissed(TransferOffer offer, String fp) => history.put(
    HistoryEntry(
      id: offer.id,
      direction: Direction.incoming,
      peerFingerprint: fp,
      peerName: peers[fp]?.displayName ?? offer.senderName,
      peerPlatform: offer.senderPlatform,
      startedAt: DateTime.now().millisecondsSinceEpoch,
      status: HistoryStatus.missed,
      totalBytes: offer.totalBytes,
      fileCount: offer.fileCount,
      items: [
        for (final i in offer.items.take(50)) HistoryItem(name: i.path, size: i.size, kind: i.kind, ok: false),
      ],
    ),
  );

  Future<void> _history(IncomingSession s, HistoryStatus status, {bool finished = false}) {
    final old = history.byId(s.id, Direction.incoming);
    return history.put(
      HistoryEntry(
        id: s.id,
        direction: Direction.incoming,
        peerFingerprint: s.senderFingerprint,
        peerName: s.senderName,
        peerPlatform: s.senderPlatform,
        startedAt: old?.startedAt ?? s.createdAt.millisecondsSinceEpoch,
        finishedAt: finished ? DateTime.now().millisecondsSinceEpoch : null,
        status: status,
        totalBytes: s.totalBytes,
        doneBytes: s.receivedBytes,
        fileCount: s.fileCount,
        doneFiles: s.doneFiles,
        items: [
          for (final r in s.items.values)
            if (r.item.kind != ItemKind.dir || s.offer.fileCount == 0)
              HistoryItem(
                name: r.item.path,
                size: r.item.size,
                kind: r.item.kind,
                location: r.location,
                text: r.item.text,
                ok: r.done,
                error: r.error,
              ),
        ],
      ),
    );
  }

  // One JsonFile per transfer so writes and the final delete are serialised.
  final _manifests = <String, JsonFile>{};
  JsonFile _manifestFile(String id) =>
      _manifests.putIfAbsent(id, () => JsonFile(File(p.join(manifestDir.path, '$id.json'))));

  void _scheduleSave(IncomingSession s) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () => _saveManifest(s));
  }

  Future<void> _saveManifest(IncomingSession s) {
    if (s.state == SessionState.cancelled || s.state == SessionState.done) return Future.value();
    return _manifestFile(s.id).write({
      'offer': s.offer.toJson(),
      'senderFp': s.senderFingerprint,
      'senderName': s.senderName,
      'createdAt': s.createdAt.millisecondsSinceEpoch,
      'items': {
        for (final r in s.items.values)
          r.item.id: {'partialRef': r.partialRef, 'done': r.done, 'location': r.location},
      },
    });
  }

  Future<IncomingSession?> _loadManifest(JsonFile f) async {
    try {
      final j = await f.read();
      if (j == null) return null;
      final offer = TransferOffer.fromJson((j['offer']! as Map).cast<String, Object?>());
      final saved = (j['items'] as Map? ?? const {}).cast<String, Object?>();
      final items = <String, ReceivedItem>{};
      for (final i in offer.items) {
        final m = (saved[i.id] as Map?)?.cast<String, Object?>() ?? const {};
        items[i.id] = ReceivedItem(i, done: i.kind != ItemKind.file || m['done'] == true)
          ..partialRef = m['partialRef'] as String?
          ..location = m['location'] as String?;
      }
      return IncomingSession(
        offer: offer,
        senderFingerprint: j['senderFp']! as String,
        senderName: j['senderName'] as String? ?? offer.senderName,
        senderPlatform: offer.senderPlatform,
        items: items,
        createdAt: DateTime.fromMillisecondsSinceEpoch(j['createdAt']! as int),
      );
    } catch (e) {
      log.warn('recv', 'bad manifest: ${e.runtimeType}');
      await f.delete();
      return null;
    }
  }
}
