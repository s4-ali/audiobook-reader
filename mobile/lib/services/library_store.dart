import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manifest.dart';
import 'storage_access.dart';

/// A book that lives on the device: its parsed manifest + the directory holding the
/// manifest and chapter MP3s (same flat layout the desktop serves).
class InstalledBook {
  final Book book;
  final Directory dir;
  const InstalledBook(this.book, this.dir);

  /// Absolute path to a chapter's audio file.
  String chapterPath(Chapter ch) => '${dir.path}/${ch.audio}';
}

/// Manages the on-device library. Books live in a persistent, file-explorer-visible
/// `<shared-storage>/Audiobooks/<book-id>/` folder so they survive an app reinstall and can be
/// added by hand (drop a book folder in → it's auto-discovered by [list]). If storage access
/// hasn't been granted yet, it transparently falls back to app-internal
/// `<app documents>/books/` so the app still works — just without the survives-reinstall
/// guarantee until access is granted.
class LibraryStore {
  Directory? _root;
  bool _usingFallback = false;

  /// True when we couldn't use the persistent shared folder and fell back to app-internal
  /// storage (books there are wiped on uninstall). The UI nudges the user to grant access.
  bool get usingFallback => _usingFallback;

  /// The resolved books-root path (null until first resolved). Shown in the UI so the user knows
  /// where to drop book folders.
  String? get rootPath => _root?.path;

  /// Resolve (and cache) the books root. Prefers the persistent shared Audiobooks folder when we
  /// already hold storage access; otherwise falls back to app-internal storage. Never prompts —
  /// call [StorageAccess.requestAccess] + [reset] to switch to the shared folder after a grant.
  Future<Directory> _booksRoot() async {
    if (_root != null) return _root!;
    Directory? shared;
    if (await StorageAccess.hasAccess()) {
      final path = await StorageAccess.audiobooksPath();
      if (path != null && path.isNotEmpty) {
        final d = Directory(path);
        try {
          if (!await d.exists()) await d.create(recursive: true);
          shared = d;
        } catch (_) {
          // Access granted but the folder can't be created — fall back below.
        }
      }
    }
    if (shared != null) {
      _root = shared;
      _usingFallback = false;
      await _migrateFromInternal(shared);
    } else {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}/books');
      if (!await root.exists()) await root.create(recursive: true);
      _root = root;
      _usingFallback = true;
    }
    return _root!;
  }

  /// Resolve the root now (no permission prompt) so [usingFallback]/[rootPath] are populated.
  Future<void> init() async {
    await _booksRoot();
  }

  /// Forget the cached root so the next access re-resolves it — call after granting storage
  /// access so the library switches from the fallback folder to the shared one.
  void reset() {
    _root = null;
    _usingFallback = false;
  }

  Future<Directory> bookDir(String bookId) async =>
      Directory('${(await _booksRoot()).path}/$bookId');

  Future<bool> isInstalled(String bookId) async =>
      File('${(await bookDir(bookId)).path}/manifest.json').existsSync();

  /// Every installed book, sorted by title. Unreadable directories are skipped. Any folder
  /// containing a `manifest.json` counts — including one the user dropped in by hand, whose
  /// folder name need not match the manifest's id (playback, notes, and progress all key off
  /// the actual [InstalledBook.dir], not the folder name).
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

  /// One-time copy of books from the old app-internal folder into the shared folder, so users
  /// upgrading from a build that stored books internally keep what they already downloaded.
  /// Guarded by a prefs flag; never clobbers an existing book in the destination.
  Future<void> _migrateFromInternal(Directory sharedRoot) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('migratedToShared') ?? false) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final old = Directory('${docs.path}/books');
      if (old.existsSync() && old.path != sharedRoot.path) {
        for (final entity in old.listSync()) {
          if (entity is! Directory) continue;
          if (!File('${entity.path}/manifest.json').existsSync()) continue;
          final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          final dest = Directory('${sharedRoot.path}/$name');
          if (await dest.exists()) continue;
          await _copyDirFlat(entity, dest);
        }
      }
    } catch (_) {
      // Migration is best-effort; a failure just means those books stay internal.
    }
    await prefs.setBool('migratedToShared', true);
  }

  static Future<void> _copyDirFlat(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    for (final entity in src.listSync(recursive: false)) {
      if (entity is File) {
        await entity.copy('${dest.path}/${entity.uri.pathSegments.last}');
      }
    }
  }
}
