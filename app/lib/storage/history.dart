import 'package:flutter/foundation.dart';

import '../core/protocol.dart';
import 'json_store.dart';

enum Direction { incoming, outgoing }

enum HistoryStatus { waiting, active, paused, done, partial, failed, cancelled, declined, missed, expired, busy, interrupted }

@immutable
class HistoryItem {
  const HistoryItem({
    required this.name,
    required this.size,
    required this.kind,
    this.location,
    this.text,
    this.ok = true,
    this.error,
  });

  final String name;
  final int size;
  final ItemKind kind;

  /// Where a received file was saved: a path (desktop) or a content URI (Android).
  final String? location;
  final String? text;
  final bool ok;
  final String? error;

  Map<String, Object?> toJson() => {
    'name': name,
    'size': size,
    'kind': kind.name,
    if (location != null) 'location': location,
    if (text != null) 'text': text,
    'ok': ok,
    if (error != null) 'error': error,
  };

  static HistoryItem fromJson(Map<String, Object?> j) => HistoryItem(
    name: j['name'] as String? ?? '',
    size: j['size'] as int? ?? 0,
    kind: ItemKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => ItemKind.file),
    location: j['location'] as String?,
    text: j['text'] as String?,
    ok: j['ok'] != false,
    error: j['error'] as String?,
  );
}

@immutable
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.direction,
    required this.peerFingerprint,
    required this.peerName,
    required this.peerPlatform,
    required this.startedAt,
    required this.status,
    required this.totalBytes,
    required this.items,
    this.finishedAt,
    this.doneBytes = 0,
    this.fileCount = 0,
    this.doneFiles = 0,
  });

  /// The transfer id; one entry per transfer and direction.
  final String id;
  final Direction direction;
  final String peerFingerprint;
  final String peerName;
  final DevicePlatform peerPlatform;
  final int startedAt;
  final int? finishedAt;
  final HistoryStatus status;
  final int totalBytes;
  final int doneBytes;
  final int fileCount;
  final int doneFiles;
  final List<HistoryItem> items;

  HistoryEntry copyWith({
    HistoryStatus? status,
    int? finishedAt,
    int? doneBytes,
    int? doneFiles,
    List<HistoryItem>? items,
  }) => HistoryEntry(
    id: id,
    direction: direction,
    peerFingerprint: peerFingerprint,
    peerName: peerName,
    peerPlatform: peerPlatform,
    startedAt: startedAt,
    status: status ?? this.status,
    totalBytes: totalBytes,
    items: items ?? this.items,
    finishedAt: finishedAt ?? this.finishedAt,
    doneBytes: doneBytes ?? this.doneBytes,
    fileCount: fileCount,
    doneFiles: doneFiles ?? this.doneFiles,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'direction': direction.name,
    'peerFp': peerFingerprint,
    'peerName': peerName,
    'peerPlatform': peerPlatform.name,
    'startedAt': startedAt,
    if (finishedAt != null) 'finishedAt': finishedAt,
    'status': status.name,
    'totalBytes': totalBytes,
    'doneBytes': doneBytes,
    'fileCount': fileCount,
    'doneFiles': doneFiles,
    'items': [for (final i in items) i.toJson()],
  };

  static HistoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, Object?>();
    try {
      return HistoryEntry(
        id: j['id']! as String,
        direction: Direction.values.byName(j['direction']! as String),
        peerFingerprint: j['peerFp']! as String,
        peerName: j['peerName'] as String? ?? 'Device',
        peerPlatform: DevicePlatform.parse(j['peerPlatform']),
        startedAt: j['startedAt']! as int,
        finishedAt: j['finishedAt'] as int?,
        status: HistoryStatus.values.byName(j['status']! as String),
        totalBytes: j['totalBytes'] as int? ?? 0,
        doneBytes: j['doneBytes'] as int? ?? 0,
        fileCount: j['fileCount'] as int? ?? 0,
        doneFiles: j['doneFiles'] as int? ?? 0,
        items: [
          for (final i in (j['items'] as List? ?? const []))
            if (i is Map) HistoryItem.fromJson(i.cast<String, Object?>()),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Local transfer history: newest first, at most 500 entries or 90 days (US-014).
class HistoryStore extends ChangeNotifier {
  HistoryStore(this._file, this._entries);

  static const maxEntries = 500;
  static const maxAge = Duration(days: 90);

  final JsonFile _file;
  final List<HistoryEntry> _entries;

  static Future<HistoryStore> load(JsonFile file) async {
    final j = await file.read();
    final entries = <HistoryEntry>[
      for (final e in (j?['entries'] as List? ?? const [])) ?HistoryEntry.fromJson(e),
    ];
    // Outgoing rows left at Sending/Waiting by a quit can never finish (BUG-007).
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.direction == Direction.outgoing &&
          (e.status == HistoryStatus.active || e.status == HistoryStatus.waiting || e.status == HistoryStatus.paused)) {
        entries[i] = e.copyWith(status: HistoryStatus.interrupted);
      }
    }
    final store = HistoryStore(file, entries).._prune();
    return store;
  }

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  HistoryEntry? byId(String id, Direction d) {
    for (final e in _entries) {
      if (e.id == id && e.direction == d) return e;
    }
    return null;
  }

  /// Inserts or replaces (same id + direction) and moves it to the top.
  Future<void> put(HistoryEntry entry) async {
    _entries.removeWhere((e) => e.id == entry.id && e.direction == entry.direction);
    _entries.insert(0, entry);
    _prune();
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await _save();
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    _entries.removeWhere((e) => e.startedAt < cutoff);
    if (_entries.length > maxEntries) _entries.removeRange(maxEntries, _entries.length);
  }

  Future<void> _save() => _file.write({'entries': [for (final e in _entries) e.toJson()]});
}
