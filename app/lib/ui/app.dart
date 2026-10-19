import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app/android_hooks.dart';
import '../app/desktop_shell.dart';
import '../app/notifier.dart';
import '../app/services.dart';
import '../core/protocol.dart';
import '../storage/settings.dart';
import '../transfer/receiver.dart';
import 'controller.dart';
import 'format.dart';
import 'scope.dart';
import 'screens/home.dart';
import 'screens/incoming_prompt.dart';
import 'screens/qr_screen.dart';
import 'screens/share_target.dart';
import 'screens/welcome.dart';
import 'theme/theme.dart';

class KickApp extends StatefulWidget {
  const KickApp({super.key, required this.services});
  final AppServices services;

  @override
  State<KickApp> createState() => _KickAppState();
}

class _KickAppState extends State<KickApp> implements ShellActions {
  late final UiController ui = UiController(widget.services);
  StreamSubscription<IncomingSession>? _completedSub;
  AndroidHooks? _android;
  Timer? _trayTimer;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    s.node.receiver.onRequest = _onRequest;
    _completedSub = s.node.receiver.completed.listen(_onCompleted);
    s.notifier.onTap = (_) => unawaited(ui.shell?.showWindow());
    if (Platform.isAndroid) {
      _android = AndroidHooks(
        s,
        ui,
        onShare: (sources) {
          final c = ui.navigatorKey.currentContext;
          if (c != null) unawaited(showShareTarget(c, sources));
        },
        onPaired: (name) => ui.toast('Connected to $name'),
      )..start();
    }
    if (isDesktop) {
      final shell = DesktopShell(this);
      ui.shell = shell;
      unawaited(shell.init());
      unawaited(shell.setLaunchAtLogin(s.node.settings.value.launchAtLogin));
      _trayTimer = Timer.periodic(const Duration(seconds: 2), (_) => _updateTray());
    }
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _trayTimer?.cancel();
    _android?.dispose();
    super.dispose();
  }

  // ---- incoming requests (US-005) ----

  Future<Decision> _onRequest(IncomingRequest req) async {
    final hidden = isDesktop && !await (ui.shell?.windowVisible ?? Future.value(true));
    if (hidden) {
      final settings = s.node.settings;
      if (Platform.isMacOS && !settings.value.promptsShown.contains('notifications')) {
        await settings.markPromptShown('notifications');
        await s.notifier.requestPermission();
      }
      final files = req.offer.fileCount;
      await s.notifier.show(
        Notifier.incomingId,
        req.firstContact ? 'Trust ${req.senderName}?' : '${req.senderName} wants to send ${files == 0 ? 'text' : countFiles(files)}',
        files == 0 ? 'Open kickFile to see it.' : '${req.offer.items.first.name}${files > 1 ? ' and ${files - 1} more' : ''} · ${formatBytes(req.offer.totalBytes)}',
        payload: 'incoming',
      );
      if (Platform.isLinux) unawaited(ui.shell?.showWindow());
    }
    final c = ui.navigatorKey.currentContext;
    if (c != null && c.mounted) unawaited(showIncomingPrompt(c, req));
    final d = await req.decision;
    unawaited(s.notifier.cancel(Notifier.incomingId));
    if (req.cancelledBySender) ui.toast('${req.senderName} cancelled');
    return d;
  }

  Future<void> _onCompleted(IncomingSession session) async {
    if (session.state != SessionState.done && session.state != SessionState.partial) return;
    final files = session.files.where((f) => f.done).toList();
    if (isDesktop && s.node.settings.value.revealAutomatically && files.isNotEmpty) {
      unawaited(s.os.reveal(files.first.location!));
    }
    final visible = !isDesktop || await (ui.shell?.windowVisible ?? Future.value(true));
    if (!visible) {
      await s.notifier.show(
        Notifier.doneId,
        session.fileCount == 0 ? 'Text from ${session.senderName}' : 'Received ${countFiles(session.fileCount)} from ${session.senderName}',
        session.fileCount == 0 ? 'Open kickFile to copy it.' : 'Saved to ${s.saveDir}',
      );
    }
  }

  // ---- tray status ----

  void _updateTray() {
    final shell = ui.shell;
    if (shell == null) return;
    String? status;
    final job = s.node.transfers.activeJobs.firstOrNull;
    final inc = s.node.receiver.session;
    if (inc != null && inc.state == SessionState.active && inc.totalBytes > 0) {
      status = 'Receiving from ${inc.senderName} · ${(inc.receivedBytes * 100 ~/ inc.totalBytes)}%';
    } else if (job != null && job.totalBytes > 0) {
      status = 'Sending to ${job.peerName} · ${(job.sentBytes * 100 ~/ job.totalBytes)}%';
    }
    unawaited(shell.setStatus(status));
  }

  // ---- ShellActions (tray menu, window close) ----

  @override
  void sendFiles() {
    final online = s.discovery.devices.where((e) => e.$2?.online ?? false).map((e) => e.$1).toList();
    if (online.isEmpty) {
      ui.toast('No devices online. Open kickFile on the other device.');
      return;
    }
    if (online.length == 1) {
      unawaited(ui.pickFilesFor(online.first));
      return;
    }
    final c = ui.navigatorKey.currentContext;
    if (c == null) return;
    unawaited(
      showDialog<void>(
        context: c,
        builder: (d) => SimpleDialog(
          title: const Text('Send files to…'),
          children: [
            for (final p in online)
              SimpleDialogOption(
                onPressed: () {
                  Navigator.pop(d);
                  unawaited(ui.pickFilesFor(p));
                },
                child: Text(p.displayName),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void showQr() => unawaited(ui.navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => const QrScreen())));

  @override
  bool get visible => s.node.settings.value.visible;

  @override
  Future<void> setVisible(bool v) async {
    await s.node.settings.update((x) => x.copyWith(visible: v));
    await s.discovery.updateBroadcast();
  }

  @override
  bool get keepInBackground => s.node.settings.value.keepInBackground;

  @override
  Future<bool> askKeepInBackground() async {
    final settings = s.node.settings;
    if (settings.value.promptsShown.contains('linux_close')) return settings.value.keepInBackground;
    final c = ui.navigatorKey.currentContext;
    if (c == null) return true;
    final keep = await showDialog<bool>(
      context: c,
      builder: (d) => AlertDialog(
        title: const Text('Keep receiving in the background?'),
        content: const Text('kickFile can stay running so other devices can send to this one. You’ll get a notification when something arrives.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Quit')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Keep running')),
        ],
      ),
    );
    await settings.update((x) => x.copyWith(
      keepInBackground: keep ?? true,
      promptsShown: {...x.promptsShown, 'linux_close'},
    ));
    return keep ?? true;
  }

  @override
  Future<void> firstCloseNotice() async {
    final settings = s.node.settings;
    if (settings.value.promptsShown.contains('close_notice')) return;
    await settings.markPromptShown('close_notice');
    final c = ui.navigatorKey.currentContext;
    if (c == null || !c.mounted) return;
    await showDialog<void>(
      context: c,
      builder: (d) => AlertDialog(
        title: const Text('kickFile is still running'),
        content: Text(
          Platform.isMacOS
              ? 'It stays in the menu bar so your phone can send files to this Mac. Quit from the menu-bar icon or with ⌘Q.'
              : 'It stays in the system tray so your phone can send files to this PC. Right-click the tray icon to quit.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('OK'))],
      ),
    );
  }

  @override
  Future<void> quit() async {
    await s.shutdown();
    exit(0);
  }

  @override
  Widget build(BuildContext context) => AppScope(
    services: s,
    ui: ui,
    child: ListenableBuilder(
      listenable: s.node.settings,
      builder: (context, _) {
        final v = s.node.settings.value;
        return MaterialApp(
          title: 'kickFile',
          debugShowCheckedModeBanner: false,
          navigatorKey: ui.navigatorKey,
          scaffoldMessengerKey: ui.messengerKey,
          theme: kfTheme(Brightness.light),
          darkTheme: kfTheme(Brightness.dark),
          themeMode: switch (v.theme) {
            ThemeChoice.light => ThemeMode.light,
            ThemeChoice.dark => ThemeMode.dark,
            ThemeChoice.system => ThemeMode.system,
          },
          home: v.onboarded
              ? const HomeScreen()
              : WelcomeScreen(
                  onDone: () {
                    unawaited(s.discovery.start());
                    _android?.onOnboarded();
                    setState(() {});
                  },
                ),
        );
      },
    ),
  );
}

/// Kept for screens that need the platform label of this device.
DevicePlatform get thisPlatform => currentPlatform;
