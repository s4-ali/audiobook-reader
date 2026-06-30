import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/manifest.dart';

/// A book that lives on the device: its parsed manifest + the directory holding the
/// manifest and chapter MP3s (same flat layout the desktop serves).
class InstalledBook {
  final Book book;
  final Directory dir;
  const InstalledBook(this.book, this.dir);

  /// Absolute path to a chapter's audio file.
  String chapterPath(Chapter ch) => '${dir.path}/${ch.audio}';
}

/// Manages the on-device library under `<app documents>/books/<book-id>/`.
class LibraryStore {
  Directory? _root;

  Future<Directory> _booksRoot() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/books');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _root = root;
    return root;
  }

  Future<Directory> bookDir(String bookId) async =>
      Directory('${(await _booksRoot()).path}/$bookId');

  Future<bool> isInstalled(String bookId) async =>
      File('${(await bookDir(bookId)).path}/manifest.json').existsSync();

  /// Every installed book, sorted by title. Unreadable directories are skipped.
  Future<List<InstalledBook>> list() async {
    final root = await _booksRoot();
    final books = <InstalledBook>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final mf = File('${entity.path}/manifest.json');
      if (!mf.existsSync()) continue;
      try {
        books.add(InstalledBook(Book.parse(await mf.readAsString()), entity));
      } catch (_) {
        // Skip a corrupt/half-written book rather than failing the whole list.
      }
    }
    books.sort((a, b) =>
        a.book.title.toLowerCase().compareTo(b.book.title.toLowerCase()));
    return books;
  }

  Future<void> delete(String bookId) async {
    final dir = await bookDir(bookId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
