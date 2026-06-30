import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/manifest.dart';
import 'library_store.dart';

/// A book as advertised by the desktop server's `/api/library` (lightweight summary).
class RemoteBook {
  final String id;
  final String title;
  final String author;
  final String status; // ready | generating | partial | cancelled
  final double duration;
  final int nChapters;

  const RemoteBook({
    required this.id,
    required this.title,
    required this.author,
    required this.status,
    required this.duration,
    required this.nChapters,
  });

  bool get isReady => status == 'ready';

  factory RemoteBook.fromJson(Map<String, dynamic> j) => RemoteBook(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? j['id'] ?? 'Untitled') as String,
        author: (j['author'] ?? '') as String,
        status: (j['status'] ?? 'ready') as String,
        duration: ((j['duration'] ?? 0) as num).toDouble(),
        nChapters: ((j['n_chapters'] ?? 0) as num).toInt(),
      );
}

/// Gets books onto the device two ways — LAN download from the desktop server and import
/// of a local `.abk` file — then extracts both through the same install path.
class Transfer {
  final LibraryStore library;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(minutes: 30), // big books over Wi-Fi
  ));

  Transfer(this.library);

  /// Normalize user input into a base URL: add a scheme if missing, drop trailing slash.
  static String normalizeUrl(String input) {
    var u = input.trim();
    if (u.isEmpty) throw const FormatException('Enter a server address');
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  Future<List<RemoteBook>> fetchLibrary(String serverUrl) async {
    final res = await _dio.get<Map<String, dynamic>>('$serverUrl/api/library');
    final books = (res.data?['books'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return books.map(RemoteBook.fromJson).toList();
  }

  /// Download `<id>.abk` from the server and install it. `onProgress` is 0..1 across the
  /// whole operation (download then extract).
  Future<InstalledBook> downloadAndInstall(
    String serverUrl,
    String bookId, {
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await getTemporaryDirectory();
    final abk = File('${tmp.path}/$bookId.abk');
    await _dio.download(
      '$serverUrl/api/books/$bookId/package',
      abk.path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total * 0.9);
      },
    );
    try {
      return await _installFromAbk(
        abk,
        onProgress: (x) => onProgress?.call(0.9 + x * 0.1),
      );
    } finally {
      if (await abk.exists()) await abk.delete();
    }
  }

  /// Install a `.abk` (or `.zip`) the user picked from device storage.
  Future<InstalledBook> importFromFile(
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    return _installFromAbk(File(filePath), onProgress: onProgress);
  }

  /// Extract an `.abk` to a staging dir, read its manifest id, then move it into place at
  /// `books/<id>/` (replacing any previous copy).
  Future<InstalledBook> _installFromAbk(
    File abk, {
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await getTemporaryDirectory();
    final staging = Directory(
        '${tmp.path}/abk_stage_${DateTime.now().millisecondsSinceEpoch}');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    await ZipFile.extractToDirectory(
      zipFile: abk,
      destinationDir: staging,
      onExtracting: (entry, progress) {
        onProgress?.call(progress / 100.0);
        return ZipFileOperation.includeItem;
      },
    );

    final manifest = File('${staging.path}/manifest.json');
    if (!await manifest.exists()) {
      await staging.delete(recursive: true);
      throw const FormatException(
          'Not a valid audiobook package (no manifest.json inside)');
    }
    final book = Book.parse(await manifest.readAsString());

    final dest = await library.bookDir(book.id);
    if (await dest.exists()) await dest.delete(recursive: true);
    try {
      await staging.rename(dest.path); // fast path: same filesystem
    } on FileSystemException {
      await _copyDir(staging, dest); // fallback: cross-filesystem copy
      await staging.delete(recursive: true);
    }
    return InstalledBook(book, dest);
  }

  static Future<void> _copyDir(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    for (final entity in src.listSync(recursive: false)) {
      if (entity is File) {
        await entity.copy('${dest.path}/${entity.uri.pathSegments.last}');
      }
    }
  }
}
