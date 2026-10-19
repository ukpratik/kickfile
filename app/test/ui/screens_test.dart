// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/app/services.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/core/sas.dart';
import 'package:kickfile/transfer/io_file_access.dart';
import 'package:kickfile/transfer/node.dart';
import 'package:kickfile/transfer/receiver.dart';
import 'package:kickfile/ui/controller.dart';
import 'package:kickfile/ui/scope.dart';
import 'package:kickfile/ui/screens/home.dart';
import 'package:kickfile/ui/screens/incoming_prompt.dart';
import 'package:kickfile/ui/theme/theme.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late KickNode node;
  late AppServices services;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('kf_ui_');
    final save = p.join(root.path, 'save');
    node = await KickNode.open(
      dataDir: Directory(p.join(root.path, 'data')),
      files: IoFileAccess(save),
      defaultName: 'Arjun’s MacBook Air',
      platform: DevicePlatform.macos,
    );
    await node.settings.update((s) => s.copyWith(onboarded: true));
    services = AppServices.test(node, save);
  });

  tearDown(() async {
    services.discovery.dispose();
    await node.dispose();
    root.deleteSync(recursive: true);
  });

  Widget wrap(Widget child) {
    final ui = UiController(services);
    return AppScope(
      services: services,
      ui: ui,
      child: MaterialApp(
        theme: kfTheme(Brightness.light),
        navigatorKey: ui.navigatorKey,
        scaffoldMessengerKey: ui.messengerKey,
        home: child,
      ),
    );
  }

  testWidgets('home lists online devices with a Send cue and trusted devices offline', (t) async {
    final kabir = DeviceInfo(fingerprint: 'a' * 64, name: 'Kabir’s Pixel 8', platform: DevicePlatform.android, port: 47420);
    final meera = DeviceInfo(fingerprint: 'b' * 64, name: 'Meera’s ThinkPad', platform: DevicePlatform.linux, port: 47420);
    await t.runAsync(() async {
      await node.peers.seen(kabir, addresses: ['192.168.1.20']);
      await node.peers.seen(meera, addresses: ['192.168.1.21']);
      await node.peers.update(meera.fingerprint, (p) => p.copyWith(trusted: true));
    });
    services.discovery.addReachable(kabir, '192.168.1.20');

    await t.pumpWidget(wrap(const HomeScreen()));
    await t.pump();

    expect(find.text('Kabir’s Pixel 8'), findsOneWidget);
    expect(find.textContaining('Android · Online'), findsOneWidget);
    expect(find.text('Meera’s ThinkPad'), findsOneWidget);
    expect(find.textContaining('Offline · Trusted'), findsOneWidget);
    expect(find.text('Add a device'), findsOneWidget);
    expect(find.text("Don't see your device?"), findsOneWidget);
    if (isDesktop) expect(find.text('Show QR'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('first-contact prompt shows the code and answers Trust & auto-accept', (t) async {
    final sender = 'c' * 64;
    final req = IncomingRequest(
      offer: const TransferOffer(
        id: 'abcdef12-0000-4000-8000-000000000009',
        senderName: 'Kabir’s Pixel 8',
        senderPlatform: DevicePlatform.android,
        items: [OfferItem(id: 'i0', kind: ItemKind.file, path: 'Trip-Goa.mov', size: 2400000000)],
      ),
      senderFingerprint: sender,
      firstContact: true,
      code: verificationCode(sender, node.fingerprint),
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
      recentDeclines: 0,
    );
    await t.pumpWidget(wrap(Scaffold(body: IncomingPrompt(request: req))));
    expect(find.text('Trust Kabir’s Pixel 8?'), findsOneWidget);
    expect(find.text('Trip-Goa.mov'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Code ')), findsOneWidget);
    await t.tap(find.text('Trust & auto-accept'));
    expect(await req.decision, Decision.trustAuto);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('known device prompt: Accept and the More menu with Block', (t) async {
    final req = IncomingRequest(
      offer: const TransferOffer(
        id: 'abcdef12-0000-4000-8000-00000000000a',
        senderName: 'Riya’s iPhone',
        senderPlatform: DevicePlatform.ios,
        items: [
          OfferItem(id: 'i0', kind: ItemKind.file, path: 'IMG_4821.HEIC', size: 3100000),
          OfferItem(id: 'i1', kind: ItemKind.file, path: 'IMG_4822.HEIC', size: 2900000),
          OfferItem(id: 'i2', kind: ItemKind.file, path: 'Boarding-pass.pdf', size: 12400000),
          OfferItem(id: 'i3', kind: ItemKind.file, path: 'more.pdf', size: 1),
        ],
      ),
      senderFingerprint: 'd' * 64,
      firstContact: false,
      code: '123456',
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
      recentDeclines: 2,
    );
    await t.pumpWidget(wrap(Scaffold(body: IncomingPrompt(request: req))));
    expect(find.text('Riya’s iPhone wants to send 4 files'), findsOneWidget);
    expect(find.text('and 1 more'), findsOneWidget);
    expect(find.textContaining('3rd request in 10 min'), findsOneWidget);
    expect(find.text('Block this device'), findsOneWidget);
    await t.tap(find.text('Accept'));
    expect(await req.decision, Decision.accept);
    await t.pumpWidget(const SizedBox());
  });
}
