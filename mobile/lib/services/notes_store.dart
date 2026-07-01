import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/manifest.dart';
import '../models/note.dart';
import 'library_store.dart';

/// On-device notes for a book: a sibling `notes.json` in `<app docs>/books/<id>/` — the same
/// flat layout and `{book, version, notes:[]}` shape the desktop writes. So a notes file
/// bundled inside an `.abk` loads as-is, and the Markdown/Obsidian exporters below mirror
/// `app/notes.py` output. Persistence is atomic (temp file + rename).
class NotesStore {
  final LibraryStore library;
  NotesStore(this.library);

  static const int version = 1;
  static const List<String> colors = ['yellow', 'green', 'blue', 'pink', 'purple'];

  /// UTC, second precision, `Z` suffix — matches the server so sync compares cleanly.
  static String nowIso() {
    final n = DateTime.now().toUtc();
    final d = DateTime.utc(n.year, n.month, n.day, n.hour, n.minute, n.second);
    return '${d.toIso8601String().split('.').first}Z';
  }

  Future<File> _file(String bookId) async =>
      File('${(await library.bookDir(bookId)).path}/notes.json');

  Future<List<Note>> load(String bookId) async {
    try {
      final f = await _file(bookId);
      if (!await f.exists()) return [];
      return _ordered(Note.listFromDoc(await f.readAsString()));
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String bookId, List<Note> notes) async {
    final f = await _file(bookId);
    final doc = {
      'book': bookId,
      'version': version,
      'notes': _ordered(notes).map((n) => n.toJson()).toList(),
    };
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(doc));
    await tmp.rename(f.path);
  }

  List<Note> _ordered(List<Note> notes) {
    final list = [...notes];
    list.sort((a, b) => a.ch != b.ch
        ? a.ch - b.ch
        : (a.si != b.si ? a.si - b.si : a.s.compareTo(b.s)));
    return list;
  }

  // --- export (Dart port of app/notes.py exporters) ------------------------
  String _mmss(double sec) {
    if (sec.isNaN || sec < 0) sec = 0;
    final total = sec.floor();
    final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  String _blockquote(String text) =>
      text.split('\n').map((l) => '> $l').join('\n');

  String _slugTag(String t) {
    var s = t.trim().replaceAll(RegExp(r'\s+'), '-');
    s = s.replaceAll(RegExp(r'[^0-9A-Za-z_/\-]'), '');
    return s.isEmpty ? 'tag' : s;
  }

  String _inlineTags(List<String> tags) =>
      tags.where((t) => t.trim().isNotEmpty).map((t) => '#${_slugTag(t)}').join(' ');

  String _chTitle(Book book, int ch) {
    if (ch >= 0 && ch < book.chapters.length) {
      final t = book.chapters[ch].title.trim();
      return t.isEmpty ? 'Chapter ${ch + 1}' : t;
    }
    return 'Chapter ${ch + 1}';
  }

  String _yaml(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  String toMarkdown(Book book, List<Note> notes) {
    final parts = <String>['# ${book.title} — Notes'];
    if (book.author.isNotEmpty) parts.add('*by ${book.author}*');
    if (notes.isEmpty) return '${parts.join('\n')}\n\n_No notes yet._\n';
    int? curCh;
    for (final n in _ordered(notes)) {
      if (n.ch != curCh) {
        curCh = n.ch;
        parts..add('')..add('## ${_chTitle(book, n.ch)}');
      }
      final quote = n.exact.trim();
      parts.add('');
      if (quote.isNotEmpty) parts..add(_blockquote(quote))..add('');
      var meta = '*[${_mmss(n.s)}]*';
      final tags = _inlineTags(n.tags);
      if (tags.isNotEmpty) meta += '  $tags';
      parts.add(meta);
      if (n.note.trim().isNotEmpty) parts..add('')..add('**Note:** ${n.note.trim()}');
    }
    return '${parts.join('\n').trim()}\n';
  }

  String toObsidian(Book book, List<Note> notes) {
    final extra = <String>[];
    final seen = <String>{};
    for (final n in notes) {
      for (final t in n.tags) {
        final s = _slugTag(t);
        if (s.isNotEmpty && seen.add(s.toLowerCase())) extra.add(s);
      }
    }
    final parts = <String>['---', 'title: ${_yaml(book.title)}'];
    if (book.author.isNotEmpty) parts.add('author: ${_yaml(book.author)}');
    parts..add('source: audiobook-reader')..add('book_id: ${book.id}')..add('tags:');
    for (final t in ['audiobook', 'notes', ...extra]) {
      parts.add('  - $t');
    }
    parts..add('---')..add('')..add('# ${book.title}');
    if (notes.isEmpty) return '${parts.join('\n')}\n\n_No notes yet._\n';
    int? curCh;
    for (final n in _ordered(notes)) {
      if (n.ch != curCh) {
        curCh = n.ch;
        parts..add('')..add('## ${_chTitle(book, n.ch)}');
      }
      final quote = n.exact.trim();
      final body = n.note.trim();
      final tags = _inlineTags(n.tags);
      parts..add('')..add('> [!quote] ${_chTitle(book, n.ch)} — [${_mmss(n.s)}]');
      if (quote.isNotEmpty) parts.add(_blockquote(quote));
      if (body.isNotEmpty) {
        parts..add('>')..add(_blockquote(body));
        if (tags.isNotEmpty) parts.add('> $tags');
      } else if (tags.isNotEmpty) {
        parts..add('>')..add('> $tags');
      }
      parts.add('^ch${n.ch + 1}-s${n.si}');
    }
    return '${parts.join('\n').trim()}\n';
  }

  /// Write an export to a temp `.md` file and return it (hand to a share sheet).
  Future<File> writeExport(Book book, List<Note> notes, {required bool obsidian}) async {
    final tmp = await getTemporaryDirectory();
    final name = '${book.id}-notes${obsidian ? '-obsidian' : ''}.md';
    final f = File('${tmp.path}/$name');
    await f.writeAsString(obsidian ? toObsidian(book, notes) : toMarkdown(book, notes));
    return f;
  }
}
