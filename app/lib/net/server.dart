import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/auth.dart';
import '../core/errors.dart';
import '../core/identity.dart';
import '../core/log.dart';
import '../core/protocol.dart';

/// What the server does with each request. Implemented by the receiver.
abstract class ServerPolicy {
  DeviceInfo info();

  /// Hidden mode: `GET /v1/info` only answers trusted callers or a valid pairing secret.
  bool get hidden;
  bool isTrusted(String fingerprint);
  bool checkPairingSecret(String secret);

  Future<void> pair(Caller caller, String secret, DeviceInfo callerInfo);
  Future<OfferAnswer> offer(Caller caller, TransferOffer offer);
  Future<int> upload(Caller caller, String transferId, String itemId, int offset, int length, Stream<List<int>> body);
  Future<void> done(Caller caller, String transferId, String itemId, String sha256);
  Future<void> finish(Caller caller, String transferId);
  Future<void> cancel(Caller caller, String transferId);
}

class OfferAnswer {
  const OfferAnswer({required this.offsets, this.done = const {}});

  /// Bytes the receiver already has, per file item.
  final Map<String, int> offsets;

  /// Items already complete (resume).
  final Set<String> done;

  Map<String, Object?> toJson() => {'accepted': true, 'offsets': offsets, 'done': done.toList()};

  factory OfferAnswer.fromJson(Map<String, Object?> j) => OfferAnswer(
    offsets: {
      for (final e in ((j['offsets'] as Map?) ?? const {}).entries)
        if (e.value is int) e.key as String: e.value as int,
    },
    done: {...((j['done'] as List?) ?? const []).whereType<String>()},
  );
}

/// HTTPS server for protocol v1 (LLD §3.1).
class KfServer {
  KfServer(this.identity, this.policy) : _auth = AuthVerifier(identity.fingerprint);

  final DeviceIdentity identity;
  final ServerPolicy policy;
  final AuthVerifier _auth;
  HttpServer? _server;

  int get port => _server?.port ?? 0;
  bool get running => _server != null;

  /// Binds [port] on all IPv4 interfaces, or an OS-assigned port if it's taken.
  Future<void> start({int port = kDefaultPort, InternetAddress? address}) async {
    if (_server != null) return;
    final addr = address ?? InternetAddress.anyIPv4;
    final ctx = identity.serverContext();
    HttpServer s;
    try {
      s = await HttpServer.bindSecure(addr, port, ctx);
    } on SocketException {
      s = await HttpServer.bindSecure(addr, 0, ctx);
      log.warn('server', 'port $port busy, using ${s.port}');
    }
    s.idleTimeout = const Duration(seconds: 30);
    _server = s;
    s.listen(_handle, onError: (Object e) => log.warn('server', 'listen error ${e.runtimeType}'));
    log.info('server', 'listening on ${s.port}');
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final segs = req.uri.pathSegments;
    final pathWithQuery = req.uri.hasQuery ? '${req.uri.path}?${req.uri.query}' : req.uri.path;
    try {
      if (segs.isEmpty || segs.first != 'v1') throw KfError(KfErrorCode.notFound);

      if (req.method == 'GET' && segs.length == 2 && segs[1] == 'info') {
        Caller? caller;
        final h = req.headers.value(kAuthHeader);
        if (h != null) {
          try {
            caller = _auth.verify(h, method: 'GET', pathWithQuery: pathWithQuery);
          } on KfError {
            caller = null;
          }
        }
        final secret = req.uri.queryParameters['s'];
        final allowed = !policy.hidden ||
            (caller != null && policy.isTrusted(caller.fingerprint)) ||
            (secret != null && policy.checkPairingSecret(secret));
        if (!allowed) throw KfError(KfErrorCode.notFound);
        return await _json(res, 200, policy.info().toJson());
      }

      final caller = _auth.verify(
        req.headers.value(kAuthHeader),
        method: req.method,
        pathWithQuery: pathWithQuery,
      );

      if (req.method == 'POST' && segs.length == 2 && segs[1] == 'pair') {
        final body = await _readJson(req);
        final secret = body['secret'];
        if (secret is! String) throw KfError(KfErrorCode.badSecret);
        final info = DeviceInfo(
          fingerprint: caller.fingerprint,
          name: cleanDeviceName(body['name'] as String? ?? ''),
          platform: DevicePlatform.parse(body['platform']),
          port: body['port'] is int ? body['port']! as int : kDefaultPort,
        );
        await policy.pair(caller, secret, info);
        return await _json(res, 200, policy.info().toJson());
      }

      if (segs.length >= 2 && segs[1] == 'transfers') {
        if (req.method == 'POST' && segs.length == 2) {
          final offer = TransferOffer.fromJson(await _readJson(req));
          final answer = await policy.offer(caller, offer);
          return await _json(res, 200, answer.toJson());
        }
        if (segs.length < 3) throw KfError(KfErrorCode.notFound);
        final tid = segs[2];
        if (req.method == 'POST' && segs.length == 4 && segs[3] == 'finish') {
          await policy.finish(caller, tid);
          return await _json(res, 200, const {});
        }
        if (req.method == 'POST' && segs.length == 4 && segs[3] == 'cancel') {
          await policy.cancel(caller, tid);
          return await _json(res, 200, const {});
        }
        if (segs.length >= 5 && segs[3] == 'items') {
          final iid = segs[4];
          if (req.method == 'PUT' && segs.length == 5) {
            final offset = int.tryParse(req.uri.queryParameters['offset'] ?? '');
            final length = req.contentLength;
            if (offset == null || offset < 0 || length < 0) {
              throw KfError(KfErrorCode.invalidOffer, 'offset/length');
            }
            final received = await policy.upload(caller, tid, iid, offset, length, req);
            return await _json(res, 200, {'received': received});
          }
          if (req.method == 'POST' && segs.length == 6 && segs[5] == 'done') {
            final body = await _readJson(req);
            final sha = body['sha256'];
            if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
              throw KfError(KfErrorCode.invalidOffer, 'sha256');
            }
            await policy.done(caller, tid, iid, sha);
            return await _json(res, 200, const {});
          }
        }
      }
      throw KfError(KfErrorCode.notFound);
    } on KfError catch (e) {
      final status = e.code.httpStatus == 0 ? 500 : e.code.httpStatus;
      await _json(res, status, {'error': e.code.wire, 'message': e.detail, ...?e.data});
    } catch (e) {
      log.error('server', 'unhandled ${e.runtimeType}');
      await _json(res, 500, {'error': KfErrorCode.protocol.wire});
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest req) async {
    final declared = req.contentLength;
    if (declared > kMaxJsonBytes) throw KfError(KfErrorCode.invalidOffer, 'body too large');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > kMaxJsonBytes) throw KfError(KfErrorCode.invalidOffer, 'body too large');
    }
    return decodeJsonObject(bytes.takeBytes());
  }

  Future<void> _json(HttpResponse res, int status, Map<String, Object?> body) async {
    try {
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(body));
      await res.close();
    } catch (_) {
      // Client went away.
    }
  }
}
