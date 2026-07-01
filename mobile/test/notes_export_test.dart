import 'package:audiobook_player/models/manifest.dart';
import 'package:audiobook_player/models/note.dart';
import 'package:audiobook_player/services/library_store.dart';
import 'package:audiobook_player/services/notes_store.dart';
import 'package:flutter_test/flutter_test.dart';

Chapter _ch(String id, int i, String title) => Chapter(
      id: id,
      index: i,
      title: title,
      level: 1,
      status: 'ready',
      audio: '$id.mp3',
      duration: 100,
      startGlobal: null,
      topics: const [],
      sentences: const [],
    );

Book _book() => Book(
      id: 'demo',
      title: 'Demo: A Book',
      author: 'A. Writer',
      voice: '',
      engine: '',
      speed: 1.0,
      status: 'ready',
      chaptersTotal: 2,
      chaptersReady: 2,
      totalDuration: 0,
      chapters: [_ch('ch0', 0, 'Intro'), _ch('ch1', 1, 'Two')],
    );

Note _note({
  required String id,
  required int ch,
  int si = 0,
  String color = 'yellow',
  List<String> tags = const [],
  String body = '',
  double s = 0,
  String exact = 'Quote.',
}) =>
    Note(
      id: id,
      kind: body.isEmpty ? 'highlight' : 'note',
      ch: ch,
      si: si,
      sj: si,
      cs: 0,
      ce: 0,
      s: s,
      e: s + 1,
      exact: exact,
      prefix: '',
      suffix: '',
      color: color,
      tags: tags,
      note: body,
      created: '2026-07-01T00:00:00Z',
      updated: '2026-07-01T00:00:00Z',
    );

void main() {
  final store = NotesStore(LibraryStore());
  final b = _book();
  final notes = [
    _note(
        id: '1',
        ch: 0,
        si: 2,
        color: 'green',
        tags: ['idea', 'key-point'],
        body: 'Multi\n> line',
        s: 65,
        exact: 'Line one. Line two.'),
    _note(id: '2', ch: 1, si: 0, s: 3725, exact: 'Just a highlight.'),
  ];

  test('markdown export structure matches the backend format', () {
    final md = store.toMarkdown(b, notes);
    expect(md, startsWith('# Demo: A Book — Notes'));
    expect(md, contains('## Intro'));
    expect(md, contains('> Line one. Line two.'));
    expect(md, contains('*[1:05]*'));
    expect(md, contains('#idea #key-point'));
    expect(md, contains('**Note:** Multi\n> line'));
    expect(md, contains('## Two'));
    expect(md, contains('*[1:02:05]*')); // 3725s = 1h02m05s
  });

  test('obsidian export uses plural tags, callouts and block ids', () {
    final ob = store.toObsidian(b, notes);
    expect(ob, contains('title: "Demo: A Book"'));
    expect(ob, contains('\ntags:\n  - audiobook\n  - notes\n  - idea\n  - key-point'));
    expect(ob, contains('> [!quote] Intro — [1:05]'));
    expect(ob, contains('> Line one. Line two.'));
    expect(ob, contains('^ch1-s2'));
    expect(ob, contains('> [!quote] Two — [1:02:05]'));
    expect(ob, contains('^ch2-s0'));
  });

  test('empty exports are friendly, not blank', () {
    expect(store.toMarkdown(b, const []), contains('_No notes yet._'));
    expect(store.toObsidian(b, const []), contains('_No notes yet._'));
  });

  test('Note JSON round-trips (device <-> server contract)', () {
    final n = notes.first;
    final again = Note.fromJson(n.toJson());
    expect(again.id, n.id);
    expect(again.kind, 'note');
    expect(again.tags, ['idea', 'key-point']);
    expect(again.note, 'Multi\n> line');
    expect(again.ch, 0);
    expect(again.si, 2);
  });
}
