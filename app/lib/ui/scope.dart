import 'package:flutter/widgets.dart';

import '../app/services.dart';
import 'controller.dart';

/// Gives every widget the services and the UI controller.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required this.ui, required super.child});

  final AppServices services;
  final UiController ui;

  static AppScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => old.services != services || old.ui != ui;
}

extension ScopeX on BuildContext {
  AppServices get services => AppScope.of(this).services;
  UiController get ui => AppScope.of(this).ui;
}
