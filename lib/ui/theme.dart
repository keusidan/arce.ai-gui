import 'package:flutter/material.dart';

/// Design tokens of the ARCE.AI interface (light and dark), one set per theme.
@immutable
class ArceColors extends ThemeExtension<ArceColors> {
  const ArceColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.accent,
    required this.accent2,
    required this.accentSoft,
    required this.green,
    required this.greenSoft,
    required this.amber,
    required this.amberSoft,
    required this.red,
    required this.nav,
    required this.navText,
    required this.navMuted,
    required this.userBubble,
    required this.assistantBubble,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color ink;
  final Color muted;
  final Color faint;
  final Color line;
  final Color accent;
  final Color accent2;
  final Color accentSoft;
  final Color green;
  final Color greenSoft;
  final Color amber;
  final Color amberSoft;
  final Color red;
  final Color nav;
  final Color navText;
  final Color navMuted;
  final Color userBubble;
  final Color assistantBubble;

  static const light = ArceColors(
    bg: Color(0xFFF6F7FA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF1F3F7),
    surface3: Color(0xFFE9ECF2),
    ink: Color(0xFF1C202B),
    muted: Color(0xFF717988),
    faint: Color(0xFF9BA2AF),
    line: Color(0xFFE4E7ED),
    accent: Color(0xFF5D67E8),
    accent2: Color(0xFF7A82F3),
    accentSoft: Color(0xFFEEF0FF),
    green: Color(0xFF2E9D76),
    greenSoft: Color(0xFFE7F6F0),
    amber: Color(0xFFBD7A1D),
    amberSoft: Color(0xFFFFF4E4),
    red: Color(0xFFC04B52),
    nav: Color(0xFF171920),
    navText: Color(0xFFF5F6FB),
    navMuted: Color(0xFF9298A7),
    userBubble: Color(0xFFE9EBFF),
    assistantBubble: Color(0xFFFFFFFF),
  );

  static const dark = ArceColors(
    bg: Color(0xFF101116),
    surface: Color(0xFF191B22),
    surface2: Color(0xFF20232C),
    surface3: Color(0xFF2B2F3A),
    ink: Color(0xFFF0F1F5),
    muted: Color(0xFFA2A7B3),
    faint: Color(0xFF737A89),
    line: Color(0xFF30333E),
    accent: Color(0xFF8C93FF),
    accent2: Color(0xFFA4A9FF),
    accentSoft: Color(0xFF292B49),
    green: Color(0xFF67C8A0),
    greenSoft: Color(0xFF203A33),
    amber: Color(0xFFE2AD62),
    amberSoft: Color(0xFF3C3021),
    red: Color(0xFFE07A80),
    nav: Color(0xFF0B0C10),
    navText: Color(0xFFF5F6FB),
    navMuted: Color(0xFF858B9B),
    userBubble: Color(0xFF292B49),
    assistantBubble: Color(0xFF191B22),
  );

  @override
  ArceColors copyWith() => this;

  @override
  ArceColors lerp(ThemeExtension<ArceColors>? other, double t) {
    if (other is! ArceColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return ArceColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surface2: l(surface2, other.surface2),
      surface3: l(surface3, other.surface3),
      ink: l(ink, other.ink),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      line: l(line, other.line),
      accent: l(accent, other.accent),
      accent2: l(accent2, other.accent2),
      accentSoft: l(accentSoft, other.accentSoft),
      green: l(green, other.green),
      greenSoft: l(greenSoft, other.greenSoft),
      amber: l(amber, other.amber),
      amberSoft: l(amberSoft, other.amberSoft),
      red: l(red, other.red),
      nav: l(nav, other.nav),
      navText: l(navText, other.navText),
      navMuted: l(navMuted, other.navMuted),
      userBubble: l(userBubble, other.userBubble),
      assistantBubble: l(assistantBubble, other.assistantBubble),
    );
  }
}

extension ArceTheme on BuildContext {
  ArceColors get c => Theme.of(this).extension<ArceColors>()!;
}

/// Noto Sans JP is bundled (see pubspec.yaml); these system fonts only cover what it lacks.
const _fontFamily = 'NotoSansJP';

const _fontFallback = [
  'Noto Sans JP',
  'Noto Sans CJK JP',
  'Hiragino Kaku Gothic ProN',
  'Yu Gothic UI',
  'Meiryo',
];

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? ArceColors.dark : ArceColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: Colors.white,
    secondary: c.accent2,
    onSecondary: Colors.white,
    error: c.red,
    onError: Colors.white,
    surface: c.surface,
    onSurface: c.ink,
    surfaceContainerHighest: c.surface3,
    outline: c.line,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    dividerColor: c.line,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.accent, selectionColor: c.accent.withValues(alpha: .25)),
    scrollbarTheme: const ScrollbarThemeData(thickness: WidgetStatePropertyAll(4)),
    extensions: [c],
  );
}

TextStyle ts(
  BuildContext context,
  double size, {
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? height,
  double? letterSpacing,
  String? family,
}) =>
    TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color ?? context.c.ink,
      height: height,
      letterSpacing: letterSpacing,
      fontFamily: family,
    );
