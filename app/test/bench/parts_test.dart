@Tags(['bench'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parts', () async {
    final chunk = Uint8List(64 * 1024);
    const total = 256 * 1024 * 1024;
    var sw = Stopwatch()..start();
    final sink = _S();
    final h = sha256.startChunkedConversion(sink);
    for (var i = 0; i < total ~/ chunk.length; i++) { h.add(chunk); }
    h.close();
    stdout.writeln('SHA256 ${(256 / sw.elapsedMilliseconds * 1000).toStringAsFixed(0)} MB/s');

    final dir = await Directory.systemTemp.createTemp();
    final raf = await File('${dir.path}/x').open(mode: FileMode.write);
    sw = Stopwatch()..start();
    for (var i = 0; i < total ~/ chunk.length; i++) { await raf.writeFrom(chunk); }
    await raf.close();
    stdout.writeln('RAF write 64K ${(256 / sw.elapsedMilliseconds * 1000).toStringAsFixed(0)} MB/s');

    sw = Stopwatch()..start();
    var n = 0;
    await for (final c in File('${dir.path}/x').openRead()) { n += c.length; }
    stdout.writeln('read ${(256 / sw.elapsedMilliseconds * 1000).toStringAsFixed(0)} MB/s $n');
    await dir.delete(recursive: true);
  }, skip: Platform.environment['KF_BENCH'] == null);
}
class _S implements Sink<Digest> { @override void add(Digest d) {} @override void close() {} }
