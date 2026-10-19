// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/log.dart';
import '../core/protocol.dart';
import '../net/client.dart';
import '../net/netinfo.dart';
import '../net/probe.dart';
import '../storage/peers.dart';
import '../transfer/node.dart';

/// A device as the home screen shows it: its stored record plus live reachability.
class LiveDevice {
  LiveDevice(this.fingerprint);
  final String fingerprint;
  String? host;
  int port = kDefaultPort;
  bool online = false;
  bool versionMismatch = false;
  int failures = 0;
  DateTime lastOk = DateTime.fromMillisecondsSinceEpoch(0);

  PeerEndpoint? get endpoint => host == null ? null : PeerEndpoint(host!, port, fingerprint);
}

/// Finds kickFile devices: DNS-SD first, the subnet probe as a fallback, and
/// liveness pings so devices that leave disappear within ~10 s (US-002, ADR-003).
class Discovery extends ChangeNotifier {
  Discovery(this.node);

  final KickNode node;
  final _live = <String, LiveDevice>{};
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  Timer? _liveness;
  Timer? _probeTimer;
  bool _probing = false;
  bool _started = false;
  DateTime _searchStarted = DateTime.now();
  NetworkState network = const NetworkState(addresses: [], vpnActive: false);

  /// "Looking for more" shimmer: the first 30 s after a (re)start.
  bool get searching => DateTime.now().difference(_searchStarted) < const Duration(seconds: 30);

  LiveDevice? live(String fp) => _live[fp];

  /// What the home screen lists: online devices (trusted first), then trusted offline ones.
  List<(PeerRecord, LiveDevice?)> get devices {
    final out = <(PeerRecord, LiveDevice?)>[];
    for (final l in _live.values.where((l) => l.online)) {
      final r = node.peers[l.fingerprint];
      if (r != null && !r.blocked) out.add((r, l));
    }
    for (final r in node.peers.trusted) {
      if (!out.any((e) => e.$1.fingerprint == r.fingerprint)) out.add((r, _live[r.fingerprint]));
    }
    int rank((PeerRecord, LiveDevice?) e) => (e.$2?.online ?? false) ? (e.$1.trusted ? 0 : 1) : 2;
    out.sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : b.$1.lastSeen.compareTo(a.$1.lastSeen);
    });
    return out;
  }

  bool get anyOnline => _live.values.any((l) => l.online);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _searchStarted = DateTime.now();
    network = await readNetwork();
    notifyListeners();
    await _startBroadcast();
    await _startDiscovery();
    _liveness = Timer.periodic(const Duration(seconds: 4), (_) => _checkLiveness());
    // Fallback probe if DNS-SD found nothing in 3 s, then every 30 s while empty.
    Timer(const Duration(seconds: 3), () {
      if (!anyOnline) unawaited(probe());
    });
    _probeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!anyOnline) unawaited(probe());
    });
    unawaited(_tryKnownAddresses());
  }

  Future<void> stop() async {
    _started = false;
    _liveness?.cancel();
    _probeTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await _discovery?.stop();
      await _broadcast?.stop();
    } catch (_) {}
    _discovery = null;
    _broadcast = null;
  }

  /// Pull to refresh / "Search again".
  Future<void> refresh() async {
    _searchStarted = DateTime.now();
    network = await readNetwork();
    notifyListeners();
    try {
      await _discovery?.stop();
    } catch (_) {}
    await _startDiscovery();
    unawaited(probe());
    unawaited(_tryKnownAddresses());
  }

  /// Android: stop announcing while the app isn't on screen (A-08, NFR-010).
  Future<void> pauseBackground() async {
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _broadcast = null;
    _liveness?.cancel();
    _liveness = null;
  }

  Future<void> resumeForeground() async {
    if (!_started) return;
    if (_broadcast == null) await _startBroadcast();
    _liveness ??= Timer.periodic(const Duration(seconds: 4), (_) => _checkLiveness());
    await refresh();
  }

  /// Visibility or name changed: re-announce.
  Future<void> updateBroadcast() async {
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _broadcast = null;
    await _startBroadcast();
  }

  /// A verified request from [fp] reached us: it's online at [host] (BUG-011).
  /// The port stays what we know; liveness pings correct it if needed.
  void markContact(String fp, String? host) {
    final record = node.peers[fp];
    final l = _live.putIfAbsent(fp, () => LiveDevice(fp));
    if (host != null && host != l.host) {
      l
        ..host = host
        ..port = record?.port ?? kDefaultPort;
    }
    l
      ..failures = 0
      ..lastOk = DateTime.now();
    if (!l.online) {
      l.online = true;
      notifyListeners();
    }
  }

  /// A device we just paired with or reached directly.
  void addReachable(DeviceInfo info, String host) {
    final l = _live.putIfAbsent(info.fingerprint, () => LiveDevice(info.fingerprint))
      ..host = host
      ..port = info.port
      ..online = true
      ..failures = 0
      ..lastOk = DateTime.now();
    l.versionMismatch = false;
    notifyListeners();
  }

  Future<void> _startBroadcast() async {
    if (!node.settings.value.visible || node.port == 0) return;
    try {
      final b = BonsoirBroadcast(
        printLogs: false,
        service: BonsoirService(
          name: node.settings.value.deviceName,
          type: kServiceType,
          port: node.port,
          attributes: {'v': '$kProtocolVersion', 'fp': node.fingerprint, 'p': node.platform.name},
        ),
      );
      await b.initialize();
      await b.start();
      _broadcast = b;
    } catch (e) {
      log.warn('disc', 'broadcast failed: ${e.runtimeType}');
    }
  }

  Future<void> _startDiscovery() async {
    try {
      final d = BonsoirDiscovery(printLogs: false, type: kServiceType);
      await d.initialize();
      await _sub?.cancel();
      _sub = d.eventStream?.listen(_onEvent);
      await d.start();
      _discovery = d;
    } catch (e) {
      log.warn('disc', 'discovery failed: ${e.runtimeType}');
    }
  }

  void _onEvent(BonsoirDiscoveryEvent e) {
    switch (e) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        if (service.attributes['fp'] == node.fingerprint) return;
        try {
          _discovery?.serviceResolver.resolveService(service);
        } catch (_) {}
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final service):
        unawaited(_onResolved(service));
      case BonsoirDiscoveryServiceLostEvent(:final service):
        final fp = service.attributes['fp'];
        if (fp != null) unawaited(_ping(_live[fp]));
      default:
        break;
    }
  }

  Future<void> _onResolved(BonsoirService s) async {
    final fp = s.attributes['fp'];
    if (fp == null || fp == node.fingerprint || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) return;
    final hosts = s.hostAddresses.where((a) => !a.contains(':')).toList();
    if (s.attributes['v'] != null && s.attributes['v'] != '$kProtocolVersion') {
      final l = _live.putIfAbsent(fp, () => LiveDevice(fp))..versionMismatch = true;
      if (hosts.isNotEmpty) l.host = hosts.first;
      notifyListeners();
      return;
    }
    for (final h in hosts) {
      if (await _verify(fp, h, s.port)) return;
    }
  }

  /// Confirms a device really is [fp] at [host] (pinned TLS) and marks it online.
  Future<bool> _verify(String fp, String host, int port) async {
    try {
      final info = await node.client.info(host, port, expectFingerprint: fp);
      await _remember(info, host);
      return true;
    } on KfError catch (e) {
      if (e.code == KfErrorCode.versionMismatch) {
        _live.putIfAbsent(fp, () => LiveDevice(fp))
          ..versionMismatch = true
          ..host = host;
        notifyListeners();
      }
      return false;
    }
  }

  Future<void> _remember(DeviceInfo info, String host) async {
    if (info.fingerprint == node.fingerprint) return;
    final old = node.peers[info.fingerprint];
    final changed = old == null ||
        old.name != info.name ||
        old.port != info.port ||
        old.addresses.firstOrNull != host ||
        DateTime.now().millisecondsSinceEpoch - old.lastSeen > const Duration(hours: 1).inMilliseconds;
    if (changed) await node.peers.seen(info, addresses: [host]);
    addReachable(info, host);
  }

  Future<void> probe() async {
    if (_probing) return;
    _probing = true;
    try {
      network = await readNetwork();
      final ips = network.addresses.map((a) => a.ip).toList();
      await for (final hit in probeSubnets(node.client, ips)) {
        if (hit.info.fingerprint == node.fingerprint) continue;
        await _remember(hit.info, hit.host);
      }
    } catch (e) {
      log.warn('disc', 'probe failed: ${e.runtimeType}');
    } finally {
      _probing = false;
    }
  }

  /// Trusted devices can be Hidden or on networks without multicast: try where we last saw them.
  Future<void> _tryKnownAddresses() async {
    for (final p in node.peers.trusted.toList()) {
      if (_live[p.fingerprint]?.online ?? false) continue;
      for (final a in p.addresses) {
        if (await _verify(p.fingerprint, a, p.port)) break;
      }
    }
  }

  var _tick = 0;
  Future<void> _checkLiveness() async {
    _tick++;
    final nw = await readNetwork();
    if (nw.primaryIp != network.primaryIp || nw.vpnActive != network.vpnActive) {
      network = nw;
      notifyListeners();
      if (nw.addresses.isNotEmpty) unawaited(refresh());
    }
    // Every device we have an address for, online or not: they come back by themselves (BUG-003).
    await Future.wait([for (final l in _live.values.where((l) => l.host != null)) _ping(l)]);
    if (_tick % 3 == 0) unawaited(_tryKnownAddresses());
  }

  Future<void> _ping(LiveDevice? l) async {
    final ep = l?.endpoint;
    if (l == null || ep == null) return;
    try {
      await node.client.info(ep.host, ep.port, expectFingerprint: ep.fingerprint, timeout: const Duration(seconds: 2));
      l
        ..failures = 0
        ..lastOk = DateTime.now();
      if (!l.online) {
        l.online = true;
        notifyListeners();
      }
    } on KfError {
      l.failures++;
      if (l.online && l.failures >= 2) {
        l.online = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
