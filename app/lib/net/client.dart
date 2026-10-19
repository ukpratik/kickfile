import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/auth.dart';
import '../core/errors.dart';
import '../core/identity.dart';
import '../core/protocol.dart';
import 'server.dart' show OfferAnswer;

/// Where to reach a peer. [fingerprint] is the pinned identity.
class PeerEndpoint {
  const PeerEndpoint(this.host, this.port, this.fingerprint);
  final String host;
  final int port;
  final String fingerprint;

  @override
  String toString() => 'PeerEndpoint($host:$port)';
}

/// Lets the sender abort an upload in flight (Cancel).
class UploadHandle {
  HttpClientRequest? _req;
  void Function(KfError)? _fail;
  bool _aborted = false;
  bool get aborted => _aborted;

  void abort() {
    _aborted = true;
    // Fail our own body stream too: a backpressured addStream ignores req.abort.
    _fail?.call(KfError(KfErrorCode.cancelled));
    _req?.abort(KfError(KfErrorCode.cancelled));
  }
}

/// HTTPS client for protocol v1: pins the peer certificate and signs requests.
class KfClient {
  KfClient(this.me, {this.connectTimeout = const Duration(seconds: 5), this.stallAfter = const Duration(seconds: 15)});

  final DeviceIdentity me;
  final Duration connectTimeout;

  /// An upload with no bytes moving for this long is aborted, so the sender shows
  /// "Reconnecting…" instead of frozen numbers (BUG-004).
  final Duration stallAfter;
  final _pinned = <String, HttpClient>{};

  void close() {
    for (final c in _pinned.values) {
      c.close(force: true);
    }
    _pinned.clear();
  }

  HttpClient _clientFor(String fingerprint) => _pinned.putIfAbsent(fingerprint, () {
    final c = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 15)
      ..maxConnectionsPerHost = 4
      ..badCertificateCallback = (cert, host, port) => fingerprintOf(cert.der) == fingerprint;
    return c;
  });

  /// `GET /v1/info`. Without a known fingerprint (subnet probe, short code), any
  /// certificate is accepted, but its fingerprint must match the one the device reports.
  Future<DeviceInfo> info(
    String host,
    int port, {
    String? expectFingerprint,
    String? secret,
    Duration? timeout,
  }) async {
    String? seenFp;
    final client = expectFingerprint != null
        ? _clientFor(expectFingerprint)
        : (HttpClient(context: SecurityContext(withTrustedRoots: false))
            ..connectionTimeout = timeout ?? connectTimeout
            ..badCertificateCallback = (cert, h, p) {
              seenFp = fingerprintOf(cert.der);
              return true;
            });
    try {
      final path = secret == null ? '/v1/info' : '/v1/info?s=${Uri.encodeQueryComponent(secret)}';
      final req = await _open(client, 'GET', host, port, path, expectFingerprint).timeout(timeout ?? connectTimeout);
      final res = await req.close().timeout(timeout ?? connectTimeout);
      final body = await _readJson(res);
      final info = DeviceInfo.fromJson(body);
      if (expectFingerprint == null) {
        final sx509 = res.certificate;
        final actual = seenFp ?? (sx509 == null ? null : fingerprintOf(sx509.der));
        if (actual == null || actual != info.fingerprint) {
          throw KfError(KfErrorCode.identityMismatch, 'reported fingerprint differs');
        }
      }
      if (info.version != kProtocolVersion) {
        throw KfError(KfErrorCode.versionMismatch, '${info.version}');
      }
      return info;
    } on KfError {
      rethrow;
    } catch (e) {
      throw _netError(e);
    } finally {
      if (expectFingerprint == null) client.close(force: true);
    }
  }

  Future<void> pair(PeerEndpoint peer, String secret, DeviceInfo mine) async {
    await _postJson(peer, '/v1/pair', {
      'secret': secret,
      'name': mine.name,
      'platform': mine.platform.name,
      'port': mine.port,
    });
  }

  /// Blocks until the receiver answers (≤ 60 s) or the offer is resumable.
  Future<OfferAnswer> offer(PeerEndpoint peer, TransferOffer offer) async {
    final j = await _postJson(
      peer,
      '/v1/transfers',
      offer.toJson(),
      timeout: kOfferTimeout + const Duration(seconds: 15),
    );
    return OfferAnswer.fromJson(j);
  }

  Future<int> upload(
    PeerEndpoint peer,
    String transferId,
    String itemId,
    int offset,
    int length,
    Stream<List<int>> data, {
    UploadHandle? handle,
  }) async {
    final path = '/v1/transfers/$transferId/items/$itemId?offset=$offset';
    try {
      final req = await _open(_clientFor(peer.fingerprint), 'PUT', peer.host, peer.port, path, peer.fingerprint);
      handle?._req = req;
      if (handle?.aborted ?? false) throw KfError(KfErrorCode.cancelled);
      req.contentLength = length;
      req.headers.contentType = ContentType.binary;
      // We own the body stream so a stall or a Cancel can end a backpressured addStream,
      // which HttpClientRequest.abort alone doesn't (BUG-004).
      var moved = DateTime.now();
      var stalled = false;
      final body = StreamController<List<int>>();
      late final StreamSubscription<List<int>> source;
      // A paused subscription holds back errors too, so a stalled addStream can't be failed
      // through its own stream: race it against this instead.
      final failure = Completer<void>();
      var failed = false;
      void fail(KfError e) {
        if (failed) return;
        failed = true;
        unawaited(source.cancel());
        unawaited(body.close());
        req.abort(e);
        failure.completeError(e);
      }

      source = data.listen(
        (c) {
          moved = DateTime.now();
          body.add(c);
        },
        onError: (Object e, StackTrace st) => failed ? null : body.addError(e, st),
        onDone: () => failed ? null : body.close(),
      );
      body
        ..onPause = source.pause
        ..onResume = source.resume
        ..onCancel = () => source.cancel();
      handle?._fail = fail;
      final watchdog = Timer.periodic(Duration(milliseconds: (stallAfter.inMilliseconds / 3).ceil()), (_) {
        if (DateTime.now().difference(moved) > stallAfter) {
          stalled = true;
          fail(KfError(KfErrorCode.unreachable, 'stalled'));
        }
      });
      try {
        if (handle?.aborted ?? false) fail(KfError(KfErrorCode.cancelled));
        final sending = req.addStream(body.stream);
        unawaited(sending.catchError((Object _) {})); // may outlive a stall; its error is moot
        await Future.any([sending, failure.future]);
        final res = await req.close().timeout(stallAfter + const Duration(seconds: 5));
        final j = await _readJson(res).timeout(stallAfter + const Duration(seconds: 5));
        return j['received'] as int? ?? 0;
      } catch (e) {
        if (stalled) throw KfError(KfErrorCode.unreachable, 'stalled');
        if (handle?.aborted ?? false) throw KfError(KfErrorCode.cancelled);
        rethrow;
      } finally {
        watchdog.cancel();
        handle?._fail = null;
      }
    } on KfError {
      rethrow;
    } catch (e) {
      if (handle?.aborted ?? false) throw KfError(KfErrorCode.cancelled);
      throw _netError(e);
    } finally {
      handle?._req = null;
    }
  }

  Future<void> done(PeerEndpoint peer, String transferId, String itemId, String sha256) =>
      _postJson(peer, '/v1/transfers/$transferId/items/$itemId/done', {'sha256': sha256});

  Future<void> finish(PeerEndpoint peer, String transferId) =>
      _postJson(peer, '/v1/transfers/$transferId/finish', const {});

  Future<void> cancel(PeerEndpoint peer, String transferId) => _postJson(
    peer,
    '/v1/transfers/$transferId/cancel',
    const {},
    timeout: const Duration(seconds: 3),
  );

  Future<Map<String, Object?>> _postJson(
    PeerEndpoint peer,
    String path,
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final req = await _open(_clientFor(peer.fingerprint), 'POST', peer.host, peer.port, path, peer.fingerprint);
      req.headers.contentType = ContentType.json;
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      return await _readJson(res).timeout(timeout);
    } on KfError {
      rethrow;
    } catch (e) {
      throw _netError(e);
    }
  }

  Future<HttpClientRequest> _open(
    HttpClient client,
    String method,
    String host,
    int port,
    String pathWithQuery,
    String? receiverFp,
  ) async {
    final uri = Uri.parse('https://${_hostForUri(host)}:$port$pathWithQuery');
    final req = await client.openUrl(method, uri);
    req.persistentConnection = true;
    if (receiverFp != null) {
      req.headers.set(
        kAuthHeader,
        buildAuthHeader(me, method: method, pathWithQuery: pathWithQuery, receiverFingerprint: receiverFp),
      );
    }
    return req;
  }

  Future<Map<String, Object?>> _readJson(HttpClientResponse res) async {
    final bytes = BytesBuilder(copy: false);
    await for (final c in res) {
      bytes.add(c);
      if (bytes.length > kMaxJsonBytes) throw KfError(KfErrorCode.protocol, 'response too large');
    }
    final raw = bytes.takeBytes();
    Map<String, Object?> j;
    try {
      j = raw.isEmpty ? const {} : decodeJsonObject(raw);
    } on KfError {
      j = const {};
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return j;
    final code = j['error'] is String
        ? KfErrorCode.fromWire(j['error'] as String)
        : (res.statusCode == 404 ? KfErrorCode.versionMismatch : KfErrorCode.protocol);
    throw KfError(code, j['message'] as String?, j);
  }

  KfError _netError(Object e) {
    if (e is HandshakeException || e is TlsException) {
      return KfError(KfErrorCode.identityMismatch, 'tls');
    }
    if (e is KfError) return e;
    return KfError(KfErrorCode.unreachable, e.runtimeType.toString());
  }

  String _hostForUri(String host) => host.contains(':') ? '[$host]' : host;
}
