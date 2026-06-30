import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/library_store.dart';
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
  List<InstalledBook>? _books;

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryStore>();
    _transfer = context.read<Transfer>();
    _load();
  }

  Future<void> _load() async {
    final books = await _lib.list();
    if (mounted) setState(() => _books = books);
  }

  Future<void> _connect() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const BrowseScreen()));
    await _load();
  }

  Future<void> _open(InstalledBook b) async {
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReaderScreen(installed: b)));
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
              : RefreshIndicator(
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
          ],
        ),
      ),
    );
  }
}
