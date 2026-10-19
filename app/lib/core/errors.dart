// SPDX-License-Identifier: GPL-3.0-or-later
/// Every failure the engine reports. The UI maps codes to the design copy.
enum KfErrorCode {
  declined(403),
  timeout(408),
  busy(409),
  offsetMismatch(409),
  invalidOffer(422),
  hashMismatch(422),
  rateLimited(429),
  noSpace(507),
  unknownTransfer(404),
  notFound(404),
  cancelled(410),
  badSecret(403),
  unauthorized(401),
  versionMismatch(426),
  unreachable(0),
  identityMismatch(0),
  sourceChanged(0),
  sourceMissing(0),
  io(500),
  protocol(500);

  const KfErrorCode(this.httpStatus);

  /// Status the server answers with; 0 means the code never travels on the wire.
  final int httpStatus;

  /// Wire name, e.g. `offset_mismatch`.
  String get wire => name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

  static KfErrorCode fromWire(String? wire) {
    for (final c in values) {
      if (c.wire == wire) return c;
    }
    return KfErrorCode.protocol;
  }
}

class KfError implements Exception {
  KfError(this.code, [this.detail, this.data]);

  final KfErrorCode code;
  final String? detail;

  /// Extra fields from the wire, e.g. `{received: 1024}` for offset_mismatch.
  final Map<String, Object?>? data;

  @override
  String toString() => 'KfError(${code.wire}${detail == null ? '' : ': $detail'})';
}
