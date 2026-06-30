import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/manifest.dart';
import '../services/library_store.dart';
import '../services/player_controller.dart';
import '../services/settings_store.dart';
import '../theme.dart';
import '../util.dart';

/// The player: scrolling chapter text with the active sentence highlighted (karaoke),
/// tap-a-sentence to seek, an outline + search sheet, and the transport bar. Mirrors the
/// web player; generation controls are intentionally absent (packages are already done).
class ReaderScreen extends StatefulWidget {
  final InstalledBook installed;
  const ReaderScreen({super.key, required this.installed});

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

  @override
  void initState() {
    super.initState();
    _c = PlayerController(widget.installed, context.read<SettingsStore>());
    _c.init();
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
        final spans = <InlineSpan>[];
        for (final s in _paras[pIdx]) {
          final active = s.i == _c.activeSentenceIndex;
          spans.add(TextSpan(
            text: '${s.t} ',
            recognizer: _recognizers[s.i],
            style: TextStyle(
              color: active ? cCrust : cText,
              backgroundColor: active ? cMauve : null,
            ),
          ));
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text.rich(
            TextSpan(children: spans),
            style: const TextStyle(fontSize: 18, height: 1.6),
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
