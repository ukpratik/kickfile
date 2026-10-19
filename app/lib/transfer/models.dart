// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Smoothed speed over ~3 s (US-006) and time left.
class SpeedMeter {
  SpeedMeter({this.window = const Duration(seconds: 3)});

  final Duration window;
  final _samples = <(int, int)>[]; // (ms, cumulative bytes)

  void reset() => _samples.clear();

  /// Cheap to call per chunk: keeps at most one sample per 100 ms.
  void sample(int cumulativeBytes, [DateTime? now]) {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (_samples.isNotEmpty && t - _samples.last.$1 < 100) return;
    _samples.add((t, cumulativeBytes));
    while (_samples.length > 2 && t - _samples.first.$1 > window.inMilliseconds) {
      _samples.removeAt(0);
    }
  }

  /// Bytes per second; 0 until there are two samples, and 0 once nothing has moved for 2 s.
  double get bytesPerSecond {
    if (_samples.length < 2) return 0;
    if (DateTime.now().millisecondsSinceEpoch - _samples.last.$1 > 2000) return 0;
    final dt = _samples.last.$1 - _samples.first.$1;
    if (dt <= 0) return 0;
    return (_samples.last.$2 - _samples.first.$2) * 1000 / dt;
  }

  Duration? eta(int remaining) {
    final bps = bytesPerSecond;
    if (bps <= 0) return null;
    return Duration(milliseconds: (remaining / bps * 1000).round());
  }
}

/// Time actually spent moving data: start/stop around pauses (BUG-001).
class ActiveClock {
  Duration _total = Duration.zero;
  DateTime? _since;

  void start() => _since ??= DateTime.now();

  void stop() {
    final s = _since;
    if (s == null) return;
    _total += DateTime.now().difference(s);
    _since = null;
  }

  Duration get elapsed => _total + (_since == null ? Duration.zero : DateTime.now().difference(_since!));
}

/// Captures the digest from a chunked SHA-256 conversion.
class DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Incremental SHA-256 that can be finished once.
class Hasher {
  factory Hasher() {
    final sink = DigestSink();
    return Hasher._(sink, sha256.startChunkedConversion(sink));
  }
  Hasher._(this._sink, this._input);

  final DigestSink _sink;
  final ByteConversionSink _input;
  int bytes = 0;

  void add(List<int> chunk) {
    _input.add(chunk);
    bytes += chunk.length;
  }

  String finish() {
    _input.close();
    return _sink.value.toString();
  }

  static Future<Hasher> ofStream(Stream<List<int>> s) async {
    final h = Hasher();
    await for (final c in s) {
      h.add(c);
    }
    return h;
  }
}
