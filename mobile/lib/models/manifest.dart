/// Dart mirror of the desktop `manifest.json` contract. Field names and the terse
/// per-sentence keys (i/t/s/e/cs/ce/p) match what `app/ingest.py` writes, so a packaged
/// book parses without any transformation.
library;

import 'dart:convert';

int _toInt(dynamic v) => v == null ? 0 : (v as num).toInt();
double _toDouble(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

/// One synthesized sentence. `s`/`e` are chapter-relative seconds — the values that
/// power seeking and karaoke highlighting.
class Sentence {
  final int i; // index within the chapter
  final String t; // text
  final double s; // start (seconds)
  final double e; // end (seconds)
  final int cs; // char offset start (kept for completeness; unused by the player)
  final int ce; // char offset end
  final bool paragraph; // `p == 1`: a paragraph break follows this sentence

  const Sentence({
    required this.i,
    required this.t,
    required this.s,
    required this.e,
    required this.cs,
    required this.ce,
    required this.paragraph,
  });

  factory Sentence.fromJson(Map<String, dynamic> j) => Sentence(
        i: _toInt(j['i']),
        t: (j['t'] ?? '') as String,
        s: _toDouble(j['s']),
        e: _toDouble(j['e']),
        cs: _toInt(j['cs']),
        ce: _toInt(j['ce']),
        paragraph: _toInt(j['p']) == 1,
      );
}

/// A sub-heading inside a chapter (manifest level >= 2). `time` is its offset within the
/// chapter in seconds.
class Topic {
  final String title;
  final int level;
  final double? time;

  const Topic({required this.title, required this.level, required this.time});

  factory Topic.fromJson(Map<String, dynamic> j) => Topic(
        title: (j['title'] ?? '') as String,
        level: j['level'] == null ? 2 : _toInt(j['level']),
        time: j['time'] == null ? null : _toDouble(j['time']),
      );
}

class Chapter {
  final String id;
  final int index;
  final String title;
  final int level;
  final String? status; // "ready" | "pending" | "error" | null
  final String? audio; // bare filename, e.g. "ch0000.mp3"
  final double duration;
  final double? startGlobal;
  final List<Topic> topics;
  final List<Sentence> sentences;

  const Chapter({
    required this.id,
    required this.index,
    required this.title,
    required this.level,
    required this.status,
    required this.audio,
    required this.duration,
    required this.startGlobal,
    required this.topics,
    required this.sentences,
  });

  /// Mirrors the web player's `isReady()` leniency: a chapter with no explicit status
  /// is treated as ready.
  bool get isReady => (status ?? 'ready') == 'ready';

  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
        id: (j['id'] ?? '') as String,
        index: _toInt(j['index']),
        title: (j['title'] ?? '') as String,
        level: j['level'] == null ? 1 : _toInt(j['level']),
        status: j['status'] as String?,
        audio: j['audio'] as String?,
        duration: _toDouble(j['duration']),
        startGlobal: j['start_global'] == null ? null : _toDouble(j['start_global']),
        topics: ((j['topics'] ?? const []) as List)
            .map((t) => Topic.fromJson(t as Map<String, dynamic>))
            .toList(),
        sentences: ((j['sentences'] ?? const []) as List)
            .map((s) => Sentence.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class Book {
  final String id;
  final String title;
  final String author;
  final String voice;
  final String engine;
  final double speed;
  final String status;
  final int chaptersTotal;
  final int chaptersReady;
  final double totalDuration;
  final List<Chapter> chapters;

  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.voice,
    required this.engine,
    required this.speed,
    required this.status,
    required this.chaptersTotal,
    required this.chaptersReady,
    required this.totalDuration,
    required this.chapters,
  });

  factory Book.fromJson(Map<String, dynamic> j) {
    final chapters = ((j['chapters'] ?? const []) as List)
        .map((c) => Chapter.fromJson(c as Map<String, dynamic>))
        .toList();
    return Book(
      id: (j['id'] ?? '') as String,
      title: (j['title'] ?? j['id'] ?? 'Untitled') as String,
      author: (j['author'] ?? '') as String,
      voice: (j['voice'] ?? '') as String,
      engine: (j['engine'] ?? '') as String,
      speed: j['speed'] == null ? 1.0 : _toDouble(j['speed']),
      status: (j['status'] ?? 'ready') as String,
      chaptersTotal: j['chapters_total'] == null ? chapters.length : _toInt(j['chapters_total']),
      chaptersReady: _toInt(j['chapters_ready']),
      totalDuration: _toDouble(j['total_duration']),
      chapters: chapters,
    );
  }

  static Book parse(String jsonStr) =>
      Book.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
}

/// Port of the web player's `findActiveIndex` (web/app.js): the greatest sentence index
/// whose start time `s` is <= `t`. Returns -1 if `t` precedes the first sentence.
/// O(log n) binary search over the chapter's (start-sorted) sentences.
int findActiveSentence(List<Sentence> sentences, double t) {
  var lo = 0, hi = sentences.length - 1, ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (sentences[mid].s <= t) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}
