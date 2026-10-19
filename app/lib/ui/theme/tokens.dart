// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// Colour tokens from `product/04-design/final/assets/tokens.css` (purple, D-014).
const kfLight = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF6741D9),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFEEE9FC),
  onPrimaryContainer: Color(0xFF5532C0),
  secondary: Color(0xFF56535E),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFEEE9FC),
  onSecondaryContainer: Color(0xFF5532C0),
  tertiary: Color(0xFF8F5600),
  onTertiary: Color(0xFFFFFFFF),
  error: Color(0xFFB42318),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFDE7E5),
  onErrorContainer: Color(0xFFB42318),
  surface: Color(0xFFF4F3F7),
  onSurface: Color(0xFF17151C),
  onSurfaceVariant: Color(0xFF56535E),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF8F7FA),
  surfaceContainer: Color(0xFFF0EEF4),
  surfaceContainerHigh: Color(0xFFECEAF1),
  surfaceContainerHighest: Color(0xFFE6E3EC),
  outline: Color(0xFF918E99),
  outlineVariant: Color(0x1F17151C),
  inverseSurface: Color(0xFF2E2B35),
  onInverseSurface: Color(0xFFF3F1F7),
  inversePrimary: Color(0xFFC9B8FF),
  shadow: Color(0xFF100F14),
  scrim: Color(0x730E0C14),
  surfaceTint: Color(0x00000000),
);

const kfDark = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFB39DFF),
  onPrimary: Color(0xFF1C0F45),
  primaryContainer: Color(0xFF2A2145),
  onPrimaryContainer: Color(0xFFC9B8FF),
  secondary: Color(0xFFA8A4B1),
  onSecondary: Color(0xFF131217),
  secondaryContainer: Color(0xFF2A2145),
  onSecondaryContainer: Color(0xFFC9B8FF),
  tertiary: Color(0xFFF2B35B),
  onTertiary: Color(0xFF33270F),
  error: Color(0xFFFF8A80),
  onError: Color(0xFF3A0703),
  errorContainer: Color(0xFF3A1714),
  onErrorContainer: Color(0xFFFF8A80),
  surface: Color(0xFF131217),
  onSurface: Color(0xFFECEAF1),
  onSurfaceVariant: Color(0xFFA8A4B1),
  surfaceContainerLowest: Color(0xFF1D1B22),
  surfaceContainerLow: Color(0xFF24222A),
  surfaceContainer: Color(0xFF27252D),
  surfaceContainerHigh: Color(0xFF2D2A33),
  surfaceContainerHighest: Color(0xFF33303A),
  outline: Color(0xFF75717E),
  outlineVariant: Color(0x1AFFFFFF),
  inverseSurface: Color(0xFFECEAF1),
  onInverseSurface: Color(0xFF17151C),
  inversePrimary: Color(0xFF6741D9),
  shadow: Color(0xFF000000),
  scrim: Color(0x99000000),
  surfaceTint: Color(0x00000000),
);

/// Semantic colours Material 3 has no slot for.
@immutable
class KfColors extends ThemeExtension<KfColors> {
  const KfColors({
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.kick,
    required this.textTertiary,
  });

  static const light = KfColors(
    success: Color(0xFF1B7A3A),
    successSoft: Color(0xFFE3F3E8),
    warning: Color(0xFF8F5600),
    warningSoft: Color(0xFFFBEFD9),
    kick: Color(0xFFFF6B4A),
    textTertiary: Color(0xFF67646F),
  );

  static const dark = KfColors(
    success: Color(0xFF5BD08A),
    successSoft: Color(0xFF13301F),
    warning: Color(0xFFF2B35B),
    warningSoft: Color(0xFF33270F),
    kick: Color(0xFFFF7F61),
    textTertiary: Color(0xFF928E9B),
  );

  final Color success, successSoft, warning, warningSoft, kick, textTertiary;

  static KfColors of(BuildContext context) => Theme.of(context).extension<KfColors>()!;

  @override
  KfColors copyWith() => this;

  @override
  KfColors lerp(KfColors? o, double t) => o == null
      ? this
      : KfColors(
          success: Color.lerp(success, o.success, t)!,
          successSoft: Color.lerp(successSoft, o.successSoft, t)!,
          warning: Color.lerp(warning, o.warning, t)!,
          warningSoft: Color.lerp(warningSoft, o.warningSoft, t)!,
          kick: Color.lerp(kick, o.kick, t)!,
          textTertiary: Color.lerp(textTertiary, o.textTertiary, t)!,
        );
}

abstract final class KfSpace {
  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 20.0, s6 = 24.0, s8 = 32.0, s10 = 40.0;
  static const gutter = 16.0;
}

abstract final class KfRadius {
  static const xs = 6.0, sm = 10.0, md = 12.0, lg = 16.0, xl = 22.0;
}

abstract final class KfMotion {
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 320);
  static const kick = Duration(milliseconds: 520);
  static const standard = Cubic(.2, 0, 0, 1);
  static const enter = Cubic(.05, .7, .1, 1);
  static const exit = Cubic(.3, 0, .8, .15);
  static const kickBump = Cubic(.34, 1.4, .64, 1);

  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}
