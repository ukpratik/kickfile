@Tags(['bench'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/transfer/sender.dart';

import '../support/nodes.dart';

/// Run with: flutter test test/bench --run-skipped  (KF_BENCH=1)
void main() {
  test('loopback throughput', () async {
    final a = await TestDevice.create('A');
    final b = await TestDevice.create('B');
    final f = await a.makeFile('big.bin', 512 * 1024 * 1024);
    final peer = await a.discover(b);
    final sw = Stopwatch()..start();
    final job = a.node.send(peer.copyWith(port: b.node.port), '127.0.0.1', [await a.source(f, 'big.bin')]);
    await waitFor(() => job.isFinished, timeout: const Duration(minutes: 5));
    sw.stop();
    expect(job.state, SendState.done);
    final mbps = 512 / sw.elapsedMilliseconds * 1000;
    stdout.writeln('THROUGHPUT ${mbps.toStringAsFixed(1)} MB/s (${sw.elapsedMilliseconds} ms)');
    await a.close();
    await b.close();
  }, skip: Platform.environment['KF_BENCH'] == null, timeout: const Timeout(Duration(minutes: 6)));
}
