import 'dart:async';

import 'package:flutter/material.dart';

import 'app/desktop_shell.dart';
import 'app/services.dart';
import 'core/log.dart';
import 'ui/app.dart';
import 'ui/theme/theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (d) {
    log.error('ui', d.exceptionAsString().split('\n').first);
    FlutterError.presentError(d);
  };
  if (isDesktop) await DesktopShell.initWindow(show: !args.contains('--background'));
  final services = await AppServices.init();
  runApp(KickApp(services: services));
}
