import 'package:audiobook_player/services/settings_store.dart';
import 'package:audiobook_player/services/theme_controller.dart';
import 'package:audiobook_player/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verifies the reader-theme system: the three palettes mirror the web player, the default
/// 'dark' reproduces the app's original Catppuccin look byte-for-byte, and the controller
/// persists + notifies on a swap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the three theme ids resolve to their palettes', () {
    expect(themePalettes.keys.toList(), ['dark', 'sepia', 'light']);
    expect(themePalettes['dark'], same(mochaPalette));
    expect(themePalettes['sepia'], same(sepiaPalette));
    expect(themePalettes['light'], same(lightPalette));
  });

  test('dark palette reproduces the original Mocha canvas/accent', () {
    // Guards against a regression in the default look after the const→palette refactor.
    expect(mochaPalette.base, const Color(0xFF1E1E2E));
    expect(mochaPalette.text, const Color(0xFFCDD6F4));
    expect(mochaPalette.accent, const Color(0xFFCBA6F7));
    expect(mochaPalette.brightness, Brightness.dark);
    expect(buildTheme(mochaPalette).scaffoldBackgroundColor, const Color(0xFF1E1E2E));
  });

  test('sepia + light are light-brightness with their web canvas colors', () {
    expect(sepiaPalette.brightness, Brightness.light);
    expect(sepiaPalette.base, const Color(0xFFF3E9D2)); // web --base
    expect(sepiaPalette.accent, const Color(0xFF9A5A2B)); // web --mauve
    expect(lightPalette.brightness, Brightness.light);
    expect(lightPalette.base, const Color(0xFFFFFFFF));
    expect(buildTheme(sepiaPalette).scaffoldBackgroundColor, const Color(0xFFF3E9D2));
    expect(buildTheme(sepiaPalette).brightness, Brightness.light);
  });

  testWidgets('AppPalette.of returns the active theme palette', (tester) async {
    late AppPalette seen;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(sepiaPalette),
      home: Builder(builder: (context) {
        seen = AppPalette.of(context);
        return const SizedBox();
      }),
    ));
    expect(seen, same(sepiaPalette));
  });

  test('ThemeController persists the choice and notifies on real changes', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.create();
    final tc = ThemeController(settings);

    expect(tc.id, 'dark'); // default keeps today's look
    var notifications = 0;
    tc.addListener(() => notifications++);

    tc.select('sepia');
    expect(tc.id, 'sepia');
    expect(settings.themeId, 'sepia'); // persisted like the web abk:theme
    expect(tc.palette, same(sepiaPalette));
    expect(notifications, 1);

    tc.select('sepia'); // no-op: same value
    expect(notifications, 1);

    tc.select('nonsense'); // unknown id ignored
    expect(tc.id, 'sepia');
    expect(notifications, 1);
  });
}
