import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/log.dart';
import '../core/names.dart';
import '../core/protocol.dart';
import 'file_access.dart';

/// dart:io implementation for desktop (and tests). Partials live in a hidden
/// folder inside the save folder so the final move is a same-volume rename.
class IoFileAccess implements FileAccess {
  IoFileAccess(this.saveDir);

  /// Where received files go, e.g. `~/Downloads/kickFile`. Changeable in Settings.
  String saveDir;

  String get partialRoot => p.join(saveDir, '.kickfile-partial');

  /// Walks a folder the user picked into files and (empty) folders, keeping
  /// the folder's own name as the top of every relative path.
  Stream<SendSource> expandFolder(String folderPath) async* {
    final root = Directory(folderPath);
    final base = p.dirname(root.absolute.path);
    yield SendSource(kind: ItemKind.dir, relPath: _rel(root.path, base));
    await for (final e in root.list(recursive: true, followLinks: false)) {
      final name = p.basename(e.path);
      if (name == '.DS_Store' || name == 'Thumbs.db' || name == 'desktop.ini') continue;
      final rel = _rel(e.path, base);
      if (e is Directory) {
        yield SendSource(kind: ItemKind.dir, relPath: rel);
      } else if (e is File) {
        final st = await e.stat();
        yield SendSource(kind: ItemKind.file, relPath: rel, ref: e.path, size: st.size, mtime: st.modified.millisecondsSinceEpoch);
      }
    }
  }

  String _rel(String path, String base) => p.split(p.relative(p.absolute(path), from: base)).join('/');

  // ---- sending ----

  @override
  Stream<List<int>> openRead(SendSource source, {int offset = 0}) =>
      File(source.ref).openRead(offset);

  @override
  Future<SourceStat?> stat(SendSource source) async {
    final s = await FileStat.stat(source.ref);
    if (s.type == FileSystemEntityType.notFound) return null;
    return SourceStat(s.size, s.modified.millisecondsSinceEpoch);
  }

  // ---- receiving ----

  @override
  Future<String> createPartial(String transferId, String itemId, String relPath, int size) async {
    final f = File(p.join(partialRoot, transferId, '$itemId.part'));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(const [], flush: true);
    return f.path;
  }

  @override
  Future<int> partialLength(String partialRef) async {
    final f = File(partialRef);
    return await f.exists() ? f.length() : 0;
  }

  @override
  Stream<List<int>> readPartial(String partialRef) => File(partialRef).openRead();

  @override
  Future<PartialWriter> openPartial(String partialRef, int offset) async {
    final raf = await File(partialRef).open(mode: FileMode.append);
    await raf.truncate(offset);
    await raf.setPosition(offset);
    return _RafWriter(raf);
  }

  @override
  Future<String> finalize(String partialRef, String relPath, {int mtime = 0}) async {
    final segs = safeSegments(relPath);
    final dir = Directory(p.joinAll([saveDir, ...segs.sublist(0, segs.length - 1)]));
    await dir.create(recursive: true);
    final dest = await _freeName(dir.path, segs.last);
    try {
      await File(partialRef).rename(dest);
    } on FileSystemException {
      // Different volume (custom save folder moved?) → copy, then delete.
      await File(partialRef).copy(dest);
      await File(partialRef).delete();
    }
    if (mtime > 0) {
      try {
        await File(dest).setLastModified(DateTime.fromMillisecondsSinceEpoch(mtime));
      } catch (_) {}
    }
    return dest;
  }

  @override
  Future<void> discard(String partialRef) async {
    try {
      await File(partialRef).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  @override
  Future<void> createDir(String relPath) async {
    await Directory(p.joinAll([saveDir, ...safeSegments(relPath)])).create(recursive: true);
  }

  @override
  Future<void> removeTransferPartials(String transferId) async {
    final d = Directory(p.join(partialRoot, transferId));
    if (await d.exists()) await d.delete(recursive: true);
  }

  @override
  Future<int?> freeBytes() async {
    try {
      await Directory(saveDir).create(recursive: true);
      if (Platform.isWindows) {
        final drive = p.rootPrefix(p.absolute(saveDir)).replaceAll(RegExp(r'[\\/]'), '');
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$drive'\").FreeSpace",
        ]);
        return int.tryParse((r.stdout as String).trim());
      }
      final r = await Process.run('df', ['-Pk', saveDir]);
      final lines = (r.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines.last.split(RegExp(r'\s+'));
      final kb = int.tryParse(cols.length > 3 ? cols[3] : '');
      return kb == null ? null : kb * 1024;
    } catch (e) {
      log.warn('fs', 'free space unknown: ${e.runtimeType}');
      return null;
    }
  }

  Future<String> _freeName(String dir, String name) async {
    var candidate = p.join(dir, name);
    for (var n = 1; await FileSystemEntity.type(candidate) != FileSystemEntityType.notFound; n++) {
      if (n > 9999) throw KfError(KfErrorCode.io, 'no free name');
      candidate = p.join(dir, collisionName(name, n));
    }
    return candidate;
  }
}

class _RafWriter implements PartialWriter {
  _RafWriter(this._raf);
  final RandomAccessFile _raf;

  @override
  Future<void> add(List<int> chunk) async {
    try {
      await _raf.writeFrom(chunk);
    } on FileSystemException catch (e) {
      // ENOSPC (28 on POSIX, 112 on Windows).
      final code = e.osError?.errorCode;
      if (code == 28 || code == 112) throw KfError(KfErrorCode.noSpace);
      throw KfError(KfErrorCode.io, e.message);
    }
  }

  @override
  Future<void> close() => _raf.close();
}
