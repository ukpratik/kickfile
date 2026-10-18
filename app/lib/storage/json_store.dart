import 'dart:convert';
import 'dart:io';

import '../core/log.dart';

const kSchemaVersion = 1;

/// One JSON document on disk, written atomically (tmp + rename) and serialised.
class JsonFile {
  JsonFile(this.file, {this.privateFile = false});

  final File file;

  /// Restrict to the current user (identity key).
  final bool privateFile;
  Future<void> _queue = Future.value();

  Future<Map<String, Object?>?> read() async {
    try {
      if (!await file.exists()) return null;
      final v = jsonDecode(await file.readAsString());
      if (v is! Map) return null;
      final map = v.cast<String, Object?>();
      final schema = map['schema'];
      if (schema is int && schema > kSchemaVersion) {
        // Written by a newer app version: keep a copy and start fresh.
        await file.copy('${file.path}.v$schema.bak');
        return null;
      }
      return map;
    } catch (e) {
      log.warn('store', 'unreadable ${file.uri.pathSegments.last}: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> write(Map<String, Object?> data) {
    final body = jsonEncode({'schema': kSchemaVersion, ...data});
    return _queue = _queue.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(body, flush: true);
        if (privateFile && !Platform.isWindows) {
          await Process.run('chmod', ['600', tmp.path]);
        }
        await tmp.rename(file.path);
      } catch (e) {
        log.error('store', 'write failed ${file.uri.pathSegments.last}: ${e.runtimeType}');
      }
    });
  }

  /// Deletes after any queued write, so a late write can't bring the file back.
  Future<void> delete() => _queue = _queue.then((_) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  });
}
