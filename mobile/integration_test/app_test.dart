// End-to-end test on a real Android device/emulator: download a packaged book from the
// desktop server over the LAN (host reachable at 10.0.2.2 from an AVD), extract it, then
// play it and confirm the position + active-sentence highlight advance.
//
// Requires the desktop server running and reachable, serving a ready book with the id
// below (e.g. ingest the bundled sample with --engine dummy):
//   HOST=0.0.0.0 ./scripts/run.sh
// Run with (override the URL/port for your setup; 10.0.2.2 is the AVD's host alias):
//   flutter test integration_test/app_test.dart -d <emulator-id> \
//     --dart-define=SERVER_URL=http://10.0.2.2:8000
import 'package:audiobook_player/main.dart';
import 'package:audiobook_player/services/library_store.dart';
import 'package:audiobook_player/services/player_controller.dart';
import 'package:audiobook_player/services/settings_store.dart';
import 'package:audiobook_player/services/sync_store.dart';
import 'package:audiobook_player/services/theme_controller.dart';
import 'package:audiobook_player/services/transfer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_background/just_audio_background.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const serverUrl = String.fromEnvironment('SERVER_URL',
      defaultValue: 'http://10.0.2.2:8000'); // AVD alias for the host machine
  const bookId = 'the-light-without-a-keeper';

  setUpAll(() async {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.audiobook.audiobook_player.test',
      androidNotificationChannelName: 'Test playback',
    );
  });

  testWidgets('LAN download -> extract -> play -> highlight advances',
      (tester) async {
    final library = LibraryStore();
    final transfer = Transfer(library);
    final settings = await SettingsStore.create();

    // Start clean so we exercise a real download + extract.
    await library.delete(bookId);
    settings.clearPosition(bookId);

    // 1) Download the .abk from the desktop server and extract it on-device.
    var lastProgress = 0.0;
    final installed = await transfer.downloadAndInstall(
      serverUrl,
      bookId,
      onProgress: (p) => lastProgress = p,
    );
    expect(lastProgress, greaterThan(0));
    expect(installed.book.id, bookId);
    expect(installed.book.chapters, isNotEmpty);
    expect(await library.isInstalled(bookId), isTrue);

    // 2) Load the audio and play.
    final controller = PlayerController(installed, settings);
    await controller.init();
    expect(controller.ready, isTrue);
    expect(controller.hasAudio, isTrue);

    await controller.play();
    await Future<void>.delayed(const Duration(seconds: 4));
    await tester.pump();

    expect(controller.position.inMilliseconds, greaterThan(0),
        reason: 'playback position should advance');
    expect(controller.activeSentenceIndex, greaterThanOrEqualTo(0),
        reason: 'a sentence should be highlighted during playback');

    // 3) Seek to a later sentence the way the UI does (tap / search / outline).
    final ch = controller.currentChapter!;
    if (ch.sentences.length > 2) {
      final target = ch.sentences[2];
      await controller.goTo(controller.currentChapterIndex,
          atSeconds: target.s);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
      expect(
        controller.position.inMilliseconds,
        greaterThanOrEqualTo((target.s * 1000).round() - 700),
        reason: 'seeking to a sentence should move playback there',
      );
    }

    controller.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('UI: library lists the book and opens the reader',
      (tester) async {
    final library = LibraryStore();
    final settings = await SettingsStore.create();
    if (!await library.isInstalled(bookId)) {
      await Transfer(library).downloadAndInstall(serverUrl, bookId);
    }

    await tester.pumpWidget(AudiobookApp(
        settings: settings,
        library: library,
        sync: SyncStore(settings, enabled: false),
        theme: ThemeController(settings)));
    // No pumpAndSettle: loading spinners are infinite animations that never settle.
    await tester.pump();
    await Future<void>.delayed(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Audiobooks'), findsOneWidget);
    expect(find.text('The Light Without a Keeper'), findsWidgets);

    await tester.tap(find.text('The Light Without a Keeper').first);
    await tester.pump(); // start navigation
    await Future<void>.delayed(const Duration(seconds: 2)); // reader init + load
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
