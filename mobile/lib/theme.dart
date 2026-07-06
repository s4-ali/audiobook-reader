import 'package:flutter/material.dart';

/// Flat Geometric design system. Three reader themes mirror the web player's `[data-theme]`
/// palette swap: **dark** (Catppuccin Mocha, the default), **sepia**, and **light**. Only the
/// role tokens below change per theme; depth comes from surface-color contrast, not
/// borders/shadows. The active palette rides on [ThemeData] as an [AppPalette] extension, so
/// switching themes re-themes the whole app (chrome via [ColorScheme], reader spans via
/// [AppPalette.of]).

// ── Note-highlight swatches — theme-independent by design (mirror web --sw-*/--hl-*). ──
const noteSwatchColors = <String, Color>{
  'yellow': Color(0xFFF9E2AF),
  'green': Color(0xFFA6E3A1),
  'blue': Color(0xFF89B4FA),
  'pink': Color(0xFFF38BA8),
  'purple': Color(0xFFCBA6F7),
};

/// The translucent in-text wash for a highlight color (readable over every theme).
Color noteWash(String color) =>
    (noteSwatchColors[color] ?? const Color(0xFFF9E2AF)).withValues(alpha: 0.30);

// ── Semantic accents — used only for meaning; theme-independent (web keeps --green/--red/…
//    fixed across all [data-theme] blocks). ──
const cRed = Color(0xFFF38BA8); // error
const cGreen = Color(0xFFA6E3A1); // success
const cYellow = Color(0xFFF9E2AF); // warning
const cTeal = Color(0xFF94E2D5); // highlight
const cBlue = Color(0xFF89B4FA); // note highlight (blue)

/// The swappable part of the palette — the role tokens the three themes override (the mobile
/// twin of the web `:root[data-theme=…]` custom properties). Carried on [ThemeData] so any
/// widget can read the active theme's colors via [AppPalette.of]. `crust` doubles as "ink on
/// the accent" (dark text on the highlight plane), exactly like the web `--crust`.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  final Brightness brightness;
  final Color crust; // deepest bg / ink on accent
  final Color mantle; // secondary bg
  final Color base; // default canvas / negative space
  final Color surface0; // main body fill (back layer)
  final Color surface1; // secondary fill / hover
  final Color surface2; // raised elements
  final Color overlay0; // subtle borders
  final Color subtext0; // secondary text
  final Color text; // primary text
  final Color accent; // mauve accent
  final Color accentWash; // ~15% accent (overlays)

  const AppPalette({
    required this.brightness,
    required this.crust,
    required this.mantle,
    required this.base,
    required this.surface0,
    required this.surface1,
    required this.surface2,
    required this.overlay0,
    required this.subtext0,
    required this.text,
    required this.accent,
    required this.accentWash,
  });

  /// The active theme's palette (falls back to Mocha if the extension is somehow absent).
  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? mochaPalette;

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? crust,
    Color? mantle,
    Color? base,
    Color? surface0,
    Color? surface1,
    Color? surface2,
    Color? overlay0,
    Color? subtext0,
    Color? text,
    Color? accent,
    Color? accentWash,
  }) =>
      AppPalette(
        brightness: brightness ?? this.brightness,
        crust: crust ?? this.crust,
        mantle: mantle ?? this.mantle,
        base: base ?? this.base,
        surface0: surface0 ?? this.surface0,
        surface1: surface1 ?? this.surface1,
        surface2: surface2 ?? this.surface2,
        overlay0: overlay0 ?? this.overlay0,
        subtext0: subtext0 ?? this.subtext0,
        text: text ?? this.text,
        accent: accent ?? this.accent,
        accentWash: accentWash ?? this.accentWash,
      );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      crust: Color.lerp(crust, other.crust, t)!,
      mantle: Color.lerp(mantle, other.mantle, t)!,
      base: Color.lerp(base, other.base, t)!,
      surface0: Color.lerp(surface0, other.surface0, t)!,
      surface1: Color.lerp(surface1, other.surface1, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      overlay0: Color.lerp(overlay0, other.overlay0, t)!,
      subtext0: Color.lerp(subtext0, other.subtext0, t)!,
      text: Color.lerp(text, other.text, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentWash: Color.lerp(accentWash, other.accentWash, t)!,
    );
  }
}

/// Dark — Catppuccin Mocha (the app's original, default look).
const mochaPalette = AppPalette(
  brightness: Brightness.dark,
  crust: Color(0xFF11111B),
  mantle: Color(0xFF181825),
  base: Color(0xFF1E1E2E),
  surface0: Color(0xFF313244),
  surface1: Color(0xFF45475A),
  surface2: Color(0xFF585B70),
  overlay0: Color(0xFF6C7086),
  subtext0: Color(0xFFA6ADC8),
  text: Color(0xFFCDD6F4),
  accent: Color(0xFFCBA6F7),
  accentWash: Color(0x26CBA6F7), // ~15%
);

/// Sepia — warm paper (mirrors web `:root[data-theme="sepia"]`).
const sepiaPalette = AppPalette(
  brightness: Brightness.light,
  crust: Color(0xFFF7F0E1), // ink on accent
  mantle: Color(0xFFECE0C4),
  base: Color(0xFFF3E9D2),
  surface0: Color(0xFFE8DABB),
  surface1: Color(0xFFDDCCA7),
  surface2: Color(0xFFCFBA8D),
  overlay0: Color(0xFFB6A17C), // web has no sepia border token — a muted paper edge
  subtext0: Color(0xFF6F5C41),
  text: Color(0xFF3A2D1C),
  accent: Color(0xFF9A5A2B),
  accentWash: Color(0x249A5A2B), // ~14%
);

/// Light (mirrors web `:root[data-theme="light"]`).
const lightPalette = AppPalette(
  brightness: Brightness.light,
  crust: Color(0xFFFFFFFF), // ink on accent
  mantle: Color(0xFFECEFF4),
  base: Color(0xFFFFFFFF),
  surface0: Color(0xFFF2F3F8),
  surface1: Color(0xFFE4E7EF),
  surface2: Color(0xFFD6DAE6),
  overlay0: Color(0xFFC3C8D6), // web has no light border token — a faint grey edge
  subtext0: Color(0xFF6C7086),
  text: Color(0xFF1E2030),
  accent: Color(0xFF8839EF),
  accentWash: Color(0x1F8839EF), // ~12%
);

/// Theme id → palette. Ids mirror the web player's `abk:theme` values.
const themePalettes = <String, AppPalette>{
  'dark': mochaPalette,
  'sepia': sepiaPalette,
  'light': lightPalette,
};

/// Display metadata for the theme picker (order matches the web display menu).
const themeChoices = <({String id, String label, IconData icon})>[
  (id: 'dark', label: 'Dark', icon: Icons.dark_mode_outlined),
  (id: 'sepia', label: 'Sepia', icon: Icons.wb_sunny_outlined),
  (id: 'light', label: 'Light', icon: Icons.light_mode_outlined),
];

ThemeData buildTheme(AppPalette p) {
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: p.brightness,
  ).copyWith(
    primary: p.accent,
    onPrimary: p.crust,
    secondary: p.accent,
    onSecondary: p.crust,
    error: cRed,
    onError: p.crust,
    surface: p.base,
    onSurface: p.text,
    onSurfaceVariant: p.subtext0,
    surfaceContainerLowest: p.crust,
    surfaceContainerLow: p.mantle,
    surfaceContainer: p.surface0,
    surfaceContainerHigh: p.surface1,
    surfaceContainerHighest: p.surface2,
    surfaceDim: p.mantle,
    surfaceBright: p.surface0,
    outline: p.overlay0,
    outlineVariant: p.surface1,
    inverseSurface: p.text,
    onInverseSurface: p.crust,
    inversePrimary: p.accent,
    surfaceTint: Colors.transparent, // flat: no M3 elevation tint
  );

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.base,
    canvasColor: p.base,
    extensions: [p],
    // Chrome reads as a raised plane over the base canvas (no border needed).
    appBarTheme: AppBarThemeData(
      backgroundColor: p.surface0,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: p.accent,
      inactiveTrackColor: p.base,
      thumbColor: p.accent,
      overlayColor: p.accentWash,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surface2,
      contentTextStyle: TextStyle(color: p.text),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: ListTileThemeData(
      selectedColor: p.accent,
      iconColor: p.subtext0,
      textColor: p.text,
    ),
    dividerTheme: DividerThemeData(color: p.surface1, thickness: 1),
  );
}
