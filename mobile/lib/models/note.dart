/// Dart mirror of the desktop note record (`app/notes.py`). Field names and terse keys match
/// the server's `notes.json`, so a bundled notes file (shipped inside an `.abk`) loads
/// directly and a LAN sync round-trips without transformation.
library;

import 'dart:convert';

int _toInt(dynamic v) => v == null ? 0 : (v as num).toInt();
double _toDouble(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

/// One note or highlight. A highlight is a note with an empty [note] body. Anchors to a
/// sentence range `[si..sj]` in chapter [ch], with a durable text quote ([exact] +
/// [prefix]/[suffix]) plus fast-path hints (indices, char offsets, audio seconds).
class Note {
  final String id;
  final String kind; // "highlight" | "note"
  final int ch; // chapter index
  final int si; // start sentence index
  final int sj; // end sentence index (== si for a single sentence)
  final int cs; // char offset start (pass-through metadata)
  final int ce; // char offset end
  final double s; // audio start (seconds)
  final double e; // audio end (seconds)
  final String exact; // durable quote (source of truth)
  final String prefix; // ~32 chars before, for re-anchoring
  final String suffix; // ~32 chars after
  final String color; // yellow|green|blue|pink|purple
  final List<String> tags;
  final String note; // body; "" => bare highlight
  final String created;
  final String updated;

  const Note({
    required this.id,
    required this.kind,
    required this.ch,
    required this.si,
    required this.sj,
    required this.cs,
    required this.ce,
    required this.s,
    required this.e,
    required this.exact,
    required this.prefix,
    required this.suffix,
    required this.color,
    required this.tags,
    required this.note,
    required this.created,
    required this.updated,
  });

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: (j['id'] ?? '') as String,
        kind: (j['kind'] ?? 'note') as String,
        ch: _toInt(j['ch']),
        si: _toInt(j['si']),
        sj: _toInt(j['sj']),
        cs: _toInt(j['cs']),
        ce: _toInt(j['ce']),
        s: _toDouble(j['s']),
        e: _toDouble(j['e']),
        exact: (j['exact'] ?? '') as String,
        prefix: (j['prefix'] ?? '') as String,
        suffix: (j['suffix'] ?? '') as String,
        color: (j['color'] ?? 'yellow') as String,
        tags: ((j['tags'] ?? const []) as List).map((t) => t.toString()).toList(),
        note: (j['note'] ?? '') as String,
        created: (j['created'] ?? '') as String,
        updated: (j['updated'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'ch': ch,
        'si': si,
        'sj': sj,
        'cs': cs,
        'ce': ce,
        's': s,
        'e': e,
        'exact': exact,
        'prefix': prefix,
        'suffix': suffix,
        'color': color,
        'tags': tags,
        'note': note,
        'created': created,
        'updated': updated,
      };

  Note copyWith({
    String? kind,
    String? color,
    List<String>? tags,
    String? note,
    String? updated,
  }) =>
      Note(
        id: id,
        kind: kind ?? this.kind,
        ch: ch,
        si: si,
        sj: sj,
        cs: cs,
        ce: ce,
        s: s,
        e: e,
        exact: exact,
        prefix: prefix,
        suffix: suffix,
        color: color ?? this.color,
        tags: tags ?? this.tags,
        note: note ?? this.note,
        created: created,
        updated: updated ?? this.updated,
      );

  /// Parse either a full `{book, version, notes:[...]}` document or a bare notes array.
  static List<Note> listFromDoc(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    final list = (decoded is Map ? decoded['notes'] : decoded) as List? ?? const [];
    return list
        .map((j) => Note.fromJson(j as Map<String, dynamic>))
        .toList();
  }
}
