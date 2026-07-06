import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/note.dart';
import 'settings_store.dart';

/// The single, optional Firebase seam. When Firebase isn't configured (no
/// `lib/firebase_options.dart` from `flutterfire configure`) or no user is signed in, every
/// method is a no-op and the app behaves exactly as it does locally. When signed in, it mirrors
/// reading progress and notes to
/// Cloud Firestore so they stay in sync with the web player and any other device.
///
/// Firestore layout — identical to `web/sync.js`:
///   users/{uid}/books/{bookId}                 -> progress {ci,t,si,frac,updated,device}
///   users/{uid}/books/{bookId}/notes/{noteId}  -> one doc per note (+ a {deleted} tombstone)
class SyncStore extends ChangeNotifier {
  final SettingsStore settings;
  final bool enabled;

  FirebaseAuth? _auth;
  FirebaseFirestore? _db;
  StreamSubscription<User?>? _authSub;

  SyncStore(this.settings, {required this.enabled}) {
    if (!enabled) return;
    try {
      _auth = FirebaseAuth.instance;
      _db = FirebaseFirestore.instance;
      _authSub = _auth!.authStateChanges().listen((_) => notifyListeners());
      // Always keep a uid. An anonymous account makes Firestore (+ its offline cache) the single
      // source of truth for progress from first launch — no local progress file, yet resume/sync
      // work offline. Signing in with an email later *links* this same uid, so anonymous reading
      // history carries over. Fire-and-forget: authStateChanges wires listeners once it lands.
      if (_auth!.currentUser == null) unawaited(_ensureAnon());
    } catch (_) {
      _auth = null;
      _db = null;
    }
  }

  Future<void> _ensureAnon() async {
    try {
      await _auth?.signInAnonymously();
    } catch (_) {/* offline first-run: no uid this session; a later (online) launch mints one */}
  }

  /// Complete once a uid exists (the anonymous sign-in kicked off in the constructor, or a real
  /// one), bounded so a cold *offline* first launch never blocks the reader. Lets the very first
  /// book-open right after install still resume from Firestore instead of starting at zero.
  Future<void> awaitUid({Duration timeout = const Duration(seconds: 3)}) async {
    final auth = _auth;
    if (auth == null || auth.currentUser != null) return;
    try {
      await auth.authStateChanges().firstWhere((u) => u != null).timeout(timeout);
    } catch (_) {/* still no uid (offline first-run) — caller proceeds without a resume seek */}
  }

  /// Sync is live whenever Firebase initialized AND any uid exists (anonymous or real).
  bool get available => enabled && _auth?.currentUser != null;

  /// True only when signed in with a real (email) account — not the anonymous baseline. The
  /// account screen and the library's cloud icon key off this; [available] (any uid) gates sync.
  bool get signedInWithAccount {
    final u = _auth?.currentUser;
    return enabled && u != null && !u.isAnonymous;
  }

  String? get email => _auth?.currentUser?.email;

  // UTC, second precision, `Z` suffix — matches NotesStore.nowIso() / the server, so
  // last-write-wins string comparison of `updated` stays consistent across web + mobile.
  static String _nowIso() {
    final n = DateTime.now().toUtc();
    final d = DateTime.utc(n.year, n.month, n.day, n.hour, n.minute, n.second);
    return '${d.toIso8601String().split('.').first}Z';
  }

  // --- auth ----------------------------------------------------------------
  /// Sign in — carrying the anonymous reading history along. When anonymous (the default), *link*
  /// the email credential onto this uid so its Firestore data becomes the account's. If the email
  /// already belongs to an account, fall back to signing into it (the anonymous uid is left
  /// behind). A brand-new email therefore creates the account in place, keeping progress.
  Future<void> signIn(String email, String password) async {
    final auth = _auth;
    if (auth == null) throw StateError('Cloud sync is not configured in this build.');
    final cur = auth.currentUser;
    if (cur != null && cur.isAnonymous) {
      try {
        await cur.linkWithCredential(
            EmailAuthProvider.credential(email: email, password: password));
        return;
      } on FirebaseAuthException catch (e) {
        if (e.code != 'email-already-in-use' && e.code != 'credential-already-in-use') rethrow;
        // Account already exists → switch to it below.
      }
    }
    await auth.signInWithEmailAndPassword(email: email, password: password);
  }

  /// Create an account, linking it to the current anonymous uid when possible so nothing is lost.
  Future<void> signUp(String email, String password) async {
    final auth = _auth;
    if (auth == null) throw StateError('Cloud sync is not configured in this build.');
    final cur = auth.currentUser;
    if (cur != null && cur.isAnonymous) {
      await cur.linkWithCredential(
          EmailAuthProvider.credential(email: email, password: password));
      return;
    }
    await auth.createUserWithEmailAndPassword(email: email, password: password);
  }

  /// Sign out, then immediately drop back to a fresh anonymous uid so progress keeps working
  /// locally + offline (the invariant: there is always a uid).
  Future<void> signOut() async {
    final auth = _auth;
    if (auth == null) return;
    await auth.signOut();
    try {
      await auth.signInAnonymously();
    } catch (_) {/* offline → no uid until reconnect; degrades gracefully */}
  }

  // --- Firestore paths -----------------------------------------------------
  DocumentReference<Map<String, dynamic>> _bookDoc(String bookId) => _db!
      .collection('users')
      .doc(_auth!.currentUser!.uid)
      .collection('books')
      .doc(bookId);
  CollectionReference<Map<String, dynamic>> _notesCol(String bookId) =>
      _bookDoc(bookId).collection('notes');

  // --- progress (debounced) ------------------------------------------------
  final Map<String, Map<String, dynamic>> _pending = {};
  Timer? _debounce;

  // A coarse, human-ish label so another device can show "Now playing on Android/iPhone" — not an
  // identifier (that's `device`/clientId), just for the follow indicator.
  static final String _deviceLabel = () {
    try {
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iPhone';
      return Platform.operatingSystem;
    } catch (_) {
      return 'device';
    }
  }();

  /// Record progress for a book; coalesces bursts (per-sentence ticks, fast scrubbing) into one
  /// Firestore write. Per-sentence granularity is preserved — `si` rides in the payload.
  void writeProgress(String bookId,
      {required int ci, required double t, required int si, required double frac}) {
    if (!available) return;
    _pending[bookId] = {
      'ci': ci,
      't': t,
      'si': si,
      'frac': frac,
      'updated': DateTime.now().millisecondsSinceEpoch,
      'device': settings.clientId,
      'deviceName': _deviceLabel,
    };
    _debounce?.cancel();
    // ~1s so another device's karaoke highlight follows within a sentence, while still coalescing
    // per-sentence bursts / fast scrubbing into one write (well under Firestore's ~1 write/s/doc).
    _debounce = Timer(const Duration(seconds: 1), flushProgress);
  }

  /// Write any pending progress immediately (on pause / seek / chapter change / background).
  Future<void> flushProgress() async {
    _debounce?.cancel();
    _debounce = null;
    if (!available || _pending.isEmpty) {
      _pending.clear();
      return;
    }
    final entries = Map<String, Map<String, dynamic>>.from(_pending);
    _pending.clear();
    for (final e in entries.entries) {
      try {
        await _bookDoc(e.key).set(e.value, SetOptions(merge: true));
      } catch (_) {/* offline queue handles it; a hard failure is non-fatal */}
    }
  }

  /// Read a book's progress for the open-time resume seek. Cache-first so it returns *instantly*
  /// and works offline (the on-disk cache is authoritative locally); the realtime [progressStream]
  /// then delivers any newer position from the server / another device a moment later.
  Future<Map<String, dynamic>?> readProgress(String bookId) async {
    if (!available) return null;
    try {
      final cached = await _bookDoc(bookId).get(const GetOptions(source: Source.cache));
      final d = cached.data();
      if (d != null && d['updated'] != null) return d;
    } catch (_) {/* nothing cached yet — fall through to a normal (server) read */}
    try {
      final snap = await _bookDoc(bookId).get();
      final d = snap.data();
      return (d != null && d['updated'] != null) ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// Live remote progress for one book — the realtime twin of [readProgress], mirroring
  /// `web/sync.js`'s `watchProgress`. Emits each time another device (or this one) writes a
  /// position; the caller filters its own echo via the `device` field. Empty when unavailable.
  Stream<Map<String, dynamic>> progressStream(String bookId) {
    if (!available) return const Stream.empty();
    return _bookDoc(bookId)
        .snapshots()
        .map((s) => s.data() ?? const <String, dynamic>{})
        .where((d) => d['updated'] != null);
  }

  /// Live remote progress for *every* book: `bookId -> progress map`. Powers realtime library
  /// cards / the "Continue" hero (the twin of `web/sync.js`'s `fetchAllProgress`, but streamed).
  Stream<Map<String, Map<String, dynamic>>> allProgressStream() {
    if (!available) return const Stream.empty();
    return _db!
        .collection('users')
        .doc(_auth!.currentUser!.uid)
        .collection('books')
        .snapshots()
        .map((qs) {
      final out = <String, Map<String, dynamic>>{};
      for (final doc in qs.docs) {
        final d = doc.data();
        if (d['updated'] != null) out[doc.id] = d;
      }
      return out;
    });
  }

  // --- notes ---------------------------------------------------------------
  Future<void> pushNote(String bookId, Note n) async {
    if (!available || n.id.isEmpty) return;
    try {
      await _notesCol(bookId).doc(n.id).set(n.toJson(), SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> deleteNote(String bookId, String id) async {
    if (!available || id.isEmpty) return;
    // Soft-delete: a tombstone with a fresh `updated` so the deletion wins LWW and propagates.
    // Readers filter `deleted` out before it ever reaches notes.json.
    try {
      await _notesCol(bookId).doc(id).set(
        {'id': id, 'deleted': true, 'updated': _nowIso()},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  /// All note docs for a book (raw maps, including tombstones — the caller filters `deleted`).
  Future<List<Map<String, dynamic>>> pullNotes(String bookId) async {
    if (!available) return const [];
    try {
      return (await _notesCol(bookId).get()).docs.map((d) => d.data()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Live note docs (raw maps, including tombstones).
  Stream<List<Map<String, dynamic>>> notesStream(String bookId) {
    if (!available) return const Stream.empty();
    return _notesCol(bookId)
        .snapshots()
        .map((qs) => qs.docs.map((d) => d.data()).toList());
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
