// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart' show ECPublicKey;

import 'errors.dart';
import 'identity.dart';

const kClockSkew = Duration(minutes: 5);

/// Who sent a request, after the signature checked out.
class Caller {
  const Caller(this.fingerprint, this.certDer, [this.host]);
  final String fingerprint;
  final Uint8List certDer;

  /// The address the request came from (set by the server).
  final String? host;
}

/// Builds the `X-KF-Auth` header value for one request (ADR-002, LLD §3.1).
String buildAuthHeader(
  DeviceIdentity me, {
  required String method,
  required String pathWithQuery,
  required String receiverFingerprint,
  DateTime? now,
}) {
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final n = base64Url.encode(List<int>.generate(16, (_) => _rng.nextInt(256)));
  final sig = me.sign(_signedBytes(method, pathWithQuery, receiverFingerprint, t, n));
  final payload = {'c': base64.encode(me.certDer), 't': t, 'n': n, 's': sig};
  return base64Url.encode(utf8.encode(jsonEncode(payload)));
}

/// Verifies headers on the receiving side. Keeps the nonce cache and parsed keys.
class AuthVerifier {
  AuthVerifier(this.myFingerprint, {this.nonceCapacity = 4096});

  final String myFingerprint;
  final int nonceCapacity;
  final _nonces = <String>{};
  final _keys = <String, ECPublicKey>{};

  Caller verify(
    String? header, {
    required String method,
    required String pathWithQuery,
    DateTime? now,
  }) {
    KfError bad(String why) => KfError(KfErrorCode.unauthorized, why);
    if (header == null || header.isEmpty) throw bad('missing');
    final Map<String, Object?> j;
    try {
      j = (jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(header)))) as Map)
          .cast<String, Object?>();
    } catch (_) {
      throw bad('malformed');
    }
    final c = j['c'], t = j['t'], n = j['n'], s = j['s'];
    if (c is! String || t is! int || n is! String || s is! String || n.length > 64) {
      throw bad('fields');
    }
    final at = DateTime.fromMillisecondsSinceEpoch(t);
    final diff = (now ?? DateTime.now()).difference(at).abs();
    if (diff > kClockSkew) throw bad('clock');
    final Uint8List der;
    try {
      der = base64.decode(c);
    } catch (_) {
      throw bad('cert');
    }
    final fp = fingerprintOf(der);
    final key = _keys[fp] ??= publicKeyFromCertDer(der);
    if (!verifySignature(key, _signedBytes(method, pathWithQuery, myFingerprint, t, n), s)) {
      throw bad('signature');
    }
    final nonceKey = '$fp:$n';
    if (_nonces.contains(nonceKey)) throw bad('replay');
    _nonces.add(nonceKey);
    if (_nonces.length > nonceCapacity) _nonces.remove(_nonces.first);
    if (_keys.length > 256) _keys.remove(_keys.keys.first);
    return Caller(fp, der);
  }
}

final _rng = Random.secure();

List<int> _signedBytes(String method, String path, String receiverFp, int t, String n) =>
    utf8.encode('kfv1\n${method.toUpperCase()}\n$path\n$receiverFp\n$t\n$n');
