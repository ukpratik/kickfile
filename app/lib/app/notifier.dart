import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/log.dart';

/// System notifications: incoming requests while the window is hidden, finished transfers.
class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  void Function(String? payload)? onTap;

  static const incomingId = 1;
  static const doneId = 2;

  Future<void> init() async {
    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          macOS: const DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: const LinuxInitializationSettings(defaultActionName: 'Open kickFile'),
          windows: const WindowsInitializationSettings(
            appName: 'kickFile',
            appUserModelId: 'io.github.ukpratik.kickfile',
            guid: '6c5c8a2e-1f0b-4d8e-9a3c-7b1e2f4d9a61',
          ),
        ),
        onDidReceiveNotificationResponse: (r) => onTap?.call(r.payload),
      );
      _ready = true;
    } catch (e) {
      log.warn('notify', 'init failed ${e.runtimeType}');
    }
  }

  /// Asked in context: the first time a request arrives while the window is closed
  /// (macOS) or after the first completed transfer (Android 13+).
  Future<bool> requestPermission() async {
    try {
      if (Platform.isMacOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, sound: true) ??
            false;
      }
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            false;
      }
    } catch (_) {}
    return true;
  }

  Future<void> show(int id, String title, String body, {String? payload}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'transfers',
            'Transfers',
            channelDescription: 'Incoming requests and finished transfers',
            importance: Importance.high,
            priority: Priority.high,
          ),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      log.warn('notify', 'show failed ${e.runtimeType}');
    }
  }

  Future<void> cancel(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }
}
