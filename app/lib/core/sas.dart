import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The 6-digit verification code both devices show on first contact (US-008).
/// Order-independent, so both sides compute the same code.
String verificationCode(String fingerprintA, String fingerprintB) {
  final pair = [fingerprintA, fingerprintB]..sort();
  final d = sha256.convert(utf8.encode('kickfile-sas-v1\n${pair[0]}\n${pair[1]}')).bytes;
  final n = ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) % 1000000;
  return n.toString().padLeft(6, '0');
}

/// `482913` → `482 913`.
String formatCode(String code) => '${code.substring(0, 3)} ${code.substring(3)}';
