// SPDX-License-Identifier: GPL-3.0-or-later
@Tags(['bench'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/identity.dart';

Future<void> run(bool tls, int chunkSize) async {
  final id = DeviceIdentity.generate();
  final server = tls
      ? await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, id.serverContext())
      : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var chunks = 0;
  var bytes = 0;
  server.listen((req) async {
    await for (final c in req) { chunks++; bytes += c.length; }
    req.response.close();
  });
  final client = HttpClient()..badCertificateCallback = (c, h, p) => true;
  const total = 256 * 1024 * 1024;
  final data = Uint8List(chunkSize);
  Stream<List<int>> gen() async* { for (var i = 0; i < total ~/ chunkSize; i++) { yield data; } }
  final sw = Stopwatch()..start();
  final req = await client.putUrl(Uri.parse('${tls ? 'https' : 'http'}://127.0.0.1:${server.port}/'));
  req.contentLength = total;
  await req.addStream(gen());
  await (await req.close()).drain<void>();
  stdout.writeln('${tls ? 'TLS ' : 'HTTP'} chunk=$chunkSize ${(256 / sw.elapsedMilliseconds * 1000).toStringAsFixed(0)} MB/s, server chunks avg ${bytes ~/ chunks} B');
  client.close(force: true);
  await server.close(force: true);
}

void main() {
  test('http vs tls', () async {
    await run(false, 65536);
    await run(true, 65536);
    await run(true, 1 << 20);
  }, skip: Platform.environment['KF_BENCH'] == null, timeout: const Timeout(Duration(minutes: 5)));
}
