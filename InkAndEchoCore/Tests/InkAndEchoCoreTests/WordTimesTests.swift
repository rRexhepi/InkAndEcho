import Testing
@testable import InkAndEchoCore

/// Validates the dense per-word gap-fill that drives skip-free read-along
/// highlighting, on synthetic data — so the algorithm can be checked without a
/// 20-minute Whisper re-align.
@Suite("WordTimes gap-fill")
struct WordTimesTests {
    private func bw(_ seg: String, _ idx: Int, _ norm: String) -> BookWord {
        BookWord(segmentId: seg, indexInSegment: idx, normalized: norm)
    }
    private func aw(_ text: String, _ start: Double) -> AudioWord {
        AudioWord(text: text, startSeconds: start, endSeconds: start + 0.4, confidence: 1)
    }

    /// The core guarantee: every book word gets a time even when the audio has
    /// fewer recognized words in the gap (the old interpolation skipped these),
    /// matched words keep their real audio time, and times stay strictly
    /// increasing so each word owns a distinct slice.
    @Test func fillsEveryWordWithoutSkippingAndStaysMonotonic() {
        let aligner = WhisperAligner()
        let book = [
            bw("s1", 0, "alpha"),
            bw("s1", 1, "beta"),     // missing from the audio (ASR skip)
            bw("s1", 2, "gamma"),
            bw("s1", 3, "delta"),    // falls past the gap's matched cursor
            bw("s1", 4, "epsilon"),
        ]
        let audio = [aw("alpha", 0), aw("gamma", 4), aw("epsilon", 8)]
        let anchors = [(bookIdx: 0, audioIdx: 0), (bookIdx: 4, audioIdx: 2)]

        let result = aligner.computeWordTimes(bookWords: book, audio: audio, anchors: anchors)

        #expect(result.count == 1)
        let s = result[0]
        #expect(s.segmentId == "s1")
        #expect(s.wordIndices == [0, 1, 2, 3, 4])   // dense: nothing skipped
        #expect(s.starts.count == 5)
        #expect(abs(s.starts[0] - 0) < 1e-6)        // anchor, real time
        #expect(abs(s.starts[2] - 4) < 1e-6)        // matched inside the gap, real time
        #expect(abs(s.starts[4] - 8) < 1e-6)        // anchor, real time
        #expect(abs(s.starts[1] - 2) < 1e-6)        // interpolated between 0 and 4
        #expect(abs(s.starts[3] - 6) < 1e-6)        // interpolated between 4 and 8
        for i in 1..<s.starts.count {
            #expect(s.starts[i] > s.starts[i - 1])
        }
    }

    /// Book words are grouped into one entry per chapter, in reading order, and
    /// the concatenation is globally time-sorted (what the reader binary-searches).
    @Test func groupsByChapterInGlobalTimeOrder() {
        let aligner = WhisperAligner()
        let book = [
            bw("c1", 0, "one"),
            bw("c1", 1, "two"),
            bw("c2", 0, "three"),
            bw("c2", 1, "four"),
        ]
        let audio = [aw("one", 0), aw("two", 1), aw("three", 2), aw("four", 3)]
        let anchors = [(bookIdx: 0, audioIdx: 0), (bookIdx: 3, audioIdx: 3)]

        let result = aligner.computeWordTimes(bookWords: book, audio: audio, anchors: anchors)

        #expect(result.count == 2)
        #expect(result[0].segmentId == "c1")
        #expect(result[1].segmentId == "c2")
        #expect(result[0].wordIndices == [0, 1])
        #expect(result[1].wordIndices == [0, 1])
        let allStarts = result.flatMap { $0.starts }
        for i in 1..<allStarts.count {
            #expect(allStarts[i] > allStarts[i - 1])
        }
    }

    /// Words before the first anchor (front matter the narrator skips) must
    /// not displace the anchor itself: the head run fills backward, so the
    /// first matched word keeps its exact audio time and the monotonic fixup
    /// has nothing to cascade through.
    @Test func headRunDoesNotShiftFirstAnchor() {
        let aligner = WhisperAligner()
        let book = [
            bw("front", 0, "title"),
            bw("front", 1, "copyright"),
            bw("front", 2, "contents"),
            bw("c1", 0, "opening"),
            bw("c1", 1, "line"),
        ]
        let audio = [aw("opening", 5), aw("line", 6)]
        let anchors = [(bookIdx: 3, audioIdx: 0), (bookIdx: 4, audioIdx: 1)]

        let result = aligner.computeWordTimes(bookWords: book, audio: audio, anchors: anchors)

        #expect(result.count == 2)
        let all = result.flatMap { $0.starts }
        #expect(abs(all[3] - 5) < 1e-9)             // anchor keeps its exact time
        #expect(abs(all[4] - 6) < 1e-9)
        for i in 1..<all.count {                    // still strictly increasing
            #expect(all[i] > all[i - 1])
        }
        #expect(all[2] < 5)                         // head run stays before the anchor
    }

    @Test func emptyWithoutAnchors() {
        let aligner = WhisperAligner()
        let book = [bw("s1", 0, "a")]
        let audio = [aw("a", 0)]
        #expect(aligner.computeWordTimes(bookWords: book, audio: audio, anchors: []).isEmpty)
    }
}

/// The chunk-seam dedup: each 5-minute chunk loads 2 s past its boundary, so
/// the NEXT chunk's first words re-transcribe that zone and must be dropped
/// when they match an already-emitted word.
@Suite("Chunk seam dedup")
struct SeamDedupTests {
    private func aw(_ text: String, _ start: Double) -> AudioWord {
        AudioWord(text: text, startSeconds: start, endSeconds: start + 0.3, confidence: 1)
    }

    @Test func dropsReTranscriptionInOverlapZone() {
        // Chunk 1 (start 300) re-hears "harbor" at 300.4; chunk 0's tail
        // overlap already emitted it at 300.5.
        let recent = [aw("the", 299.2), aw("quiet", 299.7), aw("harbor", 300.5)]
        #expect(WhisperAligner.isSeamDuplicate(
            text: "harbor", startSeconds: 300.4, chunkStart: 300, recent: recent[...]
        ))
    }

    @Test func keepsGenuinelyNewWordInOverlapZone() {
        // Same zone, but the earlier chunk never emitted this word (its tail
        // was silence or it missed it) — keep it.
        let recent = [aw("the", 299.2), aw("quiet", 299.7)]
        #expect(!WhisperAligner.isSeamDuplicate(
            text: "harbor", startSeconds: 300.4, chunkStart: 300, recent: recent[...]
        ))
    }

    @Test func keepsSameWordOutsideTimeTolerance() {
        // Same text but 1.2 s away — a real repeated word, not a seam echo.
        let recent = [aw("harbor", 299.0)]
        #expect(!WhisperAligner.isSeamDuplicate(
            text: "harbor", startSeconds: 300.2, chunkStart: 300, recent: recent[...]
        ))
    }

    @Test func neverDropsPastTheOverlapZone() {
        // 300 + 2 s overlap = zone ends at 302; word at 302.4 is normal.
        let recent = [aw("harbor", 302.3)]
        #expect(!WhisperAligner.isSeamDuplicate(
            text: "harbor", startSeconds: 302.4, chunkStart: 300, recent: recent[...]
        ))
    }

    @Test func firstChunkNeverDedupes() {
        let recent = [aw("harbor", 0.4)]
        #expect(!WhisperAligner.isSeamDuplicate(
            text: "harbor", startSeconds: 0.6, chunkStart: 0, recent: recent[...]
        ))
    }
}
