import 'package:flutter/material.dart';

import '../theme.dart';
import 'settings_store.dart';

/// Holds the active reader theme and swaps it live. Mirrors the web player's Display-menu theme
/// toggle: the choice persists (via [SettingsStore.themeId], like the web `abk:theme`) and
/// applies app-wide by rebuilding [MaterialApp.theme]. A [ChangeNotifier] so the `MaterialApp`
/// (and the picker's checkmark) rebuild on change.
class ThemeController extends ChangeNotifier {
  final SettingsStore _settings;
  ThemeController(this._settings);

  String get id => _settings.themeId;

  AppPalette get palette => themePalettes[id] ?? mochaPalette;

  ThemeData get themeData => buildTheme(palette);

  void select(String themeId) {
    if (themeId == id || !themePalettes.containsKey(themeId)) return;
    _settings.themeId = themeId;
    notifyListeners();
  }
}
