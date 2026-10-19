// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/identity.dart';
import '../core/log.dart';
import '../core/protocol.dart';
import '../core/qr.dart';
import '../net/client.dart';
import '../net/server.dart';
import '../storage/history.dart';
import '../storage/json_store.dart';
import '../storage/peers.dart';
import '../storage/settings.dart';
import 'file_access.dart';
import 'receiver.dart';
import 'sender.dart';
import 'transfer_service.dart';

/// The whole engine for one device: identity, stores, server, client, sender, receiver.
/// The app wraps it with discovery and platform glue; tests run two of them on loopback.
class KickNode {
  KickNode._({
    required this.identity,
    required this.platform,
    required this.settings,
    required this.peers,
    required this.history,
    required this.files,
    required this.client,
    required this.receiver,
    required this.server,
    required this.transfers,
  });

  final DeviceIdentity identity;
  final DevicePlatform platform;
  final SettingsStore settings;
  final PeerStore peers;
  final HistoryStore history;
  final FileAccess files;
  final KfClient client;
  final ReceiveManager receiver;
  final KfServer server;
  final TransferService transfers;

  String get fingerprint => identity.fingerprint;
  int get port => server.port;

  DeviceInfo get info => DeviceInfo(
    fingerprint: identity.fingerprint,
    name: settings.value.deviceName,
    platform: platform,
    port: server.port == 0 ? kDefaultPort : server.port,
  );

  static Future<KickNode> open({
    required Directory dataDir,
    required FileAccess files,
    required String defaultName,
    required DevicePlatform platform,
    Duration offerTimeout = kOfferTimeout,
    Duration staleAfter = const Duration(seconds: 30),
    Duration autoRetryFor = const Duration(seconds: 30),
    Duration retryEvery = const Duration(seconds: 3),
    Duration stallAfter = const Duration(seconds: 15),
  }) async {
    await dataDir.create(recursive: true);
    final idFile = JsonFile(File(p.join(dataDir.path, 'identity.json')), privateFile: true);
    final idJson = await idFile.read();
    DeviceIdentity identity;
    try {
      identity = idJson == null ? DeviceIdentity.generate() : DeviceIdentity.fromJson(idJson);
    } catch (_) {
      log.warn('node', 'identity unreadable, creating a new one');
      identity = DeviceIdentity.generate();
    }
    if (idJson == null) await idFile.write(identity.toJson());

    final settings = await SettingsStore.load(
      JsonFile(File(p.join(dataDir.path, 'settings.json'))),
      Settings(deviceName: cleanDeviceName(defaultName)),
    );
    final peers = await PeerStore.load(JsonFile(File(p.join(dataDir.path, 'peers.json'))));
    final history = await HistoryStore.load(JsonFile(File(p.join(dataDir.path, 'history.json'))));
    final client = KfClient(identity, stallAfter: stallAfter);

    late final KickNode node;
    final receiver = ReceiveManager(
      files: files,
      peers: peers,
      history: history,
      manifestDir: Directory(p.join(dataDir.path, 'partials')),
      myFingerprint: identity.fingerprint,
      infoOf: () => node.info,
      hiddenOf: () => !settings.value.visible,
      offerTimeout: offerTimeout,
      staleAfter: staleAfter,
    );
    final server = KfServer(identity, receiver);
    final transfers = TransferService(
      client: client,
      files: files,
      history: history,
      me: () => node.info,
      autoRetryFor: autoRetryFor,
      retryEvery: retryEvery,
    );
    node = KickNode._(
      identity: identity,
      platform: platform,
      settings: settings,
      peers: peers,
      history: history,
      files: files,
      client: client,
      receiver: receiver,
      server: server,
      transfers: transfers,
    );
    return node;
  }

  Future<void> start({int port = kDefaultPort, InternetAddress? bindAddress}) async {
    await receiver.start();
    await server.start(port: port, address: bindAddress);
  }

  Future<void> stop() async {
    await server.stop();
    client.close();
  }

  /// Sends to a known device at its last address.
  SendJob send(PeerRecord to, String host, List<SendSource> sources) => transfers.send(
    to: PeerEndpoint(host, to.port, to.fingerprint),
    peerName: to.displayName,
    peerPlatform: to.platform,
    sources: sources,
  );

  /// QR pairing (US-003): the code carries the fingerprint, so no verification code is needed.
  Future<PeerRecord> pairWithCode(PairingCode code) async {
    KfError? last;
    for (final addr in code.addresses) {
      try {
        final ep = PeerEndpoint(addr, code.port, code.fingerprint);
        final peerInfo = await client.info(addr, code.port, expectFingerprint: code.fingerprint, secret: code.secret);
        await client.pair(ep, code.secret, info);
        return await _trustPaired(peerInfo, addr);
      } on KfError catch (e) {
        last = e;
        if (e.code == KfErrorCode.badSecret) rethrow;
      }
    }
    throw last ?? KfError(KfErrorCode.unreachable);
  }

  /// Typed short code `23-482913` (camera declined). The fingerprint is learnt
  /// from the device and checked against its TLS certificate.
  Future<PeerRecord> pairWithShortCode(String host, String secret) async {
    final peerInfo = await client.info(host, kDefaultPort, secret: secret);
    await client.pair(PeerEndpoint(host, peerInfo.port, peerInfo.fingerprint), secret, info);
    return _trustPaired(peerInfo, host);
  }

  Future<PeerRecord> _trustPaired(DeviceInfo peerInfo, String addr) async {
    await peers.seen(peerInfo, addresses: [addr]);
    return peers.update(
      peerInfo.fingerprint,
      (p) => p.copyWith(trusted: true, blocked: false),
    );
  }

  Future<void> dispose() async {
    await stop();
    receiver.dispose();
    transfers.dispose();
  }
}
