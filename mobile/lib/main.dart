import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'screens/library_screen.dart';
import 'services/library_store.dart';
import 'services/notes_store.dart';
import 'services/settings_store.dart';
import 'services/sync_store.dart';
import 'services/theme_controller.dart';
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
  // Cloud sync init — guarded so any config/init problem (or no network at launch) never blocks
  // startup. Uses the FlutterFire-generated firebase_options.dart (`flutterfire configure`).
  // SyncStore signs in anonymously on first launch so there's always a uid: reading progress +
  // notes are Firestore-backed (via the offline cache set below) even before the user signs in
  // with an email account, which later links to this same anonymous uid.
  var firebaseReady = false;
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
    // Reading progress now lives *only* in Firestore's on-disk cache (there is no local progress
    // file anymore), so persistence is what keeps resume + karaoke highlighting working offline;
    // writes queue and flush on reconnect. On by default on mobile, but set explicitly since it's
    // the single source of truth. Must run before the first Firestore query.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
    firebaseReady = true;
  } catch (_) {
    firebaseReady = false;
  }
  final sync = SyncStore(settings, enabled: firebaseReady);
  final theme = ThemeController(settings);
  runApp(AudiobookApp(
      settings: settings, library: library, sync: sync, theme: theme));
}

class AudiobookApp extends StatelessWidget {
  final SettingsStore settings;
  final LibraryStore library;
  final SyncStore sync;
  final ThemeController theme;
  const AudiobookApp(
      {super.key,
      required this.settings,
      required this.library,
      required this.sync,
      required this.theme});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SettingsStore>.value(value: settings),
        Provider<LibraryStore>.value(value: library),
        Provider<NotesStore>(create: (_) => NotesStore()),
        Provider<Transfer>(create: (_) => Transfer(library)),
        ChangeNotifierProvider<SyncStore>.value(value: sync),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
      ],
      // Rebuild MaterialApp when the reader theme changes so the swap applies app-wide.
      child: Consumer<ThemeController>(
        builder: (context, theme, _) => MaterialApp(
          title: 'Audiobook Player',
          debugShowCheckedModeBanner: false,
          theme: theme.themeData,
          home: const LibraryScreen(),
        ),
      ),
    );
  }
}
