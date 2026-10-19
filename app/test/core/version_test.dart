// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/protocol.dart';

void main() {
  test('Settings shows the pubspec version, and versionCode follows MAJOR*10000 + MINOR*100 + PATCH', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final m = RegExp(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)$').firstMatch(line.trim())!;
    expect('${m[1]}.${m[2]}.${m[3]}', kAppVersion);
    expect(int.parse(m[4]!), int.parse(m[1]!) * 10000 + int.parse(m[2]!) * 100 + int.parse(m[3]!));
  });
}
