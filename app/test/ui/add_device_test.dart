// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/ui/screens/add_device.dart';
import 'package:kickfile/ui/theme/theme.dart';

void main() {
  Future<void> pump(WidgetTester t, DevicePlatform current) async {
    t.view.physicalSize = const Size(420, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: kfTheme(Brightness.light),
        home: AddDeviceScreen(current: current),
      ),
    );
  }

  testWidgets('lists the other platforms first and this device last', (t) async {
    await pump(t, DevicePlatform.macos);
    expect(find.text('Get kickFile on your other devices'), findsOneWidget);
    expect(find.text("You're using it"), findsOneWidget);
    final android = t.getTopLeft(find.text('Android phone')).dy;
    final iphone = t.getTopLeft(find.text('iPhone & iPad')).dy;
    final mac = t.getTopLeft(find.text('Mac')).dy;
    expect(android < iphone && iphone < mac, isTrue);
    expect(find.text('Coming later'), findsOneWidget);
  });

  testWidgets('a row expands to its channels; live ones copy the releases link', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await pump(t, DevicePlatform.android);
    expect(find.text('Flathub'), findsNothing);
    await t.tap(find.text('Linux PC'));
    await t.pumpAndSettle();
    expect(find.text('Flathub'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget);
    await t.tap(find.text('Copy link').last);
    await t.pump();
    expect(copied, kReleasesUrl);
  });
}
