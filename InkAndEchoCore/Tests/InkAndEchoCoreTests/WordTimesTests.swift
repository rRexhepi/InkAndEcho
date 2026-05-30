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

    @Test func emptyWithoutAnchors() {
        let aligner = WhisperAligner()
        let book = [bw("s1", 0, "a")]
        let audio = [aw("a", 0)]
        #expect(aligner.computeWordTimes(bookWords: book, audio: audio, anchors: []).isEmpty)
    }
}
