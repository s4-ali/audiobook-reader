import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../models/manifest.dart';
import 'library_store.dart';
import 'settings_store.dart';
import 'sync_store.dart';

/// Drives playback for one book: a just_audio playlist of the chapter MP3s, with the
/// active sentence derived from the playback position (the web player's algorithm), plus
/// speed/volume and resume persistence. Exposed to the UI as a [ChangeNotifier].
class PlayerController extends ChangeNotifier {
  final InstalledBook installed;
  final SettingsStore settings;

  /// Optional cloud sync. Null / not-signed-in => every call here is a no-op (fully local).
  final SyncStore? sync;

  /// Cross-device auto-follow state: while another device is actively playing and we're idle, we
  /// mirror its position live (karaoke highlight + scroll) without starting our own playback — and
  /// never while *we* are playing. Drives the reader's "playing on another device" banner.
  static const int _followWindowMs = 12000;
  bool _following = false;
  String? _followerLabel;
  Timer? _followStale;
  // Highest `updated` we've adopted or authored — guards re-adopting stale remote writes (the
  // `device` field filters our own echo).
  int _lastUpd = 0;

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

  PlayerController(this.installed, this.settings, {this.sync});

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
  bool get following => _following;
  String? get followingDeviceName => _followerLabel;

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

    // Resume from the single source of truth: this book's Firestore doc, read cache-first so it's
    // instant and works offline (there is no local progress file). It's one shared doc per account
    // per book, so it already holds the furthest position across web + every device. The realtime
    // listener wired in _wire() then keeps us live. Wait briefly for the anonymous uid on a cold
    // first launch so the very first open still resumes.
    await sync?.awaitUid();
    var initialSource = 0;
    var initialPos = Duration.zero;
    if (sync?.available == true) {
      final remote = await sync!.readProgress(book.id);
      if (remote != null) {
        final ci = (remote['ci'] as num?)?.toInt() ?? 0;
        final src = _sourceToChapter.indexOf(ci);
        if (src >= 0) {
          initialSource = src;
          initialPos = Duration(
              milliseconds: (((remote['t'] as num?)?.toDouble() ?? 0) * 1000).round());
          _lastUpd = (remote['updated'] as num?)?.toInt() ?? 0;
        }
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
      final prevSi = _activeSentence;
      _recomputeActive();
      // Per-sentence cloud sync: push the moment the active sentence advances (debounced in
      // SyncStore → Firestore, offline-queued). Suppressed while we're mirroring another device, so
      // following never echoes the followed spot back under our own name.
      if (!_following && _activeSentence != prevSi && _activeSentence >= 0) {
        _lastUpd = DateTime.now().millisecondsSinceEpoch;
        sync?.writeProgress(book.id,
            ci: _currentChapter,
            t: _position.inMilliseconds / 1000.0,
            si: _activeSentence,
            frac: _progressFraction());
      }
      notifyListeners();
    }));
    _subs.add(_player.currentIndexStream.listen((srcIdx) {
      if (srcIdx == null || srcIdx >= _sourceToChapter.length) return;
      final ch = _sourceToChapter[srcIdx];
      if (ch != _currentChapter) {
        _currentChapter = ch;
        _activeSentence = -1;
        if (!_following) sync?.flushProgress();
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
      if (st.playing) {
        _exitFollow(); // we're the one playing now — stop mirroring another device
      } else if (!_following) {
        // Flush our latest spot on pause (unless we're mirroring another device's playback).
        _enqueueProgress();
        sync?.flushProgress();
      }
      notifyListeners();
    }));
    // Realtime cross-device auto-follow: mirror this book's shared position live. When another
    // device is actively playing and we're idle, _onRemoteProgress moves our (paused) player to
    // its spot so the karaoke highlight tracks it; it never moves the spot out from under our own
    // playback.
    if (sync?.available == true) {
      _subs.add(sync!.progressStream(book.id).listen(_onRemoteProgress,
          onError: (_) {/* e.g. permission revoked on sign-out — degrade to local */}));
    }
  }

  // A remote progress update arrived on the shared book doc. Ignore our own echo and anything not
  // newer than what we've adopted; never move while *we* are playing. Otherwise seek our paused
  // player to the remote spot — the resulting position tick updates the karaoke highlight — and,
  // when that device is actively playing (a fresh update), stay in follow mode so we keep tracking
  // it live and show the banner.
  void _onRemoteProgress(Map<String, dynamic> d) {
    if ((d['device'] as String?) == settings.clientId) return; // our own echo
    final remoteUpd = (d['updated'] as num?)?.toInt() ?? 0;
    if (remoteUpd <= _lastUpd) return; // nothing newer than what we've adopted/authored
    if (_playing) return; // never hijack our own playback
    final ci = (d['ci'] as num?)?.toInt() ?? 0;
    final src = _sourceToChapter.indexOf(ci);
    if (src < 0) return; // that chapter isn't playable on this device
    final t = (d['t'] as num?)?.toDouble() ?? 0;
    _lastUpd = remoteUpd;
    final fresh = DateTime.now().millisecondsSinceEpoch - remoteUpd < _followWindowMs;
    _following = fresh;
    _followerLabel = fresh ? (d['deviceName'] as String?) : null;
    _followStale?.cancel();
    // While the other device keeps sending fresh updates we stay in follow; a gap ends it.
    if (fresh) _followStale = Timer(const Duration(milliseconds: _followWindowMs), _exitFollow);
    // Move the (paused) player to the remote spot. Writes stay suppressed while _following, so this
    // never echoes back as ours; if it's a different chapter, the seek switches sources.
    _player.seek(Duration(milliseconds: (t * 1000).round()), index: src);
    notifyListeners();
  }

  // Stop mirroring another device (its updates stopped, or we took over playback / seeking).
  void _exitFollow() {
    _followStale?.cancel();
    _followStale = null;
    if (!_following && _followerLabel == null) return;
    _following = false;
    _followerLabel = null;
    notifyListeners();
  }

  /// Reader affordance to leave follow mode (tapping the "playing on another device" banner).
  void stopFollowing() => _exitFollow();

  void _recomputeActive() {
    final ch = currentChapter;
    _activeSentence = ch == null
        ? -1
        : findActiveSentence(ch.sentences, _position.inMilliseconds / 1000.0);
  }

  // Enqueue the current spot for cloud sync (coalesced in SyncStore → Firestore, offline-queued).
  void _enqueueProgress() {
    _lastUpd = DateTime.now().millisecondsSinceEpoch;
    sync?.writeProgress(book.id,
        ci: _currentChapter,
        t: _position.inMilliseconds / 1000.0,
        si: _activeSentence < 0 ? 0 : _activeSentence,
        frac: _progressFraction());
  }

  /// Push the current spot to Firestore now — used by the reader on app-background and when leaving
  /// the screen. Skipped while mirroring another device (that spot isn't ours to claim).
  Future<void> flushProgressToSync() async {
    if (_following) return;
    _enqueueProgress();
    await sync?.flushProgress();
  }

  /// Overall progress across the whole book (0..1): the current chapter's global start plus
  /// the in-chapter position, over the book's total duration. Powers the library progress
  /// bars and the "Continue listening" ordering.
  double _progressFraction() {
    final total = book.totalDuration;
    if (total <= 0) return 0;
    final pos = (_chapterStart(_currentChapter) + _position.inMilliseconds / 1000.0) / total;
    return pos.clamp(0.0, 1.0);
  }

  // Seconds of audio before chapter [ci] in playback (array) order. We sum durations rather
  // than trust each chapter's `start_global`, which reflects *generation* order and is wrong
  // for books built with --resume (a regenerated chapter carries a later run's offset).
  double _chapterStart(int ci) {
    var s = 0.0;
    for (var i = 0; i < ci && i < book.chapters.length; i++) {
      s += book.chapters[i].duration;
    }
    return s;
  }

  // --- transport -----------------------------------------------------------
  // Any explicit transport action is a "take-over": stop mirroring another device first. During
  // follow the player already sits at the mirrored spot, so play() simply resumes from there.
  Future<void> togglePlay() => _playing ? pause() : play();
  Future<void> play() {
    _exitFollow();
    return _player.play();
  }
  Future<void> pause() => _player.pause();
  Future<void> seekTo(Duration pos) {
    _exitFollow();
    return _player.seek(pos);
  }
  Future<void> nextChapter() {
    _exitFollow();
    return _player.seekToNext();
  }
  Future<void> prevChapter() {
    _exitFollow();
    return _player.seekToPrevious();
  }

  Future<void> nudge(int seconds) async {
    _exitFollow();
    var target = _position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    await _player.seek(target);
  }

  /// Jump to a chapter (by `book.chapters` position) at an optional in-chapter offset and
  /// start playing — used by the outline, search results, and sentence taps.
  Future<void> goTo(int chapterPos, {double atSeconds = 0, bool startPlaying = true}) async {
    _exitFollow();
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
    if (!_following) {
      _enqueueProgress();
      sync?.flushProgress(); // fire-and-forget final push
    }
    _followStale?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
