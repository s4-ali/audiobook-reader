import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/library_store.dart';
import '../services/settings_store.dart';
import '../services/storage_access.dart';
import '../services/sync_store.dart';
import '../services/transfer.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/theme_menu.dart';
import 'account_screen.dart';
import 'browse_screen.dart';
import 'reader_screen.dart';

/// Home screen: the grid of books already downloaded to the device, plus the two ways to
/// add more — connect to the desktop server, or import a `.abk` file.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WidgetsBindingObserver {
  late final LibraryStore _lib;
  late final Transfer _transfer;
  late final SyncStore _sync;
  List<InstalledBook>? _books;
  Map<String, SavedPosition> _pos = {}; // book id -> resume point (for cards + "Continue")
  bool _hasStorageAccess = true; // corrected in _init(); avoids a banner flash on first frame
  StreamSubscription<Map<String, Map<String, dynamic>>>? _progressSub;

  AppPalette get _pal => AppPalette.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lib = context.read<LibraryStore>();
    _transfer = context.read<Transfer>();
    _sync = context.read<SyncStore>();
    _sync.addListener(_onSyncChanged); // (re)subscribe when the user signs in/out
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync.removeListener(_onSyncChanged);
    _progressSub?.cancel();
    super.dispose();
  }

  // Auth changed (sign-in / sign-out): start or stop the realtime progress listener.
  void _onSyncChanged() {
    _subscribeRemoteProgress();
    if (_sync.available) _load(); // pull a fresh baseline right after signing in
  }

  /// Follow every book's remote reading position live, so the cards + "Continue" hero reflect what
  /// another device is doing in real time. Newer-by-`updated` wins. Progress lives only in Firestore
  /// (+ its offline cache), so there's nothing to persist here — the cache already holds it.
  void _subscribeRemoteProgress() {
    _progressSub?.cancel();
    _progressSub = null;
    if (!_sync.available) return;
    _progressSub = _sync.allProgressStream().listen((all) {
      final pos = Map<String, SavedPosition>.from(_pos);
      var changed = false;
      all.forEach((bookId, d) {
        final remoteUpd = (d['updated'] as num?)?.toInt() ?? 0;
        if (remoteUpd <= (pos[bookId]?.updated ?? 0)) return;
        pos[bookId] = SavedPosition.fromRemote(d);
        changed = true;
      });
      if (changed && mounted) setState(() => _pos = pos);
    }, onError: (_) {/* e.g. permission revoked on sign-out — keep what we have */});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may grant "All files access" in system settings and return here — pick that up.
    if (state == AppLifecycleState.resumed && !_hasStorageAccess) _recheckAccess();
  }

  /// Resolve the books folder (no prompt) and load. [_hasStorageAccess] drives the grant banner.
  Future<void> _init() async {
    final has = await StorageAccess.hasAccess();
    await _lib.init();
    if (mounted) setState(() => _hasStorageAccess = has);
    await _load();
    _subscribeRemoteProgress();
  }

  /// Prompt for "All files access"; on grant, switch the library from the app-internal fallback
  /// to the persistent shared folder (migrating any already-downloaded books) and reload.
  Future<void> _grantAccess() async {
    await StorageAccess.requestAccess();
    if (await StorageAccess.hasAccess()) _lib.reset();
    await _init();
  }

  Future<void> _recheckAccess() async {
    if (await StorageAccess.hasAccess()) {
      _lib.reset();
      await _init();
    }
  }

  Future<void> _load() async {
    final books = await _lib.list();
    // Resume points come only from Firestore, read cache-first so it's instant and works offline
    // (the on-disk cache is the local source of truth — there's no progress file). The realtime
    // allProgressStream listener then keeps these live.
    final pos = <String, SavedPosition>{};
    if (_sync.available) {
      for (final b in books) {
        try {
          final r = await _sync.readProgress(b.book.id);
          if (r != null) pos[b.book.id] = SavedPosition.fromRemote(r);
        } catch (_) {/* skip this book's card progress */}
      }
    }
    if (mounted) {
      setState(() {
        _books = books;
        _pos = pos;
      });
    }
  }

  Future<void> _account() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const AccountScreen()));
    await _load(); // a sign-in may have changed the resume points
  }

  /// The most recently played, not-yet-finished book — surfaced as the "Continue" card.
  InstalledBook? _continueBook() {
    final books = _books;
    if (books == null) return null;
    InstalledBook? best;
    SavedPosition? bestPos;
    for (final b in books) {
      final p = _pos[b.book.id];
      if (p == null || p.finished) continue;
      if (bestPos == null || p.updated > bestPos.updated) {
        best = b;
        bestPos = p;
      }
    }
    return best;
  }

  Future<void> _connect() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const BrowseScreen()));
    await _load();
  }

  Future<void> _open(InstalledBook b, {bool autoplay = false}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(installed: b, autoplay: autoplay)));
    await _load();
  }

  Future<void> _import() async {
    // Capture the messenger before the async gap so no BuildContext is used after it.
    final messenger = ScaffoldMessenger.of(context);
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['abk', 'zip'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    messenger.showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 16),
        Text('Importing…'),
      ]),
      duration: Duration(minutes: 10),
    ));
    try {
      final book = await _transfer.importFromFile(path);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
          SnackBar(content: Text('Imported “${book.book.title}”')));
      await _load();
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<void> _delete(InstalledBook b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${b.book.title}”?'),
        content: const Text('This removes the audio from this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await _lib.delete(b.book.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    final cont = _continueBook();
    final sync = context.watch<SyncStore>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audiobooks'),
        actions: [
          const ThemeMenuButton(),
          IconButton(
              onPressed: _account,
              icon: Icon(sync.signedInWithAccount ? Icons.cloud_done : Icons.cloud_outlined),
              tooltip: 'Cloud sync'),
          IconButton(
              onPressed: _connect,
              icon: const Icon(Icons.wifi),
              tooltip: 'Connect to server'),
          IconButton(
              onPressed: _import,
              icon: const Icon(Icons.file_open),
              tooltip: 'Import .abk file'),
        ],
      ),
      body: books == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (!_hasStorageAccess) _accessBanner(),
                Expanded(
                  child: books.isEmpty
                      ? _empty()
                      : Column(
                          children: [
                            if (cont != null) _continueCard(cont),
                            Expanded(
                              child: RefreshIndicator(
                                onRefresh: _load,
                                child: GridView.builder(
                                  padding: const EdgeInsets.all(14),
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 220,
                                    childAspectRatio: 0.70,
                                    crossAxisSpacing: 14,
                                    mainAxisSpacing: 14,
                                  ),
                                  itemCount: books.length,
                                  itemBuilder: (_, i) => _card(books[i]),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  /// Shown when "All files access" hasn't been granted: books currently live in app-internal
  /// storage (wiped on uninstall). Tapping Grant opens the system permission screen.
  Widget _accessBanner() {
    return Material(
      color: _pal.surface0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            const Icon(Icons.folder_off_outlined, color: cYellow, size: 22),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Grant “All files access” to keep books in a folder that survives reinstalls and '
                'is visible in your file manager. Until then they’re app-private and lost on uninstall.',
                style: TextStyle(fontSize: 12.5, height: 1.35),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(onPressed: _grantAccess, child: const Text('Grant')),
          ],
        ),
      ),
    );
  }

  Widget _continueCard(InstalledBook b) {
    final p = _pos[b.book.id]!;
    final total = b.book.chapters.length;
    final ci = total == 0 ? 0 : p.chapterIndex.clamp(0, total - 1);
    final pct = (p.frac * 100).clamp(0, 100).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: InkWell(
        onTap: () => _open(b, autoplay: true),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: _pal.surface0,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            border: Border(left: BorderSide(color: _pal.accent, width: 3)),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _pal.mantle,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.menu_book, color: _pal.subtext0),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('CONTINUE LISTENING',
                        style: TextStyle(
                            color: _pal.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: .5)),
                    const SizedBox(height: 3),
                    Text(b.book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text('Chapter ${ci + 1} of ${b.book.chaptersTotal} · $pct%',
                        style: TextStyle(color: _pal.subtext0, fontSize: 12)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: p.frac.clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: _pal.base,
                        color: _pal.accent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () => _open(b, autoplay: true),
                child: const Text('Resume'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_book, size: 64),
              const SizedBox(height: 16),
              const Text('No audiobooks yet', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              const Text(
                'Connect to your computer over Wi-Fi, or import a .abk package.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.icon(
                      onPressed: _connect,
                      icon: const Icon(Icons.wifi),
                      label: const Text('Connect')),
                  OutlinedButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.file_open),
                      label: const Text('Import')),
                ],
              ),
              if (_hasStorageAccess && _lib.rootPath != null) ...[
                const SizedBox(height: 22),
                Text('Or drop a book folder into',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _pal.subtext0, fontSize: 11)),
                const SizedBox(height: 2),
                Text('${_lib.rootPath}/',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: _pal.subtext0,
                        fontSize: 11,
                        fontFamily: 'monospace')),
                Text('— it’s auto-discovered here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _pal.subtext0, fontSize: 11)),
              ],
            ],
          ),
        ),
      );

  Widget _card(InstalledBook b) {
    final book = b.book;
    final p = _pos[book.id];
    return InkWell(
      onTap: () => _open(b),
      onLongPress: () => _delete(b),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: _pal.surface0,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: _pal.mantle,
                ),
                child: Center(
                    child: Icon(Icons.menu_book, size: 38, color: _pal.subtext0)),
              ),
            ),
            const SizedBox(height: 10),
            Text(book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(book.author.isEmpty ? 'Unknown' : book.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _pal.subtext0, fontSize: 12)),
            const SizedBox(height: 4),
            Text('${book.chaptersTotal} ch · ${fmtHm(book.totalDuration)}',
                style: TextStyle(color: _pal.subtext0, fontSize: 11)),
            if (p != null && p.frac > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: p.frac.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: _pal.base,
                  color: p.finished ? cGreen : _pal.accent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
