import 'dart:io';

import 'package:flutter/material.dart';

import 'tokens.dart';

bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

String? get _fontFamily {
  if (Platform.isWindows) return 'Segoe UI Variable';
  if (Platform.isLinux) return 'Adwaita Sans';
  return null; // SF Pro / Roboto from the platform
}

List<String>? get _fontFallback {
  if (Platform.isWindows) return const ['Segoe UI'];
  if (Platform.isLinux) return const ['Cantarell', 'Ubuntu', 'Noto Sans', 'DejaVu Sans'];
  return null;
}

ThemeData kfTheme(Brightness b) {
  final cs = b == Brightness.light ? kfLight : kfDark;
  final kf = b == Brightness.light ? KfColors.light : KfColors.dark;
  final desktop = isDesktop;
  final d = desktop ? 1.0 : 0.0; // desktop body sizes are 1 px smaller

  TextStyle t(double size, double height, FontWeight w, {Color? color, double? spacing}) => TextStyle(
    fontSize: size,
    height: height / size,
    fontWeight: w,
    color: color ?? cs.onSurface,
    letterSpacing: spacing ?? 0,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
  );

  final text = TextTheme(
    headlineSmall: t(28, 34, FontWeight.w700),
    titleLarge: t(22, 28, FontWeight.w700),
    titleMedium: t(17, 22, FontWeight.w600),
    bodyLarge: t(16 - d, 22 - d, FontWeight.w400),
    bodyMedium: t(14, 20, FontWeight.w400, color: cs.onSurfaceVariant),
    bodySmall: t(13 - d, 18 - d, FontWeight.w400, color: cs.onSurfaceVariant),
    labelLarge: t(14, 20, FontWeight.w600),
    labelMedium: t(13, 18, FontWeight.w600),
    labelSmall: t(12, 16, FontWeight.w600, color: kf.textTertiary, spacing: 0.6),
  );

  final shape12 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(KfRadius.md));
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    brightness: b,
    scaffoldBackgroundColor: cs.surface,
    textTheme: text,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
    extensions: [kf],
    visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    materialTapTargetSize: desktop ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
    splashFactory: desktop ? NoSplash.splashFactory : InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: cs.surface,
      foregroundColor: cs.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: cs.surfaceContainerLowest,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KfRadius.md),
        side: BorderSide(color: cs.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1, thickness: 1),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cs.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(KfRadius.xl))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(desktop ? KfRadius.lg : 28)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: cs.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KfRadius.md),
        side: BorderSide(color: cs.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: shape12, textStyle: text.labelLarge, minimumSize: Size(64, desktop ? 36 : 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape12,
        textStyle: text.labelLarge,
        minimumSize: Size(64, desktop ? 36 : 48),
        side: BorderSide(color: cs.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape12, textStyle: text.labelLarge, minimumSize: Size(48, desktop ? 36 : 48)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: cs.inverseSurface,
      contentTextStyle: text.bodyMedium!.copyWith(color: cs.onInverseSurface),
      actionTextColor: cs.inversePrimary,
      behavior: SnackBarBehavior.floating,
      shape: shape12,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cs.surfaceContainerLowest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(KfRadius.sm), borderSide: BorderSide(color: cs.outline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(KfRadius.sm), borderSide: BorderSide(color: cs.outline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(KfRadius.sm), borderSide: BorderSide(color: cs.primary, width: 2)),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? cs.primary : cs.surfaceContainerHigh),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? cs.primary : cs.outline),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      minTileHeight: desktop ? 52 : 64,
      titleTextStyle: text.bodyLarge!.copyWith(fontWeight: FontWeight.w600),
      subtitleTextStyle: text.bodySmall,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: cs.primary,
      linearTrackColor: cs.secondaryContainer,
      circularTrackColor: cs.secondaryContainer,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: cs.inverseSurface, borderRadius: BorderRadius.circular(KfRadius.xs)),
      textStyle: text.bodySmall!.copyWith(color: cs.onInverseSurface),
    ),
  );
}

/// The 6-digit code and short codes: monospace with tabular figures.
TextStyle codeStyle(BuildContext context, {double size = 36}) => TextStyle(
  fontSize: size,
  height: 44 / 36,
  fontWeight: FontWeight.w600,
  letterSpacing: 2,
  fontFamily: Platform.isMacOS
      ? 'Menlo'
      : Platform.isWindows
      ? 'Cascadia Mono'
      : Platform.isAndroid
      ? 'monospace'
      : 'DejaVu Sans Mono',
  fontFamilyFallback: const ['Consolas', 'Roboto Mono', 'monospace'],
  fontFeatures: const [FontFeature.tabularFigures()],
  color: Theme.of(context).colorScheme.onSurface,
);
