import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_and_echo/state/library_store.dart';

void main() {
  group('orderedAudioParts', () {
    // Files don't exist, so the track-tag probe fails for every part and
    // ordering falls back to natural filename sort — digit runs compare
    // numerically without zero-padding.
    test('falls back to natural filename sort without track tags', () async {
      final store = LibraryStore();
      final parts = [
        File('/nonexistent/Part 10.mp3'),
        File('/nonexistent/Part 2.mp3'),
        File('/nonexistent/part 1.mp3'),
      ];
      final ordered = await store.orderedAudioParts(parts);
      expect(
        [for (final f in ordered) f.uri.pathSegments.last],
        ['part 1.mp3', 'Part 2.mp3', 'Part 10.mp3'],
      );
    });

    test('single part passes through untouched', () async {
      final store = LibraryStore();
      final parts = [File('/nonexistent/whole-book.m4b')];
      expect(await store.orderedAudioParts(parts), parts);
    });
  });
}
