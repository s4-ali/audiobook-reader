import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Resume point for a book: chapter list-position + chapter-relative seconds, the active
/// sentence index, plus overall progress (0..1) and a save timestamp. Mirrors the Firestore
/// progress doc's `{ci, t, si, frac, updated}` shape — the single source of truth now that there
/// is no local progress file. This is an in-memory value the library cards + reader resume from.
class SavedPosition {
  final int chapterIndex;
  final double time;
  final int sentenceIndex; // per-sentence resume point (-1 if unknown)
  final double frac; // overall progress across the whole book, 0..1
  final int updated; // ms since epoch — orders books for "Continue listening"
  const SavedPosition(this.chapterIndex, this.time,
      {this.sentenceIndex = -1, this.frac = 0, this.updated = 0});

  /// Build from a Firestore progress map (`{ci,t,si,frac,updated}`).
  factory SavedPosition.fromRemote(Map<String, dynamic> d) => SavedPosition(
        (d['ci'] as num?)?.toInt() ?? 0,
        (d['t'] as num?)?.toDouble() ?? 0,
        sentenceIndex: (d['si'] as num?)?.toInt() ?? -1,
        frac: (d['frac'] as num?)?.toDouble() ?? 0,
        updated: (d['updated'] as num?)?.toInt() ?? 0,
      );

  /// Heard to the end — the library offers a fresh start rather than resume.
  bool get finished => frac >= 0.999;
}

/// Thin wrapper over SharedPreferences for the few persisted *device* values (rate / volume /
/// reader theme / remembered server URL / a stable client id). Reading progress is deliberately
/// **not** here anymore — it lives only in Firestore (+ its offline cache); see [SyncStore].
class SettingsStore {
  final SharedPreferences _p;
  SettingsStore(this._p);

  static Future<SettingsStore> create() async =>
      SettingsStore(await SharedPreferences.getInstance());

  double get rate => _p.getDouble('rate') ?? 1.0;
  set rate(double v) => _p.setDouble('rate', v);

  double get volume => _p.getDouble('vol') ?? 1.0;
  set volume(double v) => _p.setDouble('vol', v);

  String? get serverUrl => _p.getString('server');
  set serverUrl(String? v) =>
      v == null ? _p.remove('server') : _p.setString('server', v);

  /// Reader theme id ('dark' | 'sepia' | 'light'), mirroring the web player's `abk:theme`.
  /// Defaults to 'dark' so an existing install keeps its current look.
  String get themeId => _p.getString('theme') ?? 'dark';
  set themeId(String v) => _p.setString('theme', v);

  /// A stable per-device id, so cloud progress writes can recognize (and ignore) their own
  /// echo when they come back through the Firestore listener. Created on first use.
  String get clientId {
    var id = _p.getString('clientId');
    if (id == null) {
      id = const Uuid().v4();
      _p.setString('clientId', id);
    }
    return id;
  }
}
