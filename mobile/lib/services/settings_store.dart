import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Resume point for a book: chapter list-position + chapter-relative seconds.
/// Mirrors the web player's `{ci, t}` shape stored under `abk:pos:<bookId>`.
class SavedPosition {
  final int chapterIndex;
  final double time;
  const SavedPosition(this.chapterIndex, this.time);
}

/// Thin wrapper over SharedPreferences for the few persisted values, mirroring the web
/// player's keys (rate / volume / per-book position) plus the remembered server URL.
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

  SavedPosition? loadPosition(String bookId) {
    final raw = _p.getString('pos:$bookId');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return SavedPosition((j['ci'] as num).toInt(), (j['t'] as num).toDouble());
    } catch (_) {
      return null;
    }
  }

  void savePosition(String bookId, int chapterIndex, double time) =>
      _p.setString('pos:$bookId', jsonEncode({'ci': chapterIndex, 't': time}));

  void clearPosition(String bookId) => _p.remove('pos:$bookId');
}
