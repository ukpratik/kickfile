import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/log.dart';

/// What the tray menu and window close can ask the UI to do.
abstract class ShellActions {
  void sendFiles();
  void showQr();
  Future<void> setVisible(bool visible);
  bool get visible;
  bool get keepInBackground;

  /// Linux only, once: "Keep receiving in the background?" Returns true to keep running.
  Future<bool> askKeepInBackground();
  Future<void> quit();
}

/// Window 420×640, tray / menu bar icon, close-to-background (US-005, US-015).
class DesktopShell with WindowListener, TrayListener {
  DesktopShell(this.actions);

  final ShellActions actions;
  bool _trayReady = false;

  /// [show] is false when started at login: stay in the tray until needed.
  static Future<void> initWindow({bool show = true}) async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(420, 640),
      minimumSize: Size(360, 520),
      center: true,
      title: 'kickFile',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (!show) return;
      await windowManager.show();
      await windowManager.focus();
    });
  }

  Future<void> init() async {
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    trayManager.addListener(this);
    try {
      if (Platform.isMacOS) {
        await trayManager.setIcon('assets/tray/tray_template.png', isTemplate: true);
      } else if (Platform.isWindows) {
        await trayManager.setIcon('assets/tray/tray.ico');
      } else {
        await trayManager.setIcon('assets/tray/tray.png');
      }
      await trayManager.setToolTip('kickFile');
      _trayReady = true;
      await updateMenu();
    } catch (e) {
      log.warn('shell', 'tray unavailable: ${e.runtimeType}');
    }
  }

  Future<void> updateMenu({String? status}) async {
    if (!_trayReady) return;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'open', label: 'Open kickFile'),
          if (status != null) MenuItem(key: 'status', label: status, disabled: true),
          MenuItem.separator(),
          MenuItem(key: 'send', label: 'Send files…'),
          MenuItem(key: 'qr', label: 'Show QR code'),
          MenuItem.separator(),
          MenuItem.checkbox(key: 'visible', label: 'Visible to nearby devices', checked: actions.visible),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit kickFile'),
        ],
      ),
    );
  }

  /// Tooltip shows progress while something is moving (design: stepped icons are a later polish).
  Future<void> setStatus(String? status) async {
    if (!_trayReady) return;
    await trayManager.setToolTip(status == null ? 'kickFile' : 'kickFile · $status');
    await updateMenu(status: status);
  }

  Future<void> showWindow() async {
    await windowManager.show();
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.focus();
  }

  Future<bool> get windowVisible async => await windowManager.isVisible() && !await windowManager.isMinimized();

  Future<void> setLaunchAtLogin(bool on) async {
    if (Platform.isMacOS) return; // B-021
    try {
      launchAtStartup.setup(appName: 'kickFile', appPath: Platform.resolvedExecutable, args: const ['--background']);
      if (on) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (e) {
      log.warn('shell', 'launch at login failed ${e.runtimeType}');
    }
  }

  // ---- WindowListener ----
  @override
  void onWindowClose() => unawaited(_onClose());

  Future<void> _onClose() async {
    if (!actions.keepInBackground) return actions.quit();
    if (Platform.isLinux) {
      if (!await actions.askKeepInBackground()) return actions.quit();
      // GNOME may have no tray: keep the window reachable from the dock / taskbar.
      await windowManager.minimize();
      return;
    }
    await windowManager.hide();
  }

  // ---- TrayListener ----
  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      unawaited(showWindow());
    } else {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(showWindow());
      case 'send':
        unawaited(showWindow().then((_) => actions.sendFiles()));
      case 'qr':
        unawaited(showWindow().then((_) => actions.showQr()));
      case 'visible':
        unawaited(actions.setVisible(!actions.visible).then((_) => updateMenu()));
      case 'quit':
        unawaited(actions.quit());
    }
  }
}
