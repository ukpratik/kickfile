import 'package:flutter/foundation.dart';

import '../core/protocol.dart';
import 'json_store.dart';

/// A device we've seen or paired with, keyed by certificate fingerprint.
@immutable
class PeerRecord {
  const PeerRecord({
    required this.fingerprint,
    required this.name,
    required this.platform,
    this.alias,
    this.trusted = false,
    this.autoAccept = false,
    this.blocked = false,
    this.lastSeen = 0,
    this.addresses = const [],
    this.port = kDefaultPort,
  });

  final String fingerprint;

  /// The name the device announces.
  final String name;

  /// A local rename (US-010 "Rename").
  final String? alias;
  final DevicePlatform platform;
  final bool trusted;
  final bool autoAccept;
  final bool blocked;
  final int lastSeen;
  final List<String> addresses;
  final int port;

  String get displayName => alias ?? name;

  PeerRecord copyWith({
    String? name,
    String? alias,
    bool clearAlias = false,
    DevicePlatform? platform,
    bool? trusted,
    bool? autoAccept,
    bool? blocked,
    int? lastSeen,
    List<String>? addresses,
    int? port,
  }) => PeerRecord(
    fingerprint: fingerprint,
    name: name ?? this.name,
    alias: clearAlias ? null : (alias ?? this.alias),
    platform: platform ?? this.platform,
    trusted: trusted ?? this.trusted,
    autoAccept: autoAccept ?? this.autoAccept,
    blocked: blocked ?? this.blocked,
    lastSeen: lastSeen ?? this.lastSeen,
    addresses: addresses ?? this.addresses,
    port: port ?? this.port,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'alias': alias,
    'platform': platform.name,
    'trusted': trusted,
    'autoAccept': autoAccept,
    'blocked': blocked,
    'lastSeen': lastSeen,
    'addresses': addresses,
    'port': port,
  };

  static PeerRecord? fromJson(String fp, Object? raw) {
    if (raw is! Map || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) return null;
    final j = raw.cast<String, Object?>();
    return PeerRecord(
      fingerprint: fp,
      name: j['name'] is String ? j['name']! as String : 'Device',
      alias: j['alias'] is String ? j['alias'] as String : null,
      platform: DevicePlatform.parse(j['platform']),
      trusted: j['trusted'] == true,
      autoAccept: j['autoAccept'] == true,
      blocked: j['blocked'] == true,
      lastSeen: j['lastSeen'] is int ? j['lastSeen']! as int : 0,
      addresses: j['addresses'] is List ? (j['addresses']! as List).whereType<String>().toList() : const [],
      port: j['port'] is int ? j['port']! as int : kDefaultPort,
    );
  }
}

class PeerStore extends ChangeNotifier {
  PeerStore(this._file, this._peers);

  final JsonFile _file;
  final Map<String, PeerRecord> _peers;

  static Future<PeerStore> load(JsonFile file) async {
    final j = await file.read();
    final peers = <String, PeerRecord>{};
    final raw = j?['peers'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final p = PeerRecord.fromJson(k as String, v);
        if (p != null) peers[p.fingerprint] = p;
      });
    }
    return PeerStore(file, peers);
  }

  PeerRecord? operator [](String fp) => _peers[fp];
  Iterable<PeerRecord> get all => _peers.values;
  Iterable<PeerRecord> get trusted => _peers.values.where((p) => p.trusted && !p.blocked);
  Iterable<PeerRecord> get blocked => _peers.values.where((p) => p.blocked);

  bool isTrusted(String fp) => _peers[fp]?.trusted == true && _peers[fp]?.blocked != true;
  bool isBlocked(String fp) => _peers[fp]?.blocked == true;

  /// Records that a device was seen (discovery, an offer, pairing). Keeps flags.
  Future<PeerRecord> seen(DeviceInfo info, {List<String>? addresses}) {
    final old = _peers[info.fingerprint];
    final p = (old ??
            PeerRecord(fingerprint: info.fingerprint, name: info.name, platform: info.platform))
        .copyWith(
          name: info.name,
          platform: info.platform,
          lastSeen: DateTime.now().millisecondsSinceEpoch,
          addresses: addresses ?? old?.addresses,
          port: info.port,
        );
    return _put(p);
  }

  Future<PeerRecord> update(String fp, PeerRecord Function(PeerRecord) change) {
    final old = _peers[fp];
    if (old == null) return Future.error(StateError('unknown peer'));
    return _put(change(old));
  }

  /// Forget = remove the stored key and flags (US-010).
  Future<void> forget(String fp) async {
    _peers.remove(fp);
    notifyListeners();
    await _save();
  }

  /// A trusted device with the same name and platform but a different key (US-008).
  PeerRecord? identityChangedFor(String fp, String name, DevicePlatform platform) {
    if (_peers[fp] != null) return null;
    for (final p in _peers.values) {
      if (p.trusted && p.name == name && p.platform == platform && p.fingerprint != fp) return p;
    }
    return null;
  }

  Future<PeerRecord> _put(PeerRecord p) async {
    _peers[p.fingerprint] = p;
    notifyListeners();
    await _save();
    return p;
  }

  Future<void> _save() => _file.write({
    'peers': {for (final p in _peers.values) p.fingerprint: p.toJson()},
  });
}
