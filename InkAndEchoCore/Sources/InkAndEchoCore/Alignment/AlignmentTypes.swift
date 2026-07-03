import Foundation

/// Input to an aligner: the ebook's text broken into addressable segments
/// (typically chapters or paragraphs). The `id` is a stable identifier
/// — for EPUB-sourced text this is an EPUB CFI; for plaintext it can be
/// any deterministic string.
public struct AlignmentInput: Sendable {
    public let segments: [TextSegment]
    public init(segments: [TextSegment]) { self.segments = segments }
}

public struct TextSegment: Sendable, Hashable {
    public let id: String
    public let title: String?
    public let text: String
    public init(id: String, title: String? = nil, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// The output of alignment: timestamps anchored back to the source text.
/// Both word- and sentence-level maps are produced from one alignment pass
/// so the reader can toggle granularity without re-running Whisper.
public struct AlignmentMap: Codable, Sendable {
    public let words: [WordAnchor]
    public let sentences: [SentenceAnchor]
    /// Per-audio-word start timestamps from Whisper, in order. Each entry's
    /// index matches the `audioIndex` used by `WordAnchor` so the reader can
    /// project audio time onto book word position at the narrator's actual
    /// pace instead of uniform time-to-word linear interpolation.
    public let audioWordStarts: [Double]
    /// Dense per-book-word start times for read-along highlighting (one entry
    /// per chapter). Empty on pre-dense caches; the reader treats an empty
    /// `wordTimes` with non-empty `words` as "needs re-align".
    public let wordTimes: [SegmentWordTimes]
    public let createdAt: Date
    public let modelIdentifier: String

    public init(
        words: [WordAnchor],
        sentences: [SentenceAnchor],
        audioWordStarts: [Double] = [],
        wordTimes: [SegmentWordTimes] = [],
        createdAt: Date,
        modelIdentifier: String
    ) {
        self.words = words
        self.sentences = sentences
        self.audioWordStarts = audioWordStarts
        self.wordTimes = wordTimes
        self.createdAt = createdAt
        self.modelIdentifier = modelIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case words, sentences, audioWordStarts, wordTimes, createdAt, modelIdentifier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.words = try c.decode([WordAnchor].self, forKey: .words)
        self.sentences = try c.decode([SentenceAnchor].self, forKey: .sentences)
        self.audioWordStarts = (try? c.decode([Double].self, forKey: .audioWordStarts)) ?? []
        self.wordTimes = (try? c.decode([SegmentWordTimes].self, forKey: .wordTimes)) ?? []
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.modelIdentifier = try c.decode(String.self, forKey: .modelIdentifier)
    }
}

public struct WordAnchor: Codable, Sendable, Hashable {
    public let segmentId: String
    public let wordIndex: Int
    public let startSeconds: Double
    public let endSeconds: Double
    /// Index into `AlignmentMap.audioWordStarts` where this anchor was matched.
    /// Lets the reader project audio time onto book wordIndex at narrator pace.
    public let audioIndex: Int
    /// 0.0 – 1.0. Below ~0.5, the reader should fall back to sentence highlighting.
    public let confidence: Float

    public init(
        segmentId: String,
        wordIndex: Int,
        startSeconds: Double,
        endSeconds: Double,
        audioIndex: Int = -1,
        confidence: Float
    ) {
        self.segmentId = segmentId
        self.wordIndex = wordIndex
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.audioIndex = audioIndex
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case segmentId, wordIndex, startSeconds, endSeconds, audioIndex, confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.segmentId = try c.decode(String.self, forKey: .segmentId)
        self.wordIndex = try c.decode(Int.self, forKey: .wordIndex)
        self.startSeconds = try c.decode(Double.self, forKey: .startSeconds)
        self.endSeconds = try c.decode(Double.self, forKey: .endSeconds)
        self.audioIndex = (try? c.decode(Int.self, forKey: .audioIndex)) ?? -1
        self.confidence = try c.decode(Float.self, forKey: .confidence)
    }
}

public struct SentenceAnchor: Codable, Sendable, Hashable {
    public let segmentId: String
    public let sentenceIndex: Int
    public let startSeconds: Double
    public let endSeconds: Double

    public init(segmentId: String, sentenceIndex: Int, startSeconds: Double, endSeconds: Double) {
        self.segmentId = segmentId
        self.sentenceIndex = sentenceIndex
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Dense per-book-word start times for one chapter, for read-along
/// highlighting. `wordIndices[i]` (the segment-local token index the reader
/// looks up) begins being narrated at `starts[i]`. Stored as parallel arrays
/// so the long segment id isn't repeated per word. Within a chapter the
/// arrays are in book order, which is increasing time; chapters are stored in
/// reading order, so concatenating all chapters yields one globally
/// time-sorted sequence the reader can binary-search.
public struct SegmentWordTimes: Codable, Sendable, Hashable {
    public let segmentId: String
    public let wordIndices: [Int]
    public let starts: [Double]
    /// Fraction of this chapter's words that matched REAL transcript words
    /// (the rest were interpolated or omitted) — the aligner's per-chapter
    /// confidence. nil on maps written before the field existed; treat as
    /// trustworthy (decode-with-default, same pattern as `AlignmentMap`).
    public let matchedFraction: Double?

    public init(segmentId: String, wordIndices: [Int], starts: [Double], matchedFraction: Double? = nil) {
        self.segmentId = segmentId
        self.wordIndices = wordIndices
        self.starts = starts
        self.matchedFraction = matchedFraction
    }

    private enum CodingKeys: String, CodingKey {
        case segmentId, wordIndices, starts, matchedFraction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.segmentId = try c.decode(String.self, forKey: .segmentId)
        self.wordIndices = try c.decode([Int].self, forKey: .wordIndices)
        self.starts = try c.decode([Double].self, forKey: .starts)
        self.matchedFraction = try? c.decode(Double.self, forKey: .matchedFraction)
    }
}

public extension AlignmentMap {
    /// Below this matched fraction a chapter's word times are more likely to
    /// mislead than help — surface a warning and disable word highlighting.
    static let roughMatchThreshold = 0.5

    /// Chapters whose matched fraction falls under `threshold`. Pre-confidence
    /// maps (nil fractions) report none.
    func roughSegmentIDs(threshold: Double = roughMatchThreshold) -> Set<String> {
        Set(wordTimes.filter { ($0.matchedFraction ?? 1) < threshold }.map(\.segmentId))
    }

    /// Word-count-weighted matched fraction across all chapters; nil when no
    /// chapter carries confidence data (pre-confidence maps).
    var overallMatchedFraction: Double? {
        var weighted = 0.0
        var total = 0
        for swt in wordTimes {
            guard let fraction = swt.matchedFraction else { continue }
            weighted += fraction * Double(swt.wordIndices.count)
            total += swt.wordIndices.count
        }
        guard total > 0 else { return nil }
        return weighted / Double(total)
    }
}
