// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

/// Minimal rotating logger. Never log file names, file contents or IP addresses
/// of other devices beyond what's needed to debug (LLD §6).
class KfLog {
  File? _file;
  int maxBytes = 1024 * 1024;
  bool echo = false;

  void attach(File file) => _file = file;

  void info(String area, String msg) => _write('I', area, msg);
  void warn(String area, String msg) => _write('W', area, msg);
  void error(String area, String msg) => _write('E', area, msg);

  void _write(String level, String area, String msg) {
    final line = '${DateTime.now().toIso8601String()} $level $area $msg';
    if (echo) stdout.writeln(line);
    final f = _file;
    if (f == null) return;
    try {
      if (f.existsSync() && f.lengthSync() > maxBytes) {
        f.renameSync('${f.path}.1');
      }
      f.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // Logging must never break the app.
    }
  }

  /// Both log files, oldest first, for "Export logs".
  List<File> files() {
    final f = _file;
    if (f == null) return const [];
    return [File('${f.path}.1'), f].where((x) => x.existsSync()).toList();
  }
}

final log = KfLog();
