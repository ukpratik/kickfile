import 'dart:async';

import '../core/errors.dart';
import '../core/protocol.dart';
import 'client.dart';

class ProbeHit {
  const ProbeHit(this.host, this.info);
  final String host;
  final DeviceInfo info;
}

/// Asks every host in our /24 subnets for `/v1/info` on the default port (ADR-003).
/// Used when DNS-SD finds nothing, e.g. on networks that block multicast.
Stream<ProbeHit> probeSubnets(
  KfClient client,
  List<String> myIps, {
  int port = kDefaultPort,
  int parallel = 64,
  Duration timeout = const Duration(milliseconds: 600),
}) async* {
  final hosts = <String>[];
  for (final ip in myIps) {
    final parts = ip.split('.');
    if (parts.length != 4) continue;
    final prefix = parts.take(3).join('.');
    for (var i = 1; i < 255; i++) {
      final h = '$prefix.$i';
      if (h != ip && !hosts.contains(h)) hosts.add(h);
    }
  }
  final out = StreamController<ProbeHit>();
  var next = 0;
  var running = 0;
  void pump() {
    while (running < parallel && next < hosts.length) {
      final host = hosts[next++];
      running++;
      client
          .info(host, port, timeout: timeout)
          .then((info) => out.add(ProbeHit(host, info)), onError: (Object e) {
            if (e is! KfError) return;
          })
          .whenComplete(() {
            running--;
            if (next >= hosts.length && running == 0) {
              out.close();
            } else {
              pump();
            }
          });
    }
    if (hosts.isEmpty) out.close();
  }

  pump();
  yield* out.stream;
}
