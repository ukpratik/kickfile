// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/auth.dart';
import 'package:kickfile/core/errors.dart';
import 'package:kickfile/core/identity.dart';
import 'package:kickfile/core/sas.dart';

void main() {
  final alice = DeviceIdentity.generate();
  final bob = DeviceIdentity.generate();

  test('identity round-trips through JSON with the same fingerprint', () {
    final again = DeviceIdentity.fromJson(alice.toJson());
    expect(again.fingerprint, alice.fingerprint);
    expect(alice.fingerprint, hasLength(64));
    expect(alice.fingerprint, isNot(bob.fingerprint));
  });

  test('public key is extracted from the certificate and verifies signatures', () {
    final key = publicKeyFromCertDer(alice.certDer);
    expect(verifySignature(key, [1, 2, 3], alice.sign([1, 2, 3])), isTrue);
    expect(verifySignature(key, [1, 2, 4], alice.sign([1, 2, 3])), isFalse);
    expect(verifySignature(publicKeyFromCertDer(bob.certDer), [1, 2, 3], alice.sign([1, 2, 3])), isFalse);
  });

  group('auth header', () {
    String header({String method = 'POST', String path = '/v1/transfers', String? to, DateTime? now}) =>
        buildAuthHeader(alice, method: method, pathWithQuery: path, receiverFingerprint: to ?? bob.fingerprint, now: now);

    test('verifies and identifies the caller', () {
      final v = AuthVerifier(bob.fingerprint);
      final caller = v.verify(header(), method: 'POST', pathWithQuery: '/v1/transfers');
      expect(caller.fingerprint, alice.fingerprint);
    });

    Matcher unauthorized() => throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.unauthorized));

    test('rejects a replay', () {
      final v = AuthVerifier(bob.fingerprint);
      final h = header();
      v.verify(h, method: 'POST', pathWithQuery: '/v1/transfers');
      expect(() => v.verify(h, method: 'POST', pathWithQuery: '/v1/transfers'), unauthorized());
    });

    test('rejects a header meant for another receiver', () {
      final v = AuthVerifier(bob.fingerprint);
      expect(() => v.verify(header(to: alice.fingerprint), method: 'POST', pathWithQuery: '/v1/transfers'), unauthorized());
    });

    test('rejects a different path or method', () {
      final v = AuthVerifier(bob.fingerprint);
      expect(() => v.verify(header(), method: 'POST', pathWithQuery: '/v1/pair'), unauthorized());
      expect(() => v.verify(header(), method: 'PUT', pathWithQuery: '/v1/transfers'), unauthorized());
    });

    test('rejects clock skew beyond 5 minutes', () {
      final v = AuthVerifier(bob.fingerprint);
      final old = DateTime.now().subtract(const Duration(minutes: 6));
      expect(() => v.verify(header(now: old), method: 'POST', pathWithQuery: '/v1/transfers'), unauthorized());
    });

    test('rejects garbage', () {
      final v = AuthVerifier(bob.fingerprint);
      expect(() => v.verify(null, method: 'POST', pathWithQuery: '/'), unauthorized());
      expect(() => v.verify('not-base64!!', method: 'POST', pathWithQuery: '/'), unauthorized());
    });
  });

  test('verification code is symmetric, 6 digits, and formatted', () {
    final a = verificationCode(alice.fingerprint, bob.fingerprint);
    expect(a, verificationCode(bob.fingerprint, alice.fingerprint));
    expect(a, matches(RegExp(r'^\d{6}$')));
    expect(formatCode('482913'), '482 913');
  });
}
