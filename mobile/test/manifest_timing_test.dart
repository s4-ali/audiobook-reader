import 'dart:convert';

import 'package:audiobook_player/models/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

// The load-time timing upgrade must match the desktop's ingest.settle_manifest exactly:
// legacy manifests (timing_version < 2) get each sentence start pulled back halfway into
// the preceding pause (capped at 250 ms); already-settled manifests pass through untouched.
void main() {
  Map<String, dynamic> legacy() => {
        'id': 'b',
        'chapters': [
          {
            'id': 'ch0000',
            'index': 0,
            'title': 'One',
            'audio': 'ch0000.mp3',
            'sentences': [
              {'i': 0, 't': 'a', 's': 0.31, 'e': 2.5, 'cs': 0, 'ce': 1},
              // 240 ms pause -> lead 120 ms
              {'i': 1, 't': 'b', 's': 2.74, 'e': 5.0, 'cs': 2, 'ce': 3},
              // 900 ms pause -> lead capped at 250 ms
              {'i': 2, 't': 'c', 's': 5.9, 'e': 8.0, 'cs': 4, 'ce': 5},
              // zero-width unalignable sentence stays put
              {'i': 3, 't': 'd', 's': 8.0, 'e': 8.0, 'cs': 6, 'ce': 7},
            ],
            'topics': [
              {'title': 'x', 'level': 2, 'time': 2.74},
            ],
          },
        ],
      };

  test('legacy manifest is settled at load, topics remapped', () {
    final b = Book.parse(jsonEncode(legacy()));
    final starts = b.chapters[0].sentences.map((s) => s.s).toList();
    expect(starts, [0.155, 2.62, 5.65, 8.0]);
    expect(b.chapters[0].topics[0].time, 2.62);
  });

  test('timing_version 2 manifest passes through unchanged', () {
    final j = legacy()..['timing_version'] = 2;
    final b = Book.parse(jsonEncode(j));
    expect(b.chapters[0].sentences.map((s) => s.s).toList(), [0.31, 2.74, 5.9, 8.0]);
    expect(b.chapters[0].topics[0].time, 2.74);
  });

  test('findActiveSentence flips mid-pause at the settled boundary', () {
    final b = Book.parse(jsonEncode(legacy()));
    final sents = b.chapters[0].sentences;
    // Boundary settled to 2.62, raw speech onset at 2.74: the flip happens inside the
    // pause, so by the time sentence 1's audio is audible its highlight is already set,
    // and a frame-early landing after a tap-seek plays only silence, never sentence 0.
    expect(findActiveSentence(sents, 2.61), 0);
    expect(findActiveSentence(sents, 2.62), 1);
    expect(findActiveSentence(sents, 2.74), 1);
  });
}
