import 'package:flutter/foundation.dart';

import 'json_store.dart';

enum ThemeChoice { system, light, dark }

@immutable
class Settings {
  const Settings({
    required this.deviceName,
    this.visible = true,
    this.saveDir,
    this.theme = ThemeChoice.system,
    this.keepInBackground = true,
    this.launchAtLogin = true,
    this.revealAutomatically = false,
    this.onboarded = false,
    this.promptsShown = const {},
  });

  final String deviceName;
  final bool visible;

  /// Custom save folder (desktop path). Null = the platform default (US-007).
  final String? saveDir;
  final ThemeChoice theme;
  final bool keepInBackground;
  final bool launchAtLogin;
  final bool revealAutomatically;
  final bool onboarded;

  /// One-time prompts already shown, e.g. `notifications`, `linux_close`.
  final Set<String> promptsShown;

  Settings copyWith({
    String? deviceName,
    bool? visible,
    String? saveDir,
    bool clearSaveDir = false,
    ThemeChoice? theme,
    bool? keepInBackground,
    bool? launchAtLogin,
    bool? revealAutomatically,
    bool? onboarded,
    Set<String>? promptsShown,
  }) => Settings(
    deviceName: deviceName ?? this.deviceName,
    visible: visible ?? this.visible,
    saveDir: clearSaveDir ? null : (saveDir ?? this.saveDir),
    theme: theme ?? this.theme,
    keepInBackground: keepInBackground ?? this.keepInBackground,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    revealAutomatically: revealAutomatically ?? this.revealAutomatically,
    onboarded: onboarded ?? this.onboarded,
    promptsShown: promptsShown ?? this.promptsShown,
  );

  Map<String, Object?> toJson() => {
    'deviceName': deviceName,
    'visible': visible,
    'saveDir': saveDir,
    'theme': theme.name,
    'keepInBackground': keepInBackground,
    'launchAtLogin': launchAtLogin,
    'revealAutomatically': revealAutomatically,
    'onboarded': onboarded,
    'promptsShown': promptsShown.toList(),
  };

  static Settings fromJson(Map<String, Object?> j, Settings defaults) => Settings(
    deviceName: j['deviceName'] is String ? j['deviceName']! as String : defaults.deviceName,
    visible: j['visible'] is bool ? j['visible']! as bool : defaults.visible,
    saveDir: j['saveDir'] is String ? j['saveDir'] as String : null,
    theme: ThemeChoice.values.firstWhere((t) => t.name == j['theme'], orElse: () => defaults.theme),
    keepInBackground: j['keepInBackground'] is bool ? j['keepInBackground']! as bool : defaults.keepInBackground,
    launchAtLogin: j['launchAtLogin'] is bool ? j['launchAtLogin']! as bool : defaults.launchAtLogin,
    revealAutomatically: j['revealAutomatically'] is bool ? j['revealAutomatically']! as bool : false,
    onboarded: j['onboarded'] is bool ? j['onboarded']! as bool : false,
    promptsShown: j['promptsShown'] is List ? (j['promptsShown']! as List).whereType<String>().toSet() : const {},
  );
}

class SettingsStore extends ChangeNotifier {
  SettingsStore(this._file, this._value);

  final JsonFile _file;
  Settings _value;

  Settings get value => _value;

  static Future<SettingsStore> load(JsonFile file, Settings defaults) async {
    final j = await file.read();
    return SettingsStore(file, j == null ? defaults : Settings.fromJson(j, defaults));
  }

  Future<void> update(Settings Function(Settings) change) async {
    _value = change(_value);
    notifyListeners();
    await _file.write(_value.toJson());
  }

  Future<void> markPromptShown(String key) =>
      update((s) => s.copyWith(promptsShown: {...s.promptsShown, key}));
}
