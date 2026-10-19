// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'errors.dart';
import 'names.dart';

const kProtocolVersion = 1;
const kDefaultPort = 47420;
const kServiceType = '_kickfile._tcp';
const kAuthHeader = 'x-kf-auth';

const kMaxItems = 10000;
const kMaxTextChars = 100000;
const kMaxJsonBytes = 4 * 1024 * 1024;
const kMaxNameChars = 64;
const kMaxFileSize = 1 << 50; // 1 PiB, far above anything real but safe in a double

const kOfferTimeout = Duration(seconds: 60);
const kRateLimit = Duration(seconds: 5);
const kPairingSecretTtl = Duration(minutes: 10);
const kPairingSecretMaxMisses = 10;
const kPartialTtl = Duration(hours: 24);

enum DevicePlatform {
  android,
  ios,
  macos,
  windows,
  linux,
  unknown;

  static DevicePlatform parse(Object? v) =>
      values.firstWhere((p) => p.name == v, orElse: () => DevicePlatform.unknown);

  String get label => switch (this) {
    android => 'Android',
    ios => 'iPhone',
    macos => 'Mac',
    windows => 'Windows',
    linux => 'Linux',
    unknown => 'Device',
  };

  bool get isMobile => this == android || this == ios;
}

class DeviceInfo {
  const DeviceInfo({
    required this.fingerprint,
    required this.name,
    required this.platform,
    required this.port,
    this.version = kProtocolVersion,
  });

  final int version;
  final String fingerprint;
  final String name;
  final DevicePlatform platform;
  final int port;

  Map<String, Object?> toJson() => {
    'v': version,
    'fp': fingerprint,
    'name': name,
    'platform': platform.name,
    'port': port,
  };

  factory DeviceInfo.fromJson(Map<String, Object?> j) => DeviceInfo(
    version: _int(j['v']),
    fingerprint: _str(j['fp'], max: 64),
    name: cleanDeviceName(_str(j['name'], max: 256)),
    platform: DevicePlatform.parse(j['platform']),
    port: _int(j['port']),
  );
}

enum ItemKind { file, dir, text }

class OfferItem {
  const OfferItem({
    required this.id,
    required this.kind,
    required this.path,
    required this.size,
    this.mtime = 0,
    this.text,
  });

  final String id;
  final ItemKind kind;

  /// Relative path with `/` separators, e.g. `Trip/IMG_1.HEIC`. For text items, a label.
  final String path;
  final int size;

  /// Milliseconds since epoch, 0 if unknown.
  final int mtime;
  final String? text;

  String get name => path.split('/').last;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'path': path,
    'size': size,
    'mtime': mtime,
    if (text != null) 'text': text,
  };

  factory OfferItem.fromJson(Map<String, Object?> j) => OfferItem(
    id: _str(j['id'], max: 32),
    kind: ItemKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => throw KfError(KfErrorCode.invalidOffer, 'kind'),
    ),
    path: _str(j['path'], max: 4096),
    size: _int(j['size']),
    mtime: j['mtime'] == null ? 0 : _int(j['mtime']),
    text: j['text'] == null ? null : _str(j['text'], max: kMaxTextChars),
  );
}

class TransferOffer {
  const TransferOffer({
    required this.id,
    required this.senderName,
    required this.senderPlatform,
    required this.items,
  });

  final String id;
  final String senderName;
  final DevicePlatform senderPlatform;
  final List<OfferItem> items;

  int get totalBytes => items.where((i) => i.kind == ItemKind.file).fold(0, (a, i) => a + i.size);
  int get fileCount => items.where((i) => i.kind == ItemKind.file).length;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': senderName,
    'platform': senderPlatform.name,
    'items': [for (final i in items) i.toJson()],
  };

  factory TransferOffer.fromJson(Map<String, Object?> j) {
    final raw = j['items'];
    if (raw is! List) throw KfError(KfErrorCode.invalidOffer, 'items');
    final offer = TransferOffer(
      id: _str(j['id'], max: 64),
      senderName: cleanDeviceName(_str(j['name'], max: 256)),
      senderPlatform: DevicePlatform.parse(j['platform']),
      items: [for (final i in raw) OfferItem.fromJson(_map(i))],
    );
    offer.validate();
    return offer;
  }

  /// Throws [KfErrorCode.invalidOffer] if anything is off. Called on both sides.
  void validate() {
    KfError bad(String why) => KfError(KfErrorCode.invalidOffer, why);
    if (!RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) throw bad('id');
    if (items.isEmpty || items.length > kMaxItems) throw bad('item count');
    final ids = <String>{};
    final paths = <String>{};
    for (final i in items) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(i.id) || !ids.add(i.id)) throw bad('item id');
      if (i.size < 0 || i.size > kMaxFileSize) throw bad('size');
      switch (i.kind) {
        case ItemKind.file:
        case ItemKind.dir:
          validateRelPath(i.path);
          if (i.kind == ItemKind.dir && i.size != 0) throw bad('dir size');
          if (i.text != null) throw bad('text on a file');
          if (!paths.add(i.path)) throw bad('duplicate path');
        case ItemKind.text:
          final t = i.text;
          if (t == null || t.isEmpty || t.length > kMaxTextChars) throw bad('text');
      }
    }
  }
}

/// Device names come from other devices: strip control characters and cap the length.
String cleanDeviceName(String raw) {
  final s = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  if (s.isEmpty) return 'Unnamed device';
  return s.length > kMaxNameChars ? s.substring(0, kMaxNameChars) : s;
}

Map<String, Object?> decodeJsonObject(List<int> bytes) {
  try {
    final v = jsonDecode(utf8.decode(bytes));
    return _map(v);
  } on FormatException {
    throw KfError(KfErrorCode.protocol, 'bad json');
  }
}

Map<String, Object?> _map(Object? v) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) return v.cast<String, Object?>();
  throw KfError(KfErrorCode.invalidOffer, 'expected an object');
}

String _str(Object? v, {required int max}) {
  if (v is! String || v.length > max) throw KfError(KfErrorCode.invalidOffer, 'expected a string');
  return v;
}

int _int(Object? v) {
  if (v is int) return v;
  throw KfError(KfErrorCode.invalidOffer, 'expected an integer');
}
