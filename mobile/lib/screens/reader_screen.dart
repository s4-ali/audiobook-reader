import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/manifest.dart';
import '../models/note.dart';
import '../services/library_store.dart';
import '../services/notes_store.dart';
import '../services/player_controller.dart';
import '../services/settings_store.dart';
import '../services/transfer.dart';
import '../theme.dart';
import '../util.dart';

/// The player: scrolling chapter text with the active sentence highlighted (karaoke),
/// tap-a-sentence to seek, an outline + search sheet, and the transport bar. Mirrors the
/// web player; generation controls are intentionally absent (packages are already done).
class ReaderScreen extends StatefulWidget {
  final InstalledBook installed;
  final bool autoplay; // start playing once resumed (from the "Continue" card)
  const ReaderScreen({super.key, required this.installed, this.autoplay = false});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  static const _speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _tiny = TextStyle(fontSize: 11, color: cSubtext0);

  late final PlayerController _c;
  final ItemScrollController _scroll = ItemScrollController();

  // Per-chapter rendering cache, rebuilt only when the chapter changes.
  int _cachedChapter = -1;
  List<List<Sentence>> _paras = [];
  final Map<int, int> _sentToPara = {}; // sentence index -> paragraph index
  final Map<int, TapGestureRecognizer> _recognizers = {};
  int _lastScrolledPara = -1;

  double? _scrub; // 0..1 while the user drags the seek bar

  late final NotesStore _notesStore;
  List<Note> _noteList = [];
  final Map<int, String> _hlColor = {}; // sentence index -> color (current chapter only)
  final Map<int, GlobalKey> _paraKeys = {}; // paragraph index -> key (long-press hit-test)
  final Uuid _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _c = PlayerController(widget.installed, context.read<SettingsStore>());
    _notesStore = context.read<NotesStore>();
    _loadNotes();
    _c.init().then((_) {
      if (mounted && widget.autoplay) _c.play();
    });
  }

  @override
  void dispose() {
    _disposeRecognizers();
    _c.dispose();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    _recognizers.clear();
  }

  /// Split the current chapter into paragraphs and build one tap recognizer per sentence.
  void _ensureCache() {
    if (_c.currentChapterIndex == _cachedChapter) return;
    _cachedChapter = _c.currentChapterIndex;
    _disposeRecognizers();
    _paras = [];
    _sentToPara.clear();
    _paraKeys.clear();
    _lastScrolledPara = -1;
    final ch = _c.currentChapter;
    if (ch == null) return;
    final chapterPos = _cachedChapter;
    var current = <Sentence>[];
    for (final s in ch.sentences) {
      current.add(s);
      _recognizers[s.i] = TapGestureRecognizer()
        ..onTap = () => _c.goTo(chapterPos, atSeconds: s.s);
      if (s.paragraph) {
        _paras.add(current);
        current = [];
      }
    }
    if (current.isNotEmpty) _paras.add(current);
    for (var p = 0; p < _paras.length; p++) {
      for (final s in _paras[p]) {
        _sentToPara[s.i] = p;
      }
    }
    _rebuildHighlights();
  }

  /// Keep the active sentence visible (scrolls when its paragraph changes).
  void _maybeAutoScroll() {
    final si = _c.activeSentenceIndex;
    if (si < 0) return;
    final para = _sentToPara[si];
    if (para == null || para == _lastScrolledPara) return;
    _lastScrolledPara = para;
    if (!_scroll.isAttached) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.isAttached) {
        _scroll.scrollTo(
          index: para,
          alignment: 0.35,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (!_c.ready) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (!_c.hasAudio) {
          return Scaffold(
            appBar: AppBar(title: Text(_c.book.title)),
            body: const Center(child: Text('No playable audio in this book.')),
          );
        }
        _ensureCache();
        _maybeAutoScroll();
        final ch = _c.currentChapter!;
        return Scaffold(
          appBar: AppBar(
            title: Text(_c.book.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                  icon: const Icon(Icons.list),
                  tooltip: 'Contents',
                  onPressed: _showOutline),
              IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Search',
                  onPressed: _showSearch),
              IconButton(
                  icon: const Icon(Icons.sticky_note_2_outlined),
                  tooltip: 'Notes',
                  onPressed: _showNotes),
            ],
          ),
          body: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
                child: Text(ch.title,
                    style: const TextStyle(
                        fontSize: 13,
                        color: cSubtext0,
                        fontWeight: FontWeight.w600)),
              ),
              Expanded(child: _textList()),
            ],
          ),
          bottomNavigationBar: _transport(ch),
        );
      },
    );
  }

  Widget _textList() {
    if (_paras.isEmpty) {
      return const Center(child: Text('No text for this chapter.'));
    }
    return ScrollablePositionedList.builder(
      itemScrollController: _scroll,
      itemCount: _paras.length,
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
      itemBuilder: (context, pIdx) {
        final key = _paraKeys.putIfAbsent(pIdx, () => GlobalKey());
        final spans = <InlineSpan>[];
        for (final s in _paras[pIdx]) {
          final active = s.i == _c.activeSentenceIndex;
          final hl = _hlColor[s.i];
          spans.add(TextSpan(
            text: '${s.t} ',
            recognizer: _recognizers[s.i],
            style: TextStyle(
              color: active ? cCrust : cText,
              backgroundColor: active ? cMauve : (hl != null ? noteWash(hl) : null),
            ),
          ));
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: GestureDetector(
            onLongPressStart: (d) => _longPressSentence(pIdx, key, d.globalPosition),
            child: Text.rich(
              TextSpan(children: spans),
              key: key,
              style: const TextStyle(fontSize: 18, height: 1.6),
            ),
          ),
        );
      },
    );
  }

  Widget _transport(Chapter ch) {
    final pos = _c.position;
    final dur = _c.duration.inMilliseconds > 0
        ? _c.duration
        : Duration(milliseconds: (ch.duration * 1000).round());
    final active = _c.activeSentence;
    return SafeArea(
      top: false,
      child: Container(
        color: cSurface0,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 30,
              child: Center(
                child: Text(
                  active?.t ?? ch.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: cSubtext0, fontSize: 12),
                ),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 6),
                Text(fmtClock(pos), style: _tiny),
                Expanded(
                  child: Slider(
                    value: _sliderValue(pos, dur),
                    onChanged: (v) => setState(() => _scrub = v),
                    onChangeEnd: (v) {
                      _scrub = null;
                      _c.seekTo(Duration(
                          milliseconds: (v * dur.inMilliseconds).round()));
                    },
                  ),
                ),
                Text(fmtClock(dur), style: _tiny),
                const SizedBox(width: 6),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                    icon: const Icon(Icons.skip_previous),
                    tooltip: 'Previous chapter',
                    onPressed: _c.prevChapter),
                IconButton(
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => _c.nudge(-10)),
                IconButton(
                  iconSize: 52,
                  color: cMauve,
                  icon: Icon(_c.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled),
                  onPressed: _c.togglePlay,
                ),
                IconButton(
                    icon: const Icon(Icons.forward_10),
                    onPressed: () => _c.nudge(10)),
                IconButton(
                    icon: const Icon(Icons.skip_next),
                    tooltip: 'Next chapter',
                    onPressed: _c.nextChapter),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.speed, size: 18, color: cSubtext0),
                const SizedBox(width: 4),
                _speedDropdown(),
                const Spacer(),
                const Icon(Icons.volume_up, size: 18, color: cSubtext0),
                SizedBox(
                  width: 130,
                  child: Slider(value: _c.volume, onChanged: _c.setVolume),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double _sliderValue(Duration pos, Duration dur) {
    if (_scrub != null) return _scrub!.clamp(0.0, 1.0);
    if (dur.inMilliseconds == 0) return 0;
    return (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
  }

  Widget _speedDropdown() {
    final value = _speeds.contains(_c.speed) ? _c.speed : 1.0;
    return DropdownButton<double>(
      value: value,
      underline: const SizedBox.shrink(),
      isDense: true,
      items: _speeds
          .map((s) => DropdownMenuItem(value: s, child: Text('$s×')))
          .toList(),
      onChanged: (v) {
        if (v != null) _c.setSpeed(v);
      },
    );
  }

  // --- notes ---------------------------------------------------------------
  Future<void> _loadNotes() async {
    final list = await _notesStore.load(_c.book.id);
    if (!mounted) return;
    setState(() {
      _noteList = list;
      _rebuildHighlights();
    });
  }

  /// Rebuild the sentence-index → color map for the current chapter.
  void _rebuildHighlights() {
    _hlColor.clear();
    final ci = _c.currentChapterIndex;
    final maxI = (_c.currentChapter?.sentences.length ?? 0) - 1;
    for (final n in _noteList) {
      if (n.ch != ci || n.si < 0 || n.sj > maxI || n.si > n.sj) continue;
      for (var i = n.si; i <= n.sj; i++) {
        _hlColor[i] = n.color; // last write wins where notes overlap
      }
    }
  }

  Future<void> _persistNotes() => _notesStore.save(_c.book.id, _noteList);

  /// Build the durable anchor fields for a sentence range in the current chapter.
  Note _draftNote(int si, int sj) {
    final sents = _c.currentChapter!.sentences;
    si = si.clamp(0, sents.length - 1);
    sj = sj.clamp(si, sents.length - 1);
    final exact = [for (var i = si; i <= sj; i++) sents[i].t].join(' ');
    final prefix = [for (var i = (si - 3).clamp(0, si); i < si; i++) sents[i].t].join(' ');
    final suffix =
        [for (var i = sj + 1; i <= sj + 3 && i < sents.length; i++) sents[i].t].join(' ');
    final now = NotesStore.nowIso();
    return Note(
      id: _uuid.v4(),
      kind: 'highlight',
      ch: _c.currentChapterIndex,
      si: si,
      sj: sj,
      cs: sents[si].cs,
      ce: sents[sj].ce,
      s: sents[si].s,
      e: sents[sj].e,
      exact: exact,
      prefix: prefix.length > 32 ? prefix.substring(prefix.length - 32) : prefix,
      suffix: suffix.length > 32 ? suffix.substring(0, 32) : suffix,
      color: 'yellow',
      tags: const [],
      note: '',
      created: now,
      updated: now,
    );
  }

  /// Map a long-press position to the sentence under it (via the paragraph's RenderParagraph).
  void _longPressSentence(int pIdx, GlobalKey key, Offset globalPos) {
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final tp = ro.getPositionForOffset(ro.globalToLocal(globalPos));
    var acc = 0;
    Sentence? hit;
    for (final s in _paras[pIdx]) {
      acc += s.t.length + 1; // + the trailing space rendered after each sentence
      if (tp.offset < acc) {
        hit = s;
        break;
      }
    }
    hit ??= _paras[pIdx].isNotEmpty ? _paras[pIdx].last : null;
    if (hit != null) _openNoteSheet(draft: _draftNote(hit.i, hit.i));
  }

  void _addNoteAtCurrent() {
    final ch = _c.currentChapter;
    if (ch == null || ch.sentences.isEmpty) return;
    final si = _c.activeSentenceIndex < 0 ? 0 : _c.activeSentenceIndex;
    _openNoteSheet(draft: _draftNote(si, si));
  }

  List<String> _parseTags(String v) => v
      .split(RegExp(r'[,\n]+'))
      .map((t) => t.trim().replaceFirst(RegExp('^#'), ''))
      .where((t) => t.isNotEmpty)
      .toList();

  Future<void> _openNoteSheet({Note? existing, Note? draft}) async {
    final base = existing ?? draft!;
    final bodyCtrl = TextEditingController(text: base.note);
    final tagsCtrl = TextEditingController(text: base.tags.join(', '));
    var color = NotesStore.colors.contains(base.color) ? base.color : 'yellow';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (_, setSheet) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(existing == null ? 'Add note' : 'Edit note',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                if (base.exact.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: cSurface0,
                      border: Border(left: BorderSide(color: cMauve, width: 3)),
                    ),
                    child: Text(base.exact,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: cSubtext0, fontStyle: FontStyle.italic, fontSize: 13)),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyCtrl,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: 'Write your note…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final c in NotesStore.colors)
                      GestureDetector(
                        onTap: () => setSheet(() => color = c),
                        child: Container(
                          margin: const EdgeInsets.only(right: 12),
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: noteSwatchColors[c],
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color == c ? cText : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tagsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Tags (comma-separated)',
                    hintText: 'idea, todo',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (existing != null)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _deleteNote(existing);
                        },
                        icon: const Icon(Icons.delete_outline, color: cRed),
                        label: const Text('Delete', style: TextStyle(color: cRed)),
                      ),
                    const Spacer(),
                    TextButton(
                        onPressed: () => Navigator.pop(sheetCtx),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _saveNote(existing, base, bodyCtrl.text, tagsCtrl.text, color);
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    bodyCtrl.dispose();
    tagsCtrl.dispose();
  }

  Future<void> _saveNote(
      Note? existing, Note base, String body, String tags, String color) async {
    final kind = body.trim().isEmpty ? 'highlight' : 'note';
    final list = [..._noteList];
    if (existing != null) {
      final idx = list.indexWhere((n) => n.id == existing.id);
      if (idx >= 0) {
        list[idx] = existing.copyWith(
            note: body,
            tags: _parseTags(tags),
            color: color,
            kind: kind,
            updated: NotesStore.nowIso());
      }
    } else {
      list.add(base.copyWith(
          note: body,
          tags: _parseTags(tags),
          color: color,
          kind: kind,
          updated: NotesStore.nowIso()));
    }
    setState(() {
      _noteList = list;
      _rebuildHighlights();
    });
    await _persistNotes();
  }

  Future<void> _deleteNote(Note note) async {
    setState(() {
      _noteList = _noteList.where((n) => n.id != note.id).toList();
      _rebuildHighlights();
    });
    await _persistNotes();
  }

  void _jumpToNote(Note n) {
    if (n.ch < 0 || n.ch >= _c.book.chapters.length) return;
    if (!_c.book.chapters[n.ch].isReady) return;
    _c.goTo(n.ch, atSeconds: n.s);
  }

  List<Note> _orderedNotes() {
    final list = [..._noteList];
    list.sort((a, b) => a.ch != b.ch
        ? a.ch - b.ch
        : (a.si != b.si ? a.si - b.si : a.s.compareTo(b.s)));
    return list;
  }

  void _showNotes() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (_, scrollCtrl) => StatefulBuilder(
          builder: (_, setSheet) {
            final ordered = _orderedNotes();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      Text('Notes · ${ordered.length}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.ios_share),
                        tooltip: 'Export / sync',
                        onSelected: (v) {
                          if (v == 'md') _exportNotes(obsidian: false);
                          if (v == 'obsidian') _exportNotes(obsidian: true);
                          if (v == 'sync') _syncNotes(() => setSheet(() {}));
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'md', child: Text('Export Markdown')),
                          PopupMenuItem(
                              value: 'obsidian', child: Text('Export for Obsidian')),
                          PopupMenuItem(value: 'sync', child: Text('Sync with server')),
                        ],
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.add, color: cMauve),
                  title: const Text('Add note at current spot'),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _addNoteAtCurrent();
                  },
                ),
                const Divider(height: 1),
                Expanded(
                  child: ordered.isEmpty
                      ? const Center(
                          child: Text('No notes yet.',
                              style: TextStyle(color: cSubtext0)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: ordered.length,
                          itemBuilder: (_, i) {
                            final n = ordered[i];
                            final chTitle = n.ch < _c.book.chapters.length
                                ? _c.book.chapters[n.ch].title
                                : 'Chapter ${n.ch + 1}';
                            return ListTile(
                              leading: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: noteSwatchColors[n.color] ?? cYellow,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              title: Text(
                                  n.note.trim().isEmpty ? n.exact : n.note,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '$chTitle · ${fmtClock(Duration(milliseconds: (n.s * 1000).round()))}',
                                style: _tiny,
                              ),
                              onTap: () {
                                Navigator.pop(sheetCtx);
                                _jumpToNote(n);
                              },
                              onLongPress: () {
                                Navigator.pop(sheetCtx);
                                _openNoteSheet(existing: n);
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _exportNotes({required bool obsidian}) async {
    if (_noteList.isEmpty) {
      _snack('No notes to export yet.');
      return;
    }
    try {
      final f = await _notesStore.writeExport(_c.book, _noteList, obsidian: obsidian);
      await Share.shareXFiles([XFile(f.path)], subject: '${_c.book.title} — notes');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  Future<void> _syncNotes(VoidCallback refreshSheet) async {
    final transfer = context.read<Transfer>();
    final url = context.read<SettingsStore>().serverUrl;
    if (url == null || url.isEmpty) {
      _snack('No server set — open one from the library first.');
      return;
    }
    _snack('Syncing notes…');
    try {
      final merged = await transfer.syncNotes(url, _c.book.id, _noteList);
      await _notesStore.save(_c.book.id, merged);
      if (!mounted) return;
      setState(() {
        _noteList = merged;
        _rebuildHighlights();
      });
      refreshSheet();
      _snack('Notes synced (${merged.length} total).');
    } catch (e) {
      _snack('Sync failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // --- outline -------------------------------------------------------------
  void _showOutline() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (_, scrollCtrl) {
          final tiles = <Widget>[];
          for (var ci = 0; ci < _c.book.chapters.length; ci++) {
            final ch = _c.book.chapters[ci];
            tiles.add(ListTile(
              selected: ci == _c.currentChapterIndex,
              enabled: ch.isReady,
              title: Text(ch.title),
              trailing: ch.duration > 0
                  ? Text(
                      fmtClock(
                          Duration(milliseconds: (ch.duration * 1000).round())),
                      style: _tiny)
                  : null,
              onTap: () {
                Navigator.pop(sheetCtx);
                _c.goTo(ci);
              },
            ));
            for (final tp in ch.topics) {
              if (tp.time == null) continue;
              tiles.add(ListTile(
                enabled: ch.isReady,
                dense: true,
                contentPadding: EdgeInsets.only(
                    left: 32 + (tp.level - 2).clamp(0, 4) * 16.0, right: 16),
                title: Text(tp.title, style: const TextStyle(fontSize: 13)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _c.goTo(ci, atSeconds: tp.time!);
                },
              ));
            }
          }
          return ListView(controller: scrollCtrl, children: tiles);
        },
      ),
    );
  }

  // --- search --------------------------------------------------------------
  void _showSearch() {
    final index = _buildSearchIndex();
    final controller = TextEditingController();
    var results = <_Hit>[];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, scrollCtrl) => StatefulBuilder(
            builder: (_, setSheet) {
              void run(String q) {
                final query = q.trim().toLowerCase();
                results = query.isEmpty ? [] : _search(index, query);
                setSheet(() {});
              }

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search this book…',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: run,
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollCtrl,
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final h = results[i];
                        return ListTile(
                          dense: true,
                          title: Text(
                            '${h.nav ? '▸ ' : ''}${h.chapterTitle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: cSubtext0),
                          ),
                          subtitle: Text(h.text,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Text(
                              fmtClock(Duration(
                                  milliseconds: (h.time * 1000).round())),
                              style: _tiny),
                          onTap: () {
                            Navigator.pop(sheetCtx);
                            _c.goTo(h.chapterPos, atSeconds: h.time);
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<_Hit> _buildSearchIndex() {
    final items = <_Hit>[];
    for (var ci = 0; ci < _c.book.chapters.length; ci++) {
      final ch = _c.book.chapters[ci];
      items.add(_Hit(ci, 0, ch.title, ch.title, true));
      for (final tp in ch.topics) {
        if (tp.time != null) {
          items.add(_Hit(ci, tp.time!, ch.title, tp.title, true));
        }
      }
      for (final s in ch.sentences) {
        items.add(_Hit(ci, s.s, ch.title, s.t, false));
      }
    }
    return items;
  }

  List<_Hit> _search(List<_Hit> index, String query) {
    final nav = <_Hit>[];
    final lines = <_Hit>[];
    for (final h in index) {
      if (h.lc.contains(query)) {
        (h.nav ? nav : lines).add(h);
        if (nav.length + lines.length >= 120) break;
      }
    }
    return [...nav, ...lines].take(60).toList();
  }
}

/// A search index entry / result.
class _Hit {
  final int chapterPos;
  final double time;
  final String chapterTitle;
  final String text;
  final bool nav; // chapter/topic heading vs. a sentence line
  final String lc;

  _Hit(this.chapterPos, this.time, this.chapterTitle, this.text, this.nav)
      : lc = text.toLowerCase();
}
