import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'screens/library_screen.dart';
import 'services/library_store.dart';
import 'services/settings_store.dart';
import 'services/transfer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.audiobook.audiobook_player.audio',
    androidNotificationChannelName: 'Audiobook playback',
    androidNotificationOngoing: true,
  );
  final settings = await SettingsStore.create();
  final library = LibraryStore();
  runApp(AudiobookApp(settings: settings, library: library));
}

class AudiobookApp extends StatelessWidget {
  final SettingsStore settings;
  final LibraryStore library;
  const AudiobookApp({super.key, required this.settings, required this.library});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SettingsStore>.value(value: settings),
        Provider<LibraryStore>.value(value: library),
        Provider<Transfer>(create: (_) => Transfer(library)),
      ],
      child: MaterialApp(
        title: 'Audiobook Player',
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: const LibraryScreen(),
      ),
    );
  }

  ThemeData _theme() {
    const accent = Color(0xFF5b9bd5);
    const bg = Color(0xFF12161c);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(surface: const Color(0xFF1a212b));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      ),
    );
  }
}
