// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/log.dart';
import 'android_bridge.dart';

/// Open a received file, or show it in the file manager (US-007).
class OsActions {
  const OsActions();

  Future<bool> open(String location, {String? name}) async {
    if (Platform.isAndroid) {
      if (location.startsWith('content://')) return AndroidBridge.open(location, name: name);
      if (Uri.tryParse(location)?.hasScheme ?? false) return launchUrl(Uri.parse(location), mode: LaunchMode.externalApplication);
      return false;
    }
    if (Uri.tryParse(location)?.scheme.startsWith('http') ?? false) {
      return launchUrl(Uri.parse(location), mode: LaunchMode.externalApplication);
    }
    if (!await File(location).exists() && !await Directory(location).exists()) return false;
    try {
      return await launchUrl(Uri.file(location));
    } catch (e) {
      log.warn('os', 'open failed ${e.runtimeType}');
      return false;
    }
  }

  Future<bool> reveal(String location) async {
    if (Platform.isAndroid) return AndroidBridge.reveal(location);
    final exists = await File(location).exists() || await Directory(location).exists();
    if (!exists) return false;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', location]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', location]);
      } else if (Platform.isLinux) {
        final r = await Process.run('dbus-send', [
          '--session',
          '--dest=org.freedesktop.FileManager1',
          '--type=method_call',
          '/org/freedesktop/FileManager1',
          'org.freedesktop.FileManager1.ShowItems',
          'array:string:${Uri.file(location)}',
          'string:',
        ]);
        if (r.exitCode != 0) await Process.run('xdg-open', [p.dirname(location)]);
      }
      return true;
    } catch (e) {
      log.warn('os', 'reveal failed ${e.runtimeType}');
      return false;
    }
  }

  Future<void> openFolder(String dir) async {
    await Directory(dir).create(recursive: true);
    await launchUrl(Uri.directory(dir));
  }
}

/// Our name for this computer, as people would recognise it.
Future<String> desktopDeviceName() async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('scutil', ['--get', 'ComputerName']);
      final s = (r.stdout as String).trim();
      if (s.isNotEmpty) return s;
    }
    if (Platform.isLinux) {
      final r = await Process.run('hostnamectl', ['--pretty']);
      final s = (r.stdout as String).trim();
      if (r.exitCode == 0 && s.isNotEmpty) return s;
    }
  } catch (_) {}
  final h = Platform.localHostname.replaceAll(RegExp(r'\.local$'), '');
  if (h.isNotEmpty && h != 'localhost') return h;
  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase();
  final kind = Platform.isMacOS ? 'Mac' : (Platform.isWindows ? 'Windows' : 'Linux');
  return '$kind device ${suffix.substring(suffix.length - 4)}';
}
