import 'dart:async';

import 'package:flutter/services.dart';

import '../core/errors.dart';
import '../core/names.dart';
import '../core/protocol.dart';
import '../transfer/file_access.dart';

/// The Kotlin side (`KfFiles.kt`, ADR-005).
class AndroidBridge {
  static const _ch = MethodChannel('kickfile/files');
  static const _events = EventChannel('kickfile/intents');

  static Stream<Map<String, Object?>> get intents =>
      _events.receiveBroadcastStream().map((e) => (e as Map).cast<String, Object?>());

  static Future<String?> deviceName() => _ch.invokeMethod<String>('deviceName');
  static Future<int> sdkInt() async => await _ch.invokeMethod<int>('sdkInt') ?? 0;

  static Future<List<SendSource>> pickMedia() => _pick('pickMedia');
  static Future<List<SendSource>> pickFiles() => _pick('pickFiles');
  static Future<List<SendSource>> pickFolder() => _pick('pickFolder');

  static Future<List<SendSource>> _pick(String method) async {
    final raw = await _ch.invokeListMethod<Object?>(method) ?? const [];
    return [for (final m in raw) sourceFromMap((m! as Map).cast<String, Object?>())];
  }

  static SendSource sourceFromMap(Map<String, Object?> m) => m['kind'] == 'dir'
      ? SendSource(kind: ItemKind.dir, relPath: m['relPath']! as String)
      : SendSource(
          kind: ItemKind.file,
          relPath: m['relPath']! as String,
          ref: m['uri']! as String,
          size: (m['size']! as num).toInt(),
          mtime: (m['mtime'] as num?)?.toInt() ?? 0,
          mime: m['mime'] as String?,
        );

  static Future<bool> open(String ref) async => await _ch.invokeMethod<bool>('open', {'ref': ref}) ?? false;
  static Future<bool> reveal(String ref) async => await _ch.invokeMethod<bool>('reveal', {'ref': ref}) ?? false;

  static Future<void> foreground(String title, String text, int progress) =>
      _ch.invokeMethod('fgUpdate', {'title': title, 'text': text, 'progress': progress});
  static Future<void> stopForeground() => _ch.invokeMethod('fgStop');

  static Future<T?> call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw KfError(e.code == 'no_space' ? KfErrorCode.noSpace : KfErrorCode.io, e.message);
    }
  }
}

/// FileAccess over the Kotlin channel: content URIs in, MediaStore items out.
class AndroidFileAccess implements FileAccess {
  static const _chunk = 1 << 20;

  @override
  Stream<List<int>> openRead(SendSource source, {int offset = 0}) => _read(source.ref, offset);

  Stream<List<int>> _read(String ref, int offset) async* {
    final handle = await AndroidBridge.call<int>('openRead', {'ref': ref, 'offset': offset});
    if (handle == null) throw KfError(KfErrorCode.sourceMissing);
    try {
      while (true) {
        final bytes = await AndroidBridge.call<Uint8List>('read', {'handle': handle, 'max': _chunk});
        if (bytes == null) break;
        yield bytes;
      }
    } finally {
      await AndroidBridge.call<void>('closeRead', {'handle': handle});
    }
  }

  @override
  Future<SourceStat?> stat(SendSource source) async {
    try {
      final m = await AndroidBridge.call<Map<Object?, Object?>>('stat', {'ref': source.ref});
      if (m == null) return null;
      return SourceStat((m['size']! as num).toInt(), (m['mtime'] as num?)?.toInt() ?? 0);
    } on KfError {
      return null;
    }
  }

  @override
  Future<String> createPartial(String transferId, String itemId, String relPath, int size) async =>
      (await AndroidBridge.call<String>('createTarget', {'relPath': safeSegments(relPath).join('/'), 'mime': null}))!;

  @override
  Future<int> partialLength(String partialRef) async =>
      (await AndroidBridge.call<num>('partialLength', {'ref': partialRef}) ?? 0).toInt();

  @override
  Stream<List<int>> readPartial(String partialRef) => _read(partialRef, 0);

  @override
  Future<PartialWriter> openPartial(String partialRef, int offset) async {
    final h = await AndroidBridge.call<int>('openWrite', {'ref': partialRef, 'offset': offset});
    return _ChannelWriter(h!);
  }

  @override
  Future<String> finalize(String partialRef, String relPath, {int mtime = 0}) async =>
      (await AndroidBridge.call<String>('finalize', {'ref': partialRef}))!;

  @override
  Future<void> discard(String partialRef) => AndroidBridge.call<void>('discard', {'ref': partialRef});

  /// MediaStore has no empty folders; files carry their folder in RELATIVE_PATH.
  @override
  Future<void> createDir(String relPath) async {}

  /// Pending MediaStore items we didn't discard are removed by Android after 7 days.
  @override
  Future<void> removeTransferPartials(String transferId) async {}

  @override
  Future<int?> freeBytes() async => (await AndroidBridge.call<num>('freeBytes'))?.toInt();
}

class _ChannelWriter implements PartialWriter {
  _ChannelWriter(this.handle);
  final int handle;

  @override
  Future<void> add(List<int> chunk) => AndroidBridge.call<void>(
    'write',
    {'handle': handle, 'bytes': chunk is Uint8List ? chunk : Uint8List.fromList(chunk)},
  );

  @override
  Future<void> close() => AndroidBridge.call<void>('closeWrite', {'handle': handle});
}
