import Foundation
import AVFoundation
import WhisperKit

/// Aligns audiobook narration to ebook text, producing a single AlignmentMap
/// containing both word- and sentence-level anchors.
///
/// Implementations are expected to be pure functions of (audio, text) → map,
/// suitable for caching to disk per book.
public protocol AudioTextAligner: Sendable {
    func align(audioURL: URL, input: AlignmentInput) async throws -> AlignmentMap
}

/// Default aligner: WhisperKit transcription with word-level timestamps,
/// then a streaming-greedy alignment of the transcript against the source text.
///
/// The greedy alignment is intentionally simple: for each book word, look up to
/// `lookahead` audio words ahead for a normalized match. When the narrator
/// adds filler ("uh", "um") or paraphrases briefly, the audio cursor advances
/// over the noise; when the narrator skips a book passage, that book word
/// simply receives no anchor and the next match resyncs the stream.
///
/// This won't beat full DTW with phonetic similarity, but it's correct enough
/// for sentence-level highlighting on most narrated audiobooks and ships
/// without external alignment models.
public struct WhisperAligner: AudioTextAligner {
    public let modelIdentifier: String

    /// `base.en`: ~16× realtime on Apple silicon via Core ML + ANE; meaningfully
    /// better word recognition than tiny.en. Override for heavier models.
    public init(modelIdentifier: String = "openai_whisper-base.en") {
        self.modelIdentifier = modelIdentifier
    }

    public func align(audioURL: URL, input: AlignmentInput) async throws -> AlignmentMap {
        try await align(audioURL: audioURL, input: input) { _ in }
    }

    /// Align with a progress callback. The callback is invoked from a background
    /// thread; the caller is responsible for hopping to the main actor before
    /// touching UI state.
    public func align(
        audioURL: URL,
        input: AlignmentInput,
        progress: @Sendable @escaping (AlignmentStage) -> Void
    ) async throws -> AlignmentMap {
        let totalAudioSeconds: Double = {
            guard let file = try? AVAudioFile(forReading: audioURL),
                  file.processingFormat.sampleRate > 0 else { return 0 }
            return Double(file.length) / file.processingFormat.sampleRate
        }()

        progress(.loadingModel(model: modelIdentifier))
        let pipe: WhisperKit
        do {
            pipe = try await WhisperKit(WhisperKitConfig(model: modelIdentifier))
        } catch {
            throw AlignerError.modelNotFound(
                "Could not load Whisper model '\(modelIdentifier)': \(error.localizedDescription)"
            )
        }

        progress(.transcribing(snippet: nil, fraction: 0, etaSeconds: nil))
        let options = DecodingOptions(wordTimestamps: true)

        let chunkLengthSeconds: Double = 30.0
        let transcribeStart = Date()

        let callback: TranscriptionCallback = { partial in
            let snippet = String(partial.text.suffix(80))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // windowId is 0-based; +1 = number of chunks processed.
            let processedAudio = min(
                totalAudioSeconds > 0 ? totalAudioSeconds : .infinity,
                Double(partial.windowId + 1) * chunkLengthSeconds
            )
            let fraction: Double? = totalAudioSeconds > 0
                ? min(1.0, processedAudio / totalAudioSeconds)
                : nil

            let elapsed = Date().timeIntervalSince(transcribeStart)
            let speed = elapsed > 0.5 ? processedAudio / elapsed : 0  // audio-sec per wall-sec
            let remainingAudio = max(0, totalAudioSeconds - processedAudio)
            let eta: TimeInterval? = (speed > 0 && totalAudioSeconds > 0 && remainingAudio > 0)
                ? remainingAudio / speed
                : nil

            progress(.transcribing(
                snippet: snippet.isEmpty ? nil : snippet,
                fraction: fraction,
                etaSeconds: eta
            ))
            return nil
        }

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options,
                callback: callback
            )
        } catch {
            throw AlignerError.transcriptionFailed(error.localizedDescription)
        }

        progress(.aligning)
        let audioWords = results.flatMap { result in
            result.segments.flatMap { (seg: TranscriptionSegment) -> [AudioWord] in
                (seg.words ?? []).map { word in
                    AudioWord(
                        text: normalizeWord(word.word),
                        startSeconds: Double(word.start),
                        endSeconds: Double(word.end),
                        confidence: Float(word.probability)
                    )
                }
            }
        }

        let map = alignWords(audio: audioWords, segments: input.segments)
        progress(.complete(wordsAligned: map.words.count, sentencesAligned: map.sentences.count))
        return map
    }

    // MARK: - Greedy alignment

    private func alignWords(audio: [AudioWord], segments: [TextSegment]) -> AlignmentMap {
        // Flatten book words with their (segmentId, segmentLocalIndex) labels.
        // Local index here matches the wordIndex the reader's UI looks up.
        var bookWords: [BookWord] = []
        for segment in segments {
            let tokens = tokenizeWords(segment.text)
            for (idx, raw) in tokens.enumerated() {
                let norm = normalizeWord(raw)
                guard !norm.isEmpty else { continue }
                bookWords.append(BookWord(
                    segmentId: segment.id,
                    indexInSegment: idx,
                    normalized: norm
                ))
            }
        }
        guard !bookWords.isEmpty, !audio.isEmpty else {
            return emptyMap()
        }

        // Frequency maps drive anchor selection. We want words that are rare in
        // BOTH sequences (so they're distinctive landmarks) and identical when
        // normalized.
        var bookFreq: [String: Int] = [:]
        for w in bookWords { bookFreq[w.normalized, default: 0] += 1 }
        var audioFreq: [String: Int] = [:]
        for w in audio { audioFreq[w.text, default: 0] += 1 }

        // Find ordered (bookIdx, audioIdx) anchor pairs.
        let anchors = findAnchorPairs(
            bookWords: bookWords,
            audio: audio,
            bookFreq: bookFreq,
            audioFreq: audioFreq
        )

        guard !anchors.isEmpty else {
            return emptyMap()
        }

        // Reject anchors whose ratio of audio-words-per-book-word diverges
        // wildly from neighbors — these are usually false matches that would
        // poison nearby alignments.
        let validated = filterDriftedAnchors(anchors)

        // Emit a WordAnchor only at the actual match points. We don't try to
        // interpolate timestamps for in-between words: even small errors in
        // anchor positions blow out into seconds-or-minutes drift over the
        // course of a chapter, which the user experiences as completely wrong
        // playback positions. The reader's nearest-anchor fallback covers the
        // gaps for click-to-seek, and the sentence highlighter only fires
        // when an anchor actually lands inside a sentence.
        var wordAnchors: [WordAnchor] = []
        for pair in validated {
            guard pair.audioIdx < audio.count, pair.bookIdx < bookWords.count else { continue }
            let bw = bookWords[pair.bookIdx]
            let aw = audio[pair.audioIdx]
            wordAnchors.append(WordAnchor(
                segmentId: bw.segmentId,
                wordIndex: bw.indexInSegment,
                startSeconds: aw.startSeconds,
                endSeconds: aw.endSeconds,
                audioIndex: pair.audioIdx,
                confidence: aw.confidence
            ))
        }

        let sentences = deriveSentenceAnchors(words: wordAnchors, segments: segments)
        let audioWordStarts = audio.map { $0.startSeconds }

        return AlignmentMap(
            words: wordAnchors,
            sentences: sentences,
            audioWordStarts: audioWordStarts,
            createdAt: .now,
            modelIdentifier: modelIdentifier
        )
    }

    /// Drop anchors whose local audio-per-book ratio is wildly off (>3× or
    /// <0.33×) compared to the global median. These are almost always false
    /// matches caused by common-enough book words appearing earlier in the
    /// audio than they should.
    private func filterDriftedAnchors(_ anchors: [(bookIdx: Int, audioIdx: Int)]) -> [(bookIdx: Int, audioIdx: Int)] {
        guard anchors.count >= 3 else { return anchors }

        var ratios: [Double] = []
        for i in 1..<anchors.count {
            let bookGap = anchors[i].bookIdx - anchors[i - 1].bookIdx
            let audioGap = anchors[i].audioIdx - anchors[i - 1].audioIdx
            guard bookGap > 0 else { continue }
            ratios.append(Double(audioGap) / Double(bookGap))
        }
        guard !ratios.isEmpty else { return anchors }

        let sortedRatios = ratios.sorted()
        let median = sortedRatios[sortedRatios.count / 2]
        let lower = median / 3.0
        let upper = median * 3.0

        var kept: [(bookIdx: Int, audioIdx: Int)] = [anchors[0]]
        for i in 1..<anchors.count {
            let bookGap = anchors[i].bookIdx - kept.last!.bookIdx
            let audioGap = anchors[i].audioIdx - kept.last!.audioIdx
            guard bookGap > 0 else { continue }
            let ratio = Double(audioGap) / Double(bookGap)
            if ratio >= lower && ratio <= upper {
                kept.append(anchors[i])
            }
        }
        return kept
    }

    /// Find (bookIdx, audioIdx) anchor pairs by greedily walking through
    /// distinctive book words and locating them in the audio transcript ahead
    /// of an advancing cursor. Common words like "the" / "and" never anchor
    /// because they fail the rarity filter.
    private func findAnchorPairs(
        bookWords: [BookWord],
        audio: [AudioWord],
        bookFreq: [String: Int],
        audioFreq: [String: Int]
    ) -> [(bookIdx: Int, audioIdx: Int)] {
        var pairs: [(bookIdx: Int, audioIdx: Int)] = []
        var audioCursor = 0
        let searchHorizon = 800  // audio words

        for (bookIdx, bw) in bookWords.enumerated() {
            guard bw.normalized.count >= 5 else { continue }
            guard let bf = bookFreq[bw.normalized], bf <= 3 else { continue }
            guard let af = audioFreq[bw.normalized], af >= 1, af <= 5 else { continue }

            let end = min(audioCursor + searchHorizon, audio.count)
            guard audioCursor < end else { break }
            if let audioIdx = (audioCursor..<end).first(where: { audio[$0].text == bw.normalized }) {
                pairs.append((bookIdx, audioIdx))
                audioCursor = audioIdx + 1
            }
        }
        return pairs
    }

    private func emptyMap() -> AlignmentMap {
        AlignmentMap(
            words: [],
            sentences: [],
            audioWordStarts: [],
            createdAt: .now,
            modelIdentifier: modelIdentifier
        )
    }

    private func deriveSentenceAnchors(words: [WordAnchor], segments: [TextSegment]) -> [SentenceAnchor] {
        var anchors: [SentenceAnchor] = []
        let wordsBySegment = Dictionary(grouping: words, by: { $0.segmentId })

        for segment in segments {
            guard let segWords = wordsBySegment[segment.id], !segWords.isEmpty else { continue }
            let ranges = sentenceWordRanges(in: segment.text)
            for (sIdx, range) in ranges.enumerated() {
                let inRange = segWords.filter {
                    $0.wordIndex >= range.start && $0.wordIndex < range.end
                }
                guard let first = inRange.min(by: { $0.startSeconds < $1.startSeconds }),
                      let last = inRange.max(by: { $0.endSeconds < $1.endSeconds }) else {
                    continue
                }
                anchors.append(SentenceAnchor(
                    segmentId: segment.id,
                    sentenceIndex: sIdx,
                    startSeconds: first.startSeconds,
                    endSeconds: last.endSeconds
                ))
            }
        }
        return anchors
    }
}

public enum AlignerError: Error, Sendable {
    case modelNotFound(String)
    case transcriptionFailed(String)
}

public enum AlignmentStage: Sendable {
    case loadingModel(model: String)
    case transcribing(snippet: String?, fraction: Double?, etaSeconds: TimeInterval?)
    case aligning
    case complete(wordsAligned: Int, sentencesAligned: Int)

    public var displayText: String {
        switch self {
        case .loadingModel(let model):
            return "Loading Whisper model (\(model))…"
        case .transcribing(let snippet, _, let eta):
            var parts = ["Transcribing"]
            if let eta { parts.append(formatETA(eta) + " left") }
            if let snippet, !snippet.isEmpty { parts.append("\u{201C}\(snippet)\u{201D}") }
            return parts.joined(separator: " · ")
        case .aligning:
            return "Aligning transcript to ebook text…"
        case .complete(let words, let sentences):
            return "Done — \(words) words, \(sentences) sentences aligned."
        }
    }

    public var progressFraction: Double? {
        switch self {
        case .loadingModel: return 0.02
        case .transcribing(_, let fraction, _): return fraction
        case .aligning: return 0.95
        case .complete: return 1.0
        }
    }
}

private func formatETA(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 {
        return "~\(total)s"
    }
    let m = total / 60
    let s = total % 60
    if m < 60 {
        return s == 0 ? "~\(m)m" : "~\(m)m \(s)s"
    }
    let h = m / 60
    let mm = m % 60
    return mm == 0 ? "~\(h)h" : "~\(h)h \(mm)m"
}

// MARK: - Helpers

private struct AudioWord: Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
    let confidence: Float
}

private struct BookWord: Sendable {
    let segmentId: String
    let indexInSegment: Int
    let normalized: String
}

private struct WordIndexRange {
    let start: Int
    let end: Int
}

private func tokenizeWords(_ text: String) -> [String] {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
}

private func normalizeWord(_ word: String) -> String {
    let stripped = word.trimmingCharacters(
        in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
    )
    return stripped.lowercased()
}

private func sentenceWordRanges(in text: String) -> [WordIndexRange] {
    // Foundation's sentence detection — locale-aware, handles abbreviations,
    // quoted dialogue, etc. Same algorithm the reader uses to display sentences,
    // so the sentence indices we emit here line up with what the UI looks up.
    var sentenceCharRanges: [(Int, Int)] = []
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, _ in
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        sentenceCharRanges.append((start, end))
    }

    // Walk the text once, recording the [start, end) char span of each whitespace-
    // delimited word. Word index here matches `tokenizeWords(text)` ordering.
    var wordCharSpans: [(Int, Int)] = []
    var inWord = false
    var wordStart = 0
    var charIndex = 0
    for ch in text {
        if ch.isWhitespace || ch.isNewline {
            if inWord {
                wordCharSpans.append((wordStart, charIndex))
                inWord = false
            }
        } else {
            if !inWord {
                wordStart = charIndex
                inWord = true
            }
        }
        charIndex += 1
    }
    if inWord {
        wordCharSpans.append((wordStart, charIndex))
    }

    var ranges: [WordIndexRange] = []
    for (sStart, sEnd) in sentenceCharRanges {
        var first: Int?
        var last: Int?
        for (idx, span) in wordCharSpans.enumerated() {
            let center = (span.0 + span.1) / 2
            if center >= sStart && center < sEnd {
                if first == nil { first = idx }
                last = idx
            }
        }
        if let f = first, let l = last {
            ranges.append(WordIndexRange(start: f, end: l + 1))
        }
    }
    return ranges
}
