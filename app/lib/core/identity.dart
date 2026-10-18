import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/asn1.dart' as asn1;

import 'errors.dart';

const _sigAlgorithm = 'SHA-256/ECDSA';

/// This device's key pair and self-signed certificate (ADR-002).
/// The fingerprint, hex SHA-256 of the certificate DER, is the device id.
class DeviceIdentity {
  DeviceIdentity._(this.keyPem, this.certPem)
    : _privateKey = CryptoUtils.ecPrivateKeyFromPem(keyPem),
      certDer = CryptoUtils.getBytesFromPEMString(certPem) {
    fingerprint = fingerprintOf(certDer);
  }

  factory DeviceIdentity.generate() {
    final pair = CryptoUtils.generateEcKeyPair();
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem({'CN': 'kickfile'}, priv, pub);
    final cert = X509Utils.generateSelfSignedCertificate(priv, csr, 365 * 20);
    return DeviceIdentity._(CryptoUtils.encodeEcPrivateKeyToPem(priv), cert);
  }

  factory DeviceIdentity.fromJson(Map<String, Object?> j) {
    final key = j['keyPem'];
    final cert = j['certPem'];
    if (key is! String || cert is! String) throw KfError(KfErrorCode.protocol, 'identity');
    return DeviceIdentity._(key, cert);
  }

  final String keyPem;
  final String certPem;
  final Uint8List certDer;
  late final String fingerprint;
  final ECPrivateKey _privateKey;

  Map<String, Object?> toJson() => {'keyPem': keyPem, 'certPem': certPem};

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// Base64 DER ECDSA signature over [data].
  String sign(List<int> data) => CryptoUtils.ecSignatureToBase64(
    CryptoUtils.ecSign(_privateKey, Uint8List.fromList(data), algorithmName: _sigAlgorithm),
  );
}

String fingerprintOf(List<int> certDer) => sha256.convert(certDer).toString();

/// Extracts the EC public key from a certificate's subjectPublicKeyInfo.
ECPublicKey publicKeyFromCertDer(Uint8List der) {
  try {
    final cert = asn1.ASN1Parser(der).nextObject() as asn1.ASN1Sequence;
    final tbs = cert.elements![0] as asn1.ASN1Sequence;
    final els = tbs.elements!;
    // An explicit [0] version tag shifts every field by one.
    final hasVersion = els.first.tag == 0xA0;
    final spki = els[hasVersion ? 6 : 5];
    return CryptoUtils.ecPublicKeyFromDerBytes(spki.encodedBytes!);
  } catch (_) {
    throw KfError(KfErrorCode.unauthorized, 'certificate');
  }
}

bool verifySignature(ECPublicKey key, List<int> data, String signatureB64) {
  try {
    return CryptoUtils.ecVerifyBase64(
      key,
      Uint8List.fromList(data),
      signatureB64,
      algorithm: _sigAlgorithm,
    );
  } catch (_) {
    return false;
  }
}
