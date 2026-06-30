import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../models/manifest.dart';
import 'library_store.dart';
import 'settings_store.dart';

/// Drives playback for one book: a just_audio playlist of the chapter MP3s, with the
/// active sentence derived from the playback position (the web player's algorithm), plus
/// speed/volume and resume persistence. Exposed to the UI as a [ChangeNotifier].
class PlayerController extends ChangeNotifier {
  final InstalledBook installed;
  final SettingsStore settings;

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];

  /// source index in the playlist -> position in `book.chapters`. Only chapters that are
  /// ready and have a real audio file become sources, so the two can differ for a
  /// partial book; for a fully-ready package it is the identity.
  final List<int> _sourceToChapter = [];

  bool _ready = false;
  int _currentChapter = 0; // position in book.chapters
  int _activeSentence = -1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _speed = 1.0;
  double _volume = 1.0;
  int _saveTick = 0;

  PlayerController(this.installed, this.settings);

  Book get book => installed.book;
  bool get ready => _ready;
  bool get hasAudio => _sourceToChapter.isNotEmpty;
  int get currentChapterIndex => _currentChapter;
  int get activeSentenceIndex => _activeSentence;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  double get speed => _speed;
  double get volume => _volume;

  Chapter? get currentChapter =>
      (_currentChapter >= 0 && _currentChapter < book.chapters.length)
          ? book.chapters[_currentChapter]
          : null;

  Sentence? get activeSentence {
    final ch = currentChapter;
    if (ch == null || _activeSentence < 0 || _activeSentence >= ch.sentences.length) {
      return null;
    }
    return ch.sentences[_activeSentence];
  }

  Future<void> init() async {
    final sources = <AudioSource>[];
    for (var pos = 0; pos < book.chapters.length; pos++) {
      final ch = book.chapters[pos];
      if (!ch.isReady || ch.audio == null) continue;
      if (!File(installed.chapterPath(ch)).existsSync()) continue;
      _sourceToChapter.add(pos);
      sources.add(AudioSource.uri(
        Uri.file(installed.chapterPath(ch)),
        tag: MediaItem(
          id: '${book.id}::${ch.id}',
          album: book.title,
          title: ch.title.isEmpty ? 'Chapter ${pos + 1}' : ch.title,
          artist: book.author.isEmpty ? null : book.author,
          duration: ch.duration > 0
              ? Duration(milliseconds: (ch.duration * 1000).round())
              : null,
        ),
      ));
    }

    if (sources.isEmpty) {
      _ready = true;
      notifyListeners();
      return;
    }

    // Resume where we left off, if the saved chapter is still playable.
    var initialSource = 0;
    var initialPos = Duration.zero;
    final saved = settings.loadPosition(book.id);
    if (saved != null) {
      final si = _sourceToChapter.indexOf(saved.chapterIndex);
      if (si >= 0) {
        initialSource = si;
        initialPos = Duration(milliseconds: (saved.time * 1000).round());
      }
    }
    _currentChapter = _sourceToChapter[initialSource];

    await _player.setAudioSources(sources,
        initialIndex: initialSource, initialPosition: initialPos);
    _speed = settings.rate;
    _volume = settings.volume;
    await _player.setSpeed(_speed);
    await _player.setVolume(_volume);

    _wire();
    _ready = true;
    notifyListeners();
  }

  void _wire() {
    _subs.add(_player.positionStream.listen((pos) {
      _position = pos;
      _recomputeActive();
      if (++_saveTick % 10 == 0) _persist();
      notifyListeners();
    }));
    _subs.add(_player.currentIndexStream.listen((srcIdx) {
      if (srcIdx == null || srcIdx >= _sourceToChapter.length) return;
      final ch = _sourceToChapter[srcIdx];
      if (ch != _currentChapter) {
        _currentChapter = ch;
        _activeSentence = -1;
        notifyListeners();
      }
    }));
    _subs.add(_player.durationStream.listen((d) {
      if (d != null) {
        _duration = d;
        notifyListeners();
      }
    }));
    _subs.add(_player.playerStateStream.listen((st) {
      _playing = st.playing;
      if (!st.playing) _persist();
      notifyListeners();
    }));
  }

  void _recomputeActive() {
    final ch = currentChapter;
    _activeSentence = ch == null
        ? -1
        : findActiveSentence(ch.sentences, _position.inMilliseconds / 1000.0);
  }

  void _persist() => settings.savePosition(
      book.id, _currentChapter, _position.inMilliseconds / 1000.0);

  // --- transport -----------------------------------------------------------
  Future<void> togglePlay() => _playing ? _player.pause() : _player.play();
  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seekTo(Duration pos) => _player.seek(pos);
  Future<void> nextChapter() => _player.seekToNext();
  Future<void> prevChapter() => _player.seekToPrevious();

  Future<void> nudge(int seconds) async {
    var target = _position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    await _player.seek(target);
  }

  /// Jump to a chapter (by `book.chapters` position) at an optional in-chapter offset and
  /// start playing — used by the outline, search results, and sentence taps.
  Future<void> goTo(int chapterPos, {double atSeconds = 0, bool startPlaying = true}) async {
    final si = _sourceToChapter.indexOf(chapterPos);
    if (si < 0) return;
    await _player.seek(Duration(milliseconds: (atSeconds * 1000).round()), index: si);
    if (startPlaying && !_playing) await _player.play();
  }

  Future<void> setSpeed(double s) async {
    _speed = s;
    settings.rate = s;
    await _player.setSpeed(s);
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    _volume = v;
    settings.volume = v;
    await _player.setVolume(v);
    notifyListeners();
  }

  @override
  void dispose() {
    _persist();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
