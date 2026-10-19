// SPDX-License-Identifier: GPL-3.0-or-later
@Tags(['video'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/app/services.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/net/client.dart';
import 'package:kickfile/net/netinfo.dart';
import 'package:kickfile/transfer/file_access.dart';
import 'package:kickfile/transfer/receiver.dart';
import 'package:kickfile/ui/controller.dart';
import 'package:kickfile/ui/scope.dart';
import 'package:kickfile/ui/screens/add_device.dart';
import 'package:kickfile/ui/screens/connection_help.dart';
import 'package:kickfile/ui/screens/home.dart';
import 'package:kickfile/ui/screens/incoming_prompt.dart';
import 'package:kickfile/ui/screens/qr_screen.dart';
import 'package:kickfile/ui/screens/settings.dart';
import 'package:kickfile/ui/screens/welcome.dart';
import 'package:kickfile/ui/theme/theme.dart';
import 'package:path/path.dart' as p;

import '../support/nodes.dart';

/// Renders the desktop scenes of the how-to video from the real UI and real transfers.
///   KF_VIDEO=/some/dir flutter test test/video
final outDir = Platform.environment['KF_VIDEO'];

Future<void> loadFonts() async {
  var dir = p.dirname(Platform.resolvedExecutable);
  while (!Directory(p.join(dir, 'material_fonts')).existsSync() && p.dirname(dir) != dir) {
    dir = p.dirname(dir);
  }
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    roboto.addFont(Future.value(ByteData.sublistView(File(p.join(dir, 'material_fonts', f)).readAsBytesSync())));
  }
  await roboto.load();
  // The 6-digit code uses the platform monospace; in renders, digits come from Roboto.
  final mono = FontLoader('Menlo');
  for (final f in ['Roboto-Medium.ttf']) {
    mono.addFont(Future.value(ByteData.sublistView(File(p.join(dir, 'material_fonts', f)).readAsBytesSync())));
  }
  await mono.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File(p.join(dir, 'material_fonts', 'MaterialIcons-Regular.otf')).readAsBytesSync())));
  await icons.load();
  for (final fam in ['Lucide', 'Lucide500']) {
    final l = FontLoader('packages/lucide_icons_flutter/$fam')
      ..addFont(rootBundle.load('packages/lucide_icons_flutter/${fam == 'Lucide' ? 'assets/lucide.ttf' : 'assets/build_font/LucideVariable-w500.ttf'}'));
    await l.load();
  }
}

const wifi = NetworkState(addresses: [LocalAddress('192.168.1.40', 'en0', LinkKind.wifi)], vpnActive: false);

void main() {
  setUpAll(loadFonts);

  testWidgets('desktop scenes', (t) async {
    // flutter_test mocks every HttpClient with 400s; these scenes need real transfers.
    HttpOverrides.global = null;
    t.view.physicalSize = const Size(420, 640) * 2;
    t.view.devicePixelRatio = 2;

    late TestDevice mac, phone, win;
    await t.runAsync(() async {
      mac = await TestDevice.create("Arjun's MacBook Air", platform: DevicePlatform.macos, offerTimeout: const Duration(minutes: 2), files: (d) => SlowFileAccess(d, delay: const Duration(milliseconds: 25)));
      phone = await TestDevice.create("Kabir's Pixel 8", platform: DevicePlatform.android, files: (d) => SlowFileAccess(d, delay: const Duration(milliseconds: 25)));
      win = await TestDevice.create("Riya's work laptop", platform: DevicePlatform.windows);
    });
    addTearDown(() async {
      await t.runAsync(() async {
        await mac.close();
        await phone.close();
        await win.close();
      });
    });
    // Platforms as they'd announce themselves.
    final macInfo = DeviceInfo(fingerprint: mac.node.fingerprint, name: "Arjun's MacBook Air", platform: DevicePlatform.macos, port: mac.node.port);
    final phoneInfo = DeviceInfo(fingerprint: phone.node.fingerprint, name: "Kabir's Pixel 8", platform: DevicePlatform.android, port: phone.node.port);

    AppServices svc(TestDevice d) {
      final s = AppServices.test(d.node, d.saveDir)..displaySaveDirOverride = '~/Downloads/kickFile';
      s.discovery.network = wifi;
      return s;
    }

    final macSvc = svc(mac);
    final winSvc = svc(win);

    Future<void> shot(String name, AppServices s, UiController u, Widget home, {Future<void> Function(BuildContext)? after}) async {
      final key = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: AppScope(
            services: s,
            ui: u,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: kfTheme(Brightness.light, font: 'Roboto'),
              navigatorKey: u.navigatorKey,
              scaffoldMessengerKey: u.messengerKey,
              home: home,
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      if (after != null) {
        unawaited(after(u.navigatorKey.currentContext!));
        await t.pump(const Duration(milliseconds: 400));
      }
      await t.pump(const Duration(milliseconds: 400));
      await t.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await boundary.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(outDir!, '$name.png')).writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // Guide page (README screenshots), first: before discovery's 30 s subnet probe can fire.
    await shot('mac_get', macSvc, UiController(macSvc), const AddDeviceScreen(current: DevicePlatform.macos));
    await shot('mac_get_android', macSvc, UiController(macSvc), const AddDeviceScreen(current: DevicePlatform.macos, expanded: {DevicePlatform.android}));

    // 1-2 · Mac first run.
    await t.runAsync(() => mac.node.settings.update((x) => x.copyWith(onboarded: false)));
    await shot('mac_welcome', macSvc, UiController(macSvc), WelcomeScreen(onDone: () {}));
    await t.runAsync(() => mac.node.settings.update((x) => x.copyWith(onboarded: true)));
    await shot('mac_firstrun', macSvc, UiController(macSvc), const HomeScreen());

    // 3 · The phone sends: the Mac asks to trust it (first contact).
    late Completer<Decision> decide;
    await t.runAsync(() async => decide = Completer<Decision>());
    mac.node.receiver.onRequest = (r) => decide.future;
    late SendSource video;
    await t.runAsync(() async {
      final f = await phone.makeFile('Trip-Goa.mov', 24 * 1024 * 1024, seed: 3);
      video = await phone.source(f, 'Trip-Goa.mov');
      await mac.node.peers.seen(phoneInfo, addresses: ['127.0.0.1']);
      final toMac = await phone.node.peers.seen(macInfo, addresses: ['127.0.0.1']);
      phone.node.send(toMac.copyWith(port: mac.node.port), '127.0.0.1', [video]);
      await waitFor(() => mac.node.receiver.pending != null);
    });
    macSvc.discovery.addReachable(phoneInfo, '127.0.0.1');
    final req = mac.node.receiver.pending!;
    await shot('mac_trust', macSvc, UiController(macSvc), const HomeScreen(), after: (c) => showIncomingPrompt(c, req));

    // 4-5 · Receiving, then done.
    await t.runAsync(() async => decide.complete(Decision.trustAuto));
    await t.runAsync(() => waitFor(() => (mac.node.receiver.session?.receivedBytes ?? 0) > 9 * 1024 * 1024, timeout: const Duration(seconds: 30)));
    await shot('mac_receiving', macSvc, UiController(macSvc), const HomeScreen());
    await t.runAsync(() => waitFor(() => mac.node.receiver.lastFinished != null, timeout: const Duration(seconds: 60)));
    await shot('mac_done', macSvc, UiController(macSvc), const HomeScreen());

    // 6 · Drag onto the phone.
    await shot('mac_drop', macSvc, UiController(macSvc), HomeScreen(previewDropTarget: phone.node.fingerprint));

    // 7 · The Mac sends to the phone (the phone auto-accepts: it trusts the Mac now).
    final macSlow = await t.runAsync(() async {
      final f = await mac.makeFile('Q3-report.pdf', 20 * 1024 * 1024, seed: 5);
      return mac.source(f, 'Q3-report.pdf');
    });
    phone.answer = (_) => Decision.trustAuto;
    await t.runAsync(() async {
      final toPhone = mac.node.peers[phone.node.fingerprint]!;
      mac.node.transfers.send(
        to: PeerEndpoint('127.0.0.1', phone.node.port, phone.node.fingerprint),
        peerName: toPhone.displayName,
        peerPlatform: DevicePlatform.android,
        sources: [macSlow!],
      );
    });
    await t.runAsync(() => waitFor(() => mac.node.transfers.jobs.any((j) => j.sentBytes > 6 * 1024 * 1024), timeout: const Duration(seconds: 30)));
    final sendUi = UiController(macSvc)..dismissed.add('in:${mac.node.receiver.lastFinished!.id}');
    await shot('mac_sending', macSvc, sendUi, const HomeScreen());

    // 8 · Windows: home + the first-close message.
    await t.runAsync(() async {
      await win.node.peers.seen(phoneInfo, addresses: ['127.0.0.1']);
      await win.node.peers.update(phone.node.fingerprint, (x) => x.copyWith(trusted: true, autoAccept: true));
      await win.node.peers.seen(macInfo, addresses: ['127.0.0.1']);
    });
    winSvc.discovery
      ..addReachable(phoneInfo, '127.0.0.1')
      ..addReachable(macInfo, '127.0.0.1');
    final winUi = UiController(winSvc);
    await shot('win_home', winSvc, winUi, const HomeScreen());
    await shot(
      'win_close',
      winSvc,
      UiController(winSvc),
      const HomeScreen(),
      after: (c) => showDialog<void>(
        context: c,
        builder: (d) => AlertDialog(
          title: const Text('kickFile is still running'),
          content: const Text('It stays in the system tray so your phone can send files to this PC. Right-click the tray icon to quit.'),
          actions: [FilledButton(onPressed: () {}, child: const Text('OK'))],
        ),
      ),
    );

    // 9-11 · Help, QR, hotspot.
    final helpUi = UiController(macSvc);
    await shot('mac_help', macSvc, helpUi, const ConnectionHelpScreen());
    await t.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await t.pump(const Duration(milliseconds: 300));
    await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
      final img = await boundary.toImage(pixelRatio: 2);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(outDir!, 'mac_hotspot.png')).writeAsBytesSync(png!.buffer.asUint8List());
    });
    await shot('mac_qr', macSvc, UiController(macSvc), const QrScreen());
    await shot('mac_settings', macSvc, UiController(macSvc), const SettingsScreen());
    await t.pumpWidget(const SizedBox());
  }, skip: outDir == null, timeout: const Timeout(Duration(minutes: 5)));
}
