import 'alignment_types.dart';

/// Whisper-emitted word with timing. Constructed from the FFI transcribe
/// callback; the aligner is agnostic to where it comes from.
class AudioWord {
  final String text;
  final double startSeconds;
  final double endSeconds;
  final double confidence;

  const AudioWord({
    required this.text,
    required this.startSeconds,
    required this.endSeconds,
    required this.confidence,
  });

  factory AudioWord.fromJson(Map<String, dynamic> j) => AudioWord(
        text: j['t'] as String,
        startSeconds: (j['s'] as num).toDouble(),
        endSeconds: (j['e'] as num).toDouble(),
        confidence: (j['c'] as num?)?.toDouble() ?? 1.0,
      );

  // Short keys keep the transcript-cache file small — a 25h audiobook is
  // ~300k words, and `{"text": ..., "startSeconds": ...}` per entry is
  // pure overhead vs. `{"t": ..., "s": ...}`.
  Map<String, dynamic> toJson() => {
        't': text,
        's': startSeconds,
        'e': endSeconds,
        'c': confidence,
      };
}

/// Pure-logic port of `WhisperAligner` from InkAndEchoCore/Aligner.swift.
/// Takes a Whisper transcript (already produced) and the source text
/// segments, emits an AlignmentMap. No audio decoding, no FFI.
///
/// The greedy alignment: for each book word that's distinctive (length >= 5,
/// appears <= 3 times in book and 1..5 times in audio), look ahead in the
/// audio cursor for an exact normalized match. Common words like "the"/"and"
/// never anchor. Anchors that drift wildly from the median audio-per-book
/// ratio get filtered.
class Aligner {
  final String modelIdentifier;
  final int lookahead;
  static const int _searchHorizon = 800;

  const Aligner({
    this.modelIdentifier = 'openai_whisper-base.en',
    this.lookahead = 10,
  });

  AlignmentMap align({
    required List<AudioWord> audio,
    required List<TextSegment> segments,
  }) {
    final bookWords = _buildBookWords(segments);
    if (bookWords.isEmpty || audio.isEmpty) return _empty();

    final normalizedAudio = _normalizeAudio(audio);
    final (bookFreq, audioFreq) =
        _buildFrequencyMaps(bookWords, normalizedAudio);

    final anchors =
        _findAnchorPairs(bookWords, normalizedAudio, bookFreq, audioFreq);
    if (anchors.isEmpty) return _empty();

    final validated = _filterDriftedAnchors(anchors);
    final wordAnchors =
        _buildWordAnchors(validated, bookWords, normalizedAudio);
    final sentences = _deriveSentenceAnchors(wordAnchors, segments);
    final audioWordStarts =
        normalizedAudio.map((w) => w.startSeconds).toList(growable: false);

    return AlignmentMap(
      words: wordAnchors,
      sentences: sentences,
      audioWordStarts: audioWordStarts,
      createdAt: DateTime.now().toUtc(),
      modelIdentifier: modelIdentifier,
    );
  }

  List<_BookWord> _buildBookWords(List<TextSegment> segments) {
    final out = <_BookWord>[];
    for (final seg in segments) {
      final tokens = _tokenizeWords(seg.text);
      for (var idx = 0; idx < tokens.length; idx++) {
        final norm = _normalizeWord(tokens[idx]);
        if (norm.isEmpty) continue;
        out.add(_BookWord(seg.id, idx, norm));
      }
    }
    return out;
  }

  List<AudioWord> _normalizeAudio(List<AudioWord> audio) => audio
      .map((w) => AudioWord(
            text: _normalizeWord(w.text),
            startSeconds: w.startSeconds,
            endSeconds: w.endSeconds,
            confidence: w.confidence,
          ))
      .toList(growable: false);

  (Map<String, int>, Map<String, int>) _buildFrequencyMaps(
    List<_BookWord> bookWords,
    List<AudioWord> normalizedAudio,
  ) {
    final bookFreq = <String, int>{};
    for (final w in bookWords) {
      bookFreq[w.normalized] = (bookFreq[w.normalized] ?? 0) + 1;
    }
    final audioFreq = <String, int>{};
    for (final w in normalizedAudio) {
      audioFreq[w.text] = (audioFreq[w.text] ?? 0) + 1;
    }
    return (bookFreq, audioFreq);
  }

  List<WordAnchor> _buildWordAnchors(
    List<_AnchorPair> validated,
    List<_BookWord> bookWords,
    List<AudioWord> normalizedAudio,
  ) {
    final out = <WordAnchor>[];
    for (final p in validated) {
      if (p.audioIdx >= normalizedAudio.length ||
          p.bookIdx >= bookWords.length) {
        continue;
      }
      final bw = bookWords[p.bookIdx];
      final aw = normalizedAudio[p.audioIdx];
      out.add(WordAnchor(
        segmentId: bw.segmentId,
        wordIndex: bw.indexInSegment,
        startSeconds: aw.startSeconds,
        endSeconds: aw.endSeconds,
        audioIndex: p.audioIdx,
        confidence: aw.confidence,
      ));
    }
    return out;
  }

  AlignmentMap _empty() => AlignmentMap(
        words: const [],
        sentences: const [],
        audioWordStarts: const [],
        createdAt: DateTime.now().toUtc(),
        modelIdentifier: modelIdentifier,
      );

  List<_AnchorPair> _findAnchorPairs(
    List<_BookWord> bookWords,
    List<AudioWord> audio,
    Map<String, int> bookFreq,
    Map<String, int> audioFreq,
  ) {
    final pairs = <_AnchorPair>[];
    var audioCursor = 0;
    for (var bookIdx = 0; bookIdx < bookWords.length; bookIdx++) {
      final bw = bookWords[bookIdx];
      if (bw.normalized.length < 5) continue;
      final bf = bookFreq[bw.normalized];
      if (bf == null || bf > 3) continue;
      final af = audioFreq[bw.normalized];
      if (af == null || af < 1 || af > 5) continue;

      final end = audioCursor + _searchHorizon < audio.length
          ? audioCursor + _searchHorizon
          : audio.length;
      if (audioCursor >= end) break;

      var found = -1;
      for (var i = audioCursor; i < end; i++) {
        if (audio[i].text == bw.normalized) {
          found = i;
          break;
        }
      }
      if (found >= 0) {
        // Reject candidates that leap far past the position the running
        // book<->audio cadence predicts (~1 audio word per book word). A
        // far-ahead candidate means the matcher found a LATER occurrence
        // of this word (e.g. the next chapter's heading because the ASR
        // mis-heard this chapter's). Accepting it is fatal: the cursor is
        // monotonic, so every genuine match in the skipped span becomes
        // unreachable. The first anchor stays unbounded (narrator
        // preambles). 200 audio words ~= 80s still tolerates asides.
        // (Swift parity: WhisperAligner.findAnchorPairs.)
        if (pairs.isNotEmpty) {
          final last = pairs.last;
          final expected = last.audioIdx + (bookIdx - last.bookIdx);
          if (found - expected > 200) {
            continue; // skip this book word; cursor stays put
          }
        }
        pairs.add(_AnchorPair(bookIdx, found));
        audioCursor = found + 1;
      }
    }
    return pairs;
  }

  List<_AnchorPair> _filterDriftedAnchors(List<_AnchorPair> anchors) {
    if (anchors.length < 3) return anchors;

    final ratios = <double>[];
    for (var i = 1; i < anchors.length; i++) {
      final bookGap = anchors[i].bookIdx - anchors[i - 1].bookIdx;
      final audioGap = anchors[i].audioIdx - anchors[i - 1].audioIdx;
      if (bookGap <= 0) continue;
      ratios.add(audioGap / bookGap);
    }
    if (ratios.isEmpty) return anchors;

    final sorted = [...ratios]..sort();
    final median = sorted[sorted.length ~/ 2];
    final lower = median / 3.0;
    final upper = median * 3.0;

    final kept = <_AnchorPair>[anchors.first];
    for (var i = 1; i < anchors.length; i++) {
      final bookGap = anchors[i].bookIdx - kept.last.bookIdx;
      final audioGap = anchors[i].audioIdx - kept.last.audioIdx;
      if (bookGap <= 0) continue;
      final ratio = audioGap / bookGap;
      if (ratio >= lower && ratio <= upper) {
        kept.add(anchors[i]);
      }
    }
    return kept;
  }

  List<SentenceAnchor> _deriveSentenceAnchors(
    List<WordAnchor> words,
    List<TextSegment> segments,
  ) {
    final anchors = <SentenceAnchor>[];
    final wordsBySegment = <String, List<WordAnchor>>{};
    for (final w in words) {
      (wordsBySegment[w.segmentId] ??= []).add(w);
    }

    for (final seg in segments) {
      final segWords = wordsBySegment[seg.id];
      if (segWords == null || segWords.isEmpty) continue;
      final ranges = sentenceWordRanges(seg.text);
      for (var sIdx = 0; sIdx < ranges.length; sIdx++) {
        final r = ranges[sIdx];
        final inRange = segWords
            .where((w) => w.wordIndex >= r.start && w.wordIndex < r.end)
            .toList();
        if (inRange.isEmpty) continue;
        final first = inRange.reduce(
            (a, b) => a.startSeconds < b.startSeconds ? a : b);
        final last = inRange.reduce(
            (a, b) => a.endSeconds < b.endSeconds ? b : a);
        anchors.add(SentenceAnchor(
          segmentId: seg.id,
          sentenceIndex: sIdx,
          startSeconds: first.startSeconds,
          endSeconds: last.endSeconds,
        ));
      }
    }
    return anchors;
  }
}

class _BookWord {
  final String segmentId;
  final int indexInSegment;
  final String normalized;
  const _BookWord(this.segmentId, this.indexInSegment, this.normalized);
}

class _AnchorPair {
  final int bookIdx;
  final int audioIdx;
  const _AnchorPair(this.bookIdx, this.audioIdx);
}

class WordIndexRange {
  final int start;
  final int end;
  const WordIndexRange(this.start, this.end);
}

List<String> _tokenizeWords(String text) =>
    text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

final RegExp _punctOrSpace = RegExp(r'^[\s\p{P}]+|[\s\p{P}]+$', unicode: true);

/// Fold typographic apostrophes to ASCII before edge-trimming: typeset
/// EPUBs write "don’t" while Whisper emits "don't"; the interior
/// character survives trimming, so without the fold no contraction in such
/// books ever matches an audio word. (Swift parity: normalizeWord.)
String _normalizeWord(String w) => w
    .replaceAll('’', "'")
    .replaceAll('‘', "'")
    .replaceAll(_punctOrSpace, '')
    .toLowerCase();

/// Approximate sentence boundary detection. Foundation's
/// `enumerateSubstrings(.bySentences)` is locale-aware and ICU-backed; Dart's
/// stdlib has no equivalent. This regex-based version handles the common
/// English cases (`.`/`!`/`?` followed by whitespace and a capital). It will
/// diverge from Foundation on dialogue, abbreviations, and non-Latin scripts.
/// Acceptable for Phase 1 because sentence anchors only feed sentence-level
/// highlighting, which is currently disabled at non-1x rate anyway.
List<WordIndexRange> sentenceWordRanges(String text) {
  final sentenceCharRanges = <List<int>>[];
  var sentenceStart = 0;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '.' || ch == '!' || ch == '?') {
      var j = i + 1;
      while (j < text.length && (text[j] == '"' || text[j] == "'" ||
          text[j] == '”' || text[j] == '’' || text[j] == ')')) {
        j++;
      }
      final hasWs = j < text.length && _isWhitespace(text[j]);
      if (hasWs || j >= text.length) {
        sentenceCharRanges.add([sentenceStart, j]);
        while (j < text.length && _isWhitespace(text[j])) {
          j++;
        }
        sentenceStart = j;
        i = j - 1;
      }
    }
  }
  if (sentenceStart < text.length) {
    sentenceCharRanges.add([sentenceStart, text.length]);
  }

  final wordCharSpans = <List<int>>[];
  var inWord = false;
  var wordStart = 0;
  for (var i = 0; i < text.length; i++) {
    final isWs = _isWhitespace(text[i]);
    if (isWs) {
      if (inWord) {
        wordCharSpans.add([wordStart, i]);
        inWord = false;
      }
    } else if (!inWord) {
      wordStart = i;
      inWord = true;
    }
  }
  if (inWord) wordCharSpans.add([wordStart, text.length]);

  final ranges = <WordIndexRange>[];
  for (final r in sentenceCharRanges) {
    final sStart = r[0], sEnd = r[1];
    int? first;
    int? last;
    for (var idx = 0; idx < wordCharSpans.length; idx++) {
      final span = wordCharSpans[idx];
      final center = (span[0] + span[1]) ~/ 2;
      if (center >= sStart && center < sEnd) {
        first ??= idx;
        last = idx;
      }
    }
    if (first != null && last != null) {
      ranges.add(WordIndexRange(first, last + 1));
    }
  }
  return ranges;
}

bool _isWhitespace(String ch) =>
    ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ' ';
