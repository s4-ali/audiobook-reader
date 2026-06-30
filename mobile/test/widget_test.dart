import 'package:audiobook_player/models/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('manifest parsing', () {
    const json = '''
    {
      "id": "the-light",
      "title": "The Light",
      "author": "A. Writer",
      "voice": "am_michael",
      "speed": 1.0,
      "status": "ready",
      "chapters_total": 1,
      "chapters_ready": 1,
      "total_duration": 12.5,
      "chapters": [
        {
          "id": "ch0000", "index": 0, "title": "Chapter 1", "level": 1,
          "status": "ready", "audio": "ch0000.mp3", "duration": 12.5,
          "start_global": 0.0,
          "topics": [{"title": "A topic", "level": 2, "time": 5.0}],
          "sentences": [
            {"i": 0, "t": "First.", "s": 0.0, "e": 2.0, "cs": 0, "ce": 6, "p": 1},
            {"i": 1, "t": "Second.", "s": 2.0, "e": 5.0, "cs": 7, "ce": 14},
            {"i": 2, "t": "Third.", "s": 5.0, "e": 12.5, "cs": 15, "ce": 21}
          ]
        }
      ]
    }
    ''';

    test('parses top-level + chapter + sentence fields', () {
      final book = Book.parse(json);
      expect(book.id, 'the-light');
      expect(book.title, 'The Light');
      expect(book.chapters, hasLength(1));

      final ch = book.chapters.first;
      expect(ch.isReady, isTrue);
      expect(ch.audio, 'ch0000.mp3');
      expect(ch.topics.single.time, 5.0);
      expect(ch.sentences, hasLength(3));

      final s0 = ch.sentences.first;
      expect(s0.t, 'First.');
      expect(s0.s, 0.0);
      expect(s0.paragraph, isTrue); // p == 1
      expect(ch.sentences[1].paragraph, isFalse); // p absent
    });

    test('isReady treats a missing chapter status as ready (web parity)', () {
      final book = Book.parse(
          '{"id":"x","chapters":[{"id":"ch0000","index":0,"title":"C","audio":"ch0000.mp3"}]}');
      expect(book.chapters.single.isReady, isTrue);
    });
  });

  group('findActiveSentence (binary search)', () {
    final sentences = [
      const Sentence(i: 0, t: 'a', s: 0.0, e: 2.0, cs: 0, ce: 1, paragraph: false),
      const Sentence(i: 1, t: 'b', s: 2.0, e: 5.0, cs: 0, ce: 1, paragraph: false),
      const Sentence(i: 2, t: 'c', s: 5.0, e: 12.5, cs: 0, ce: 1, paragraph: false),
    ];

    test('returns -1 before the first sentence start', () {
      expect(findActiveSentence(sentences, -0.5), -1);
    });

    test('returns the greatest index whose start <= t', () {
      expect(findActiveSentence(sentences, 0.0), 0);
      expect(findActiveSentence(sentences, 1.9), 0);
      expect(findActiveSentence(sentences, 2.0), 1);
      expect(findActiveSentence(sentences, 4.9), 1);
      expect(findActiveSentence(sentences, 5.0), 2);
      expect(findActiveSentence(sentences, 999.0), 2);
    });

    test('empty list returns -1', () {
      expect(findActiveSentence(const [], 1.0), -1);
    });
  });
}
