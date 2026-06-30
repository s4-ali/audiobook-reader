import 'package:flutter/material.dart';

/// Flat Geometric design system — Catppuccin Mocha palette, Mauve accent.
/// Flat only: depth comes from surface-color contrast, not borders/shadows.

// Background / canvas layers
const cCrust = Color(0xFF11111B); // deepest background
const cMantle = Color(0xFF181825); // secondary background
const cBase = Color(0xFF1E1E2E); // default canvas / negative space

// Surface fills (back → front)
const cSurface0 = Color(0xFF313244); // main body fill / raised chrome
const cSurface1 = Color(0xFF45475A); // secondary fill / hover
const cSurface2 = Color(0xFF585B70); // raised elements

// Text
const cOverlay0 = Color(0xFF6C7086); // subtle borders
const cSubtext0 = Color(0xFFA6ADC8); // secondary text
const cText = Color(0xFFCDD6F4); // primary text

// Mauve accent (+ a faint wash for overlays)
const cMauve = Color(0xFFCBA6F7);
const cMauve15 = Color(0x26CBA6F7); // ~15% mauve

// Semantic accents — used only for meaning
const cRed = Color(0xFFF38BA8); // error
const cGreen = Color(0xFFA6E3A1); // success
const cYellow = Color(0xFFF9E2AF); // warning
const cTeal = Color(0xFF94E2D5); // highlight

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: cMauve,
    brightness: Brightness.dark,
  ).copyWith(
    primary: cMauve,
    onPrimary: cCrust,
    secondary: cMauve,
    onSecondary: cCrust,
    error: cRed,
    onError: cCrust,
    surface: cBase,
    onSurface: cText,
    onSurfaceVariant: cSubtext0,
    surfaceContainerLowest: cCrust,
    surfaceContainerLow: cMantle,
    surfaceContainer: cSurface0,
    surfaceContainerHigh: cSurface1,
    surfaceContainerHighest: cSurface2,
    surfaceDim: cMantle,
    surfaceBright: cSurface0,
    outline: cOverlay0,
    outlineVariant: cSurface1,
    inverseSurface: cText,
    onInverseSurface: cCrust,
    inversePrimary: cMauve,
    surfaceTint: Colors.transparent, // flat: no M3 elevation tint
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: cBase,
    canvasColor: cBase,
    // Chrome reads as a raised plane over the base canvas (no border needed).
    appBarTheme: const AppBarThemeData(
      backgroundColor: cSurface0,
      foregroundColor: cText,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      activeTrackColor: cMauve,
      inactiveTrackColor: cBase,
      thumbColor: cMauve,
      overlayColor: cMauve15,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: cSurface2,
      contentTextStyle: TextStyle(color: cText),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      selectedColor: cMauve,
      iconColor: cSubtext0,
      textColor: cText,
    ),
    dividerTheme: const DividerThemeData(color: cSurface1, thickness: 1),
  );
}
