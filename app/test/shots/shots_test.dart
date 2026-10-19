@Tags(['shots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/app/services.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/core/sas.dart';
import 'package:kickfile/transfer/io_file_access.dart';
import 'package:kickfile/transfer/node.dart';
import 'package:kickfile/transfer/receiver.dart';
import 'package:kickfile/ui/controller.dart';
import 'package:kickfile/ui/scope.dart';
import 'package:kickfile/ui/screens/connection_help.dart';
import 'package:kickfile/ui/screens/home.dart';
import 'package:kickfile/ui/screens/incoming_prompt.dart';
import 'package:kickfile/ui/screens/qr_screen.dart';
import 'package:kickfile/ui/screens/settings.dart';
import 'package:kickfile/ui/theme/theme.dart';
import 'package:path/path.dart' as p;

/// Renders screens to PNG for visual review: `KF_SHOTS=/some/dir flutter test test/shots`.
final outDir = Platform.environment['KF_SHOTS'];

Future<void> loadFonts() async {
  var dir = p.dirname(Platform.resolvedExecutable);
  while (!Directory(p.join(dir, 'material_fonts')).existsSync() && p.dirname(dir) != dir) {
    dir = p.dirname(dir);
  }
  final material = p.join(dir, 'material_fonts');
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final file = File(p.join(material, f));
    if (file.existsSync()) roboto.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await roboto.load();
  for (final fam in ['Lucide', 'Lucide500']) {
    final l = FontLoader('packages/lucide_icons_flutter/$fam');
    l.addFont(rootBundle.load('packages/lucide_icons_flutter/${fam == 'Lucide' ? 'assets/lucide.ttf' : 'assets/build_font/LucideVariable-w500.ttf'}'));
    await l.load();
  }
}

ThemeData themed(Brightness b) {
  final t = kfTheme(b);
  return t.copyWith(textTheme: t.textTheme.apply(fontFamily: 'Roboto'));
}

void main() {
  late Directory root;
  late KickNode node;
  late AppServices services;

  setUpAll(loadFonts);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('kf_shots_');
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
  });

  Future<void> shot(WidgetTester t, String name, Widget child, {Brightness b = Brightness.light}) async {
    t.view.physicalSize = const Size(420, 640) * 2;
    t.view.devicePixelRatio = 2;
    final key = GlobalKey();
    final ui0 = UiController(services);
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: AppScope(
          services: services,
          ui: ui0,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themed(Brightness.light),
            darkTheme: themed(Brightness.dark),
            themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
            navigatorKey: ui0.navigatorKey,
            scaffoldMessengerKey: ui0.messengerKey,
            home: child,
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 600));
    await t.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 2);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(outDir!, '$name.png')).writeAsBytesSync(png!.buffer.asUint8List());
    });
    await t.pumpWidget(const SizedBox());
  }

  Future<void> seedPeers(WidgetTester t) async {
    final kabir = DeviceInfo(fingerprint: 'a' * 64, name: 'Kabir’s Pixel 8', platform: DevicePlatform.android, port: 47420);
    final win = DeviceInfo(fingerprint: 'e' * 64, name: 'DESKTOP-4KD2', platform: DevicePlatform.windows, port: 47420);
    final meera = DeviceInfo(fingerprint: 'b' * 64, name: 'Meera’s ThinkPad', platform: DevicePlatform.linux, port: 47420);
    await t.runAsync(() async {
      await node.peers.seen(kabir, addresses: ['192.168.1.20']);
      await node.peers.seen(win, addresses: ['192.168.1.22']);
      await node.peers.update(win.fingerprint, (p) => p.copyWith(trusted: true, autoAccept: true));
      await node.peers.seen(meera, addresses: ['192.168.1.21']);
      await node.peers.update(meera.fingerprint, (p) => p.copyWith(trusted: true));
    });
    services.discovery.addReachable(kabir, '192.168.1.20');
    services.discovery.addReachable(win, '192.168.1.22');
  }

  testWidgets('shots', (t) async {
    await shot(t, 'home_firstrun', const HomeScreen());
    await seedPeers(t);
    await shot(t, 'home_light', const HomeScreen());
    await shot(t, 'home_dark', const HomeScreen(), b: Brightness.dark);
    final req = IncomingRequest(
      offer: const TransferOffer(
        id: 'abcdef12-0000-4000-8000-000000000009',
        senderName: 'Kabir’s Pixel 8',
        senderPlatform: DevicePlatform.android,
        items: [OfferItem(id: 'i0', kind: ItemKind.file, path: 'Trip-Goa.mov', size: 2400000000)],
      ),
      senderFingerprint: 'a' * 64,
      firstContact: true,
      code: verificationCode('a' * 64, node.fingerprint),
      expiresAt: DateTime.now().add(const Duration(seconds: 52)),
      recentDeclines: 0,
    );
    await shot(t, 'trust_prompt', Scaffold(body: Center(child: Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: IncomingPrompt(request: req))))));
    await shot(t, 'connection_help', const ConnectionHelpScreen());
    await shot(t, 'settings', const SettingsScreen());
    await shot(t, 'qr', const QrScreen());
  }, skip: outDir == null);
}
