import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/library_store.dart';
import '../services/settings_store.dart';
import '../services/transfer.dart';
import '../theme.dart';
import '../util.dart';
import 'browse_screen.dart';
import 'reader_screen.dart';

/// Home screen: the grid of books already downloaded to the device, plus the two ways to
/// add more — connect to the desktop server, or import a `.abk` file.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final LibraryStore _lib;
  late final Transfer _transfer;
  late final SettingsStore _settings;
  List<InstalledBook>? _books;
  Map<String, SavedPosition> _pos = {}; // book id -> resume point (for cards + "Continue")

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryStore>();
    _transfer = context.read<Transfer>();
    _settings = context.read<SettingsStore>();
    _load();
  }

  Future<void> _load() async {
    final books = await _lib.list();
    final pos = <String, SavedPosition>{};
    for (final b in books) {
      final p = _settings.loadPosition(b.book.id);
      if (p != null) pos[b.book.id] = p;
    }
    if (mounted) {
      setState(() {
        _books = books;
        _pos = pos;
      });
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audiobooks'),
        actions: [
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
          : books.isEmpty
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
          decoration: const BoxDecoration(
            color: cSurface0,
            borderRadius: BorderRadius.all(Radius.circular(12)),
            border: Border(left: BorderSide(color: cMauve, width: 3)),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: cMantle,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.menu_book, color: cSubtext0),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('CONTINUE LISTENING',
                        style: TextStyle(
                            color: cMauve,
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
                        style: const TextStyle(color: cSubtext0, fontSize: 12)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: p.frac.clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: cBase,
                        color: cMauve,
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
          color: cSurface0,
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
                  color: cMantle,
                ),
                child: const Center(
                    child: Icon(Icons.menu_book, size: 38, color: cSubtext0)),
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
                style: const TextStyle(color: cSubtext0, fontSize: 12)),
            const SizedBox(height: 4),
            Text('${book.chaptersTotal} ch · ${fmtMinutes(book.totalDuration)}',
                style: const TextStyle(color: cSubtext0, fontSize: 11)),
            if (p != null && p.frac > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: p.frac.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: cBase,
                  color: p.finished ? cGreen : cMauve,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
