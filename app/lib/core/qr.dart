// SPDX-License-Identifier: GPL-3.0-or-later
import 'errors.dart';
import 'protocol.dart';

/// What a kickFile QR code carries (US-003, HLD §5):
/// `kickfile://c?v=1&a=192.168.1.23,10.0.0.4&p=47420&fp=<64 hex>&s=482913&n=Arjun's MacBook`
class PairingCode {
  const PairingCode({
    required this.addresses,
    required this.port,
    required this.fingerprint,
    required this.secret,
    required this.name,
  });

  final List<String> addresses;
  final int port;
  final String fingerprint;
  final String secret;
  final String name;

  String toUri() => Uri(
    scheme: 'kickfile',
    host: 'c',
    queryParameters: {
      'v': '$kProtocolVersion',
      'a': addresses.join(','),
      'p': '$port',
      'fp': fingerprint,
      's': secret,
      'n': name,
    },
  ).toString();

  /// The typed fallback: last part of the IPv4 address + the secret, e.g. `23-482913`.
  /// Null when there's no IPv4 address or the port isn't the default.
  String? get shortCode {
    if (port != kDefaultPort || addresses.isEmpty) return null;
    final last = addresses.first.split('.').last;
    return '$last-$secret';
  }

  static PairingCode parse(String raw) {
    KfError bad() => KfError(KfErrorCode.badSecret, 'not a kickFile code');
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'kickfile') throw bad();
    final q = uri.queryParameters;
    if (q['v'] != '$kProtocolVersion') throw KfError(KfErrorCode.versionMismatch);
    final fp = q['fp'] ?? '';
    final secret = q['s'] ?? '';
    final port = int.tryParse(q['p'] ?? '');
    final addrs = (q['a'] ?? '').split(',').where(_isIpv4).toList();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(fp) ||
        !RegExp(r'^\d{6}$').hasMatch(secret) ||
        port == null ||
        port <= 0 ||
        port > 65535 ||
        addrs.isEmpty) {
      throw bad();
    }
    return PairingCode(
      addresses: addrs,
      port: port,
      fingerprint: fp,
      secret: secret,
      name: cleanDeviceName(q['n'] ?? ''),
    );
  }
}

/// A typed short code resolved against our own subnet: `23-482913` + `192.168.1.40` → host `192.168.1.23`.
({String host, String secret})? parseShortCode(String raw, String myIpv4) {
  final m = RegExp(r'^\s*(\d{1,3})\s*[- ]\s*(\d{3})\s*?(\d{3})\s*$').firstMatch(raw);
  if (m == null || !_isIpv4(myIpv4)) return null;
  final last = int.parse(m[1]!);
  if (last < 1 || last > 254) return null;
  final prefix = myIpv4.substring(0, myIpv4.lastIndexOf('.'));
  return (host: '$prefix.$last', secret: '${m[2]}${m[3]}');
}

bool _isIpv4(String s) {
  final parts = s.split('.');
  return parts.length == 4 &&
      parts.every((p) {
        final n = int.tryParse(p);
        return n != null && n >= 0 && n <= 255 && p == '$n';
      });
}
