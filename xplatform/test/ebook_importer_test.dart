import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_and_echo/import/ebook_importer.dart';

void main() {
  group('EPUBImporter against Crime and Punishment fixture', () {
    final fixture = File('test/fixtures/sample.epub');
    late ImportedBook book;

    setUpAll(() async {
      book = await const EPUBImporter().importBook(fixture);
    });

    test('extracts title and author', () {
      expect(book.title.toLowerCase(), contains('crime'));
      expect(book.author.isNotEmpty, isTrue);
      expect(book.author, isNot('Unknown'));
    });

    test('produces a non-trivial spine of segments', () {
      expect(book.segments.length, greaterThan(5),
          reason: 'a novel should have several chapters / spine items');
      for (final s in book.segments) {
        expect(s.id.isNotEmpty, isTrue);
        expect(s.text.isNotEmpty, isTrue);
      }
    });

    test('segments have stable spine-itemref ids (not auto-generated)', () {
      final ids = book.segments.map((s) => s.id).toSet();
      expect(ids.length, book.segments.length,
          reason: 'spine ids must be unique');
    });

    test('attaches chapter titles from TOC where present', () {
      final titled = book.segments.where((s) => (s.title ?? '').isNotEmpty);
      expect(titled.length, greaterThan(0),
          reason: 'TOC parsing should hit at least some segments');
    });

    test('strips HTML to plain text', () {
      for (final s in book.segments) {
        expect(s.text.contains('<'), isFalse,
            reason: 'segment "${s.id}" still contains a "<"');
        expect(s.text.contains('>'), isFalse,
            reason: 'segment "${s.id}" still contains a ">"');
      }
    });

    test('preserves paragraph breaks between block elements', () {
      final hasParagraphs =
          book.segments.any((s) => s.text.contains('\n\n'));
      expect(hasParagraphs, isTrue);
    });

    test('text is long enough to feed the aligner', () {
      final totalChars =
          book.segments.fold<int>(0, (a, s) => a + s.text.length);
      expect(totalChars, greaterThan(100000),
          reason: 'a full novel should produce >100k chars of plain text');
    });

    // Golden values below are value-identical to
    // InkAndEchoCore/Tests/InkAndEchoCoreTests/EPUBImporterTests.swift —
    // a drift in either importer breaks the shared-alignment.json
    // invariant loudly.
    String firstWords(int index) => book.segments[index].text
        .split(RegExp(r'\s+'))
        .take(6)
        .join(' ');

    test('golden: metadata and cover', () {
      expect(book.title, 'Crime and Punishment');
      expect(book.author, 'Fyodor Dostoyevsky');
      expect(book.coverImageData?.length, 69425);
      expect(book.warnings, isEmpty);
    });

    test('golden: segment ids', () {
      final ids = book.segments.map((s) => s.id).toList();
      expect(ids.length, 51);
      expect(ids[0], 'id2.1');
      expect(ids[2], 'id2.3__Toc230227608');
      expect(ids[5], 'id2.6__Toc230227611');
      expect(ids[49], 'id2.50__Toc230227657');
      expect(ids[50], 'id2.51__Toc230227658');
    });

    test('golden: TOC titles', () {
      final titles = book.segments.map((s) => s.title ?? '').toList();
      expect(titles[2], "TRANSLATOR'S PREFACE");
      expect(titles[3], 'CRIME AND PUNISHMENT');
      expect(titles[4], 'PART I');
      expect(titles[5], 'CHAPTER I');
      expect(titles[49], 'EPILOGUE');
      expect(titles[50], 'II');
    });

    test('golden: first words', () {
      expect(firstWords(0), 'CRIME AND PUNISHMENT By Fyodor Dostoevsky');
      // The head-strip golden: this file's <head><title> is "Unknown" —
      // it must NOT prepend itself to the body text.
      expect(firstWords(1), "TABLE OF CONTENTS TRANSLATOR'S PREFACE CRIME");
      expect(firstWords(2), "TRANSLATOR'S PREFACE A few words about");
      expect(firstWords(5), 'CHAPTER I On an exceptionally hot');
      expect(firstWords(9), 'CHAPTER V "Of course, I\'ve been');
      expect(firstWords(50), 'II He was ill a long');
    });

    test('golden: preamble behavior', () {
      // Anchor offsets point at the heading's opening tag, so pre-anchor
      // chrome strips to under the preamble threshold — no _preamble
      // segments for this fixture, and no empty texts anywhere.
      expect(book.segments.any((s) => s.id.endsWith('_preamble')), isFalse);
      expect(book.segments.any((s) => s.text.isEmpty), isFalse);
    });

    test('golden: total text length', () {
      // Dart String.length counts UTF-16 units — same measure the Swift
      // golden uses (text.utf16.count).
      final total = book.segments.fold<int>(0, (a, s) => a + s.text.length);
      expect(total, 1154386);
    });
  });

  group('stripHTML', () {
    test('decodes named entities', () {
      expect(stripHTML('a &amp; b &lt;c&gt;'), 'a & b <c>');
    });

    test('drops script and style blocks entirely', () {
      const html =
          '<p>before</p><script>alert(1)</script><style>body{}</style><p>after</p>';
      final out = stripHTML(html);
      expect(out.contains('alert'), isFalse);
      expect(out.contains('body'), isFalse);
      expect(out.contains('before'), isTrue);
      expect(out.contains('after'), isTrue);
    });

    test('converts <br> and block-end tags to whitespace', () {
      const html = '<p>one</p><p>two<br>three</p>';
      final out = stripHTML(html);
      expect(out.split(RegExp(r'\s+')).length, 3);
    });

    test('drops <head> and its <title> text entirely', () {
      const html = '<?xml version="1.0"?><html>'
          '<head><title>Chapter Three</title><style>p { color: red }</style></head>'
          '<body><h1>Chapter Three</h1><p>In the weeks that followed.</p></body></html>';
      expect(stripHTML(html), 'Chapter Three\n\nIn the weeks that followed.');
    });

    test('decodes numeric entities instead of stripping them', () {
      expect(stripHTML('<p>don&#8217;t</p>'), 'don’t');
      expect(stripHTML('<p>don&#x2019;t</p>'), 'don’t');
      expect(stripHTML('<p>A&#8212;B</p>'), 'A—B');
      // After the named table, so a double-escaped entity stays literal.
      expect(stripHTML('<p>&#38;amp;</p>'), '&amp;');
      // Invalid references stay as-is instead of corrupting the text.
      expect(stripHTML('<p>bad &#xD800; ref</p>'), 'bad &#xD800; ref');
      expect(stripHTML('<p>huge &#99999999999; ref</p>'), 'huge &#99999999999; ref');
    });
  });

  group('normalizeHref', () {
    test('decodes percent escapes and collapses dot segments', () {
      expect(normalizeHref('Text/chapter%201.xhtml'), 'Text/chapter 1.xhtml');
      expect(normalizeHref('Text/../Images/cover.jpg'), 'Images/cover.jpg');
      expect(normalizeHref('./Text/ch1.xhtml'), 'Text/ch1.xhtml');
      // Raw spaces survive decoding unchanged (the fixture's shape).
      expect(normalizeHref('content/CRIME AND PUNISHMENT_split_1.html'),
          'content/CRIME AND PUNISHMENT_split_1.html');
      // A literal % that isn't a valid escape keeps the raw spelling.
      expect(normalizeHref('100% proof.xhtml'), '100% proof.xhtml');
      // Leading ../ can't collapse further; the join with opfDir does it.
      expect(normalizeHref('../Text/ch1.xhtml'), '../Text/ch1.xhtml');
    });
  });
}
