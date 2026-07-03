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
    /// better word recognition than tiny.en.
    public static let defaultModel = "openai_whisper-base.en"

    /// Override `modelIdentifier` for heavier models.
    public init(modelIdentifier: String = WhisperAligner.defaultModel) {
        self.modelIdentifier = modelIdentifier
    }

    /// Transcription speed on Apple silicon (ANE), for "about N min"
    /// estimates before a job starts.
    public static let realtimeFactor: Double = 16

    /// Whether the alignment model is already on disk — app surfaces use
    /// this to warn about the one-time ~150 MB download before a job, and
    /// to render the Settings prefetch row.
    public static func isModelDownloaded(variant: String = defaultModel) -> Bool {
        modelIsComplete(at: localModelFolder(variant: variant))
    }

    /// Fetch the model without running an alignment (the Settings prefetch
    /// row), so the user's first real book aligns without the download wait.
    /// No-op when the model is already local.
    public static func prefetchModel(
        variant: String = defaultModel,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        _ = try await ensureModelOnDisk(variant: variant) { stage in
            if case .downloadingModel(let fraction) = stage { progress(fraction) }
        }
    }

    public func align(audioURL: URL, input: AlignmentInput) async throws -> AlignmentMap {
        try await align(audioURL: audioURL, input: input) { _ in }
    }

    /// Align with a progress callback. The callback is invoked from a background
    /// thread; the caller is responsible for hopping to the main actor before
    /// touching UI state.
    ///
    /// `onPartial` (optional) receives interim `AlignmentMap`s during
    /// transcription along with the audio-seconds frontier they cover, so
    /// read-along can go live in the opening chapters minutes into a
    /// ~30-minute job. Partial maps truncate at the frontier — words past it
    /// have NO dense entries (see `computeWordTimes(truncateTail:)`) — and
    /// must never be persisted. Same threading contract as `progress`.
    public func align(
        audioURL: URL,
        input: AlignmentInput,
        onPartial: (@Sendable (AlignmentMap, Double) -> Void)? = nil,
        progress: @Sendable @escaping (AlignmentStage) -> Void
    ) async throws -> AlignmentMap {
        let totalAudioSeconds: Double = {
            guard let file = try? AVAudioFile(forReading: audioURL),
                  file.processingFormat.sampleRate > 0 else { return 0 }
            return Double(file.length) / file.processingFormat.sampleRate
        }()

        // Tokenized/normalized book words + frequency map, built ONCE — the
        // chunk loop's partial emits and the low-match check would otherwise
        // re-tokenize the whole book per chunk.
        let book = BookIndex(segments: input.segments)

        // Transcript cache, checked BEFORE the WhisperKit init: a hit skips
        // the model load (and its one-time ~150 MB download) entirely, so a
        // re-align costs seconds.
        let cache = TranscriptCache()
        let cacheKey = cache.key(forAudioAt: audioURL, model: modelIdentifier)
        if let cacheKey, let cached = cache.load(key: cacheKey) {
            progress(.aligning)
            let map = alignWords(audio: cached, book: book, segments: input.segments)
            progress(.complete(wordsAligned: map.words.count, sentencesAligned: map.sentences.count))
            return map
        }

        let modelFolder = try await Self.ensureModelOnDisk(variant: modelIdentifier, progress: progress)

        progress(.loadingModel(model: modelIdentifier))
        let pipe: WhisperKit
        do {
            // Explicit `modelFolder` skips WhisperKit's hub lookup entirely,
            // so once the model is on disk, alignment works offline.
            pipe = try await WhisperKit(WhisperKitConfig(
                model: modelIdentifier,
                modelFolder: modelFolder.path
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AlignerError.modelNotFound(
                "Could not load Whisper model '\(modelIdentifier)': \(error.localizedDescription)"
            )
        }

        progress(.transcribing(snippet: nil, fraction: 0, etaSeconds: nil))
        let options = DecodingOptions(wordTimestamps: true)

        // WhisperKit's window size; partial callbacks fire at this cadence.
        let whisperWindowSeconds: Double = 30.0
        // Audio-load chunk size. WhisperKit's transcribe(audioPath:) loads
        // the entire file into a `[Float]` first, which OOM-aborts a
        // multi-hour audiobook (10 hr @ 16 kHz mono Float32 ≈ 2.3 GB,
        // past iPhone's per-process ceiling). Loading in 5-minute chunks
        // keeps peak around ~19 MB per chunk.
        let loadChunkSeconds: Double = 5 * 60
        let transcribeStart = Date()

        var audioWords: [AudioWord] = []
        var loadCursor: Double = 0
        var chunkIndex = 0
        // `totalAudioSeconds <= 0` means the duration probe failed: take one
        // full-chunk pass and bail via the in-loop break. With a known
        // duration, loop strictly against it — comparing against
        // `max(total, chunk)` re-entered the loop with an empty
        // `chunkStart == chunkEnd` slice for any audio shorter than one
        // chunk, and since the cursor never advances on an empty slice,
        // sub-5-minute audiobooks spun the aligner forever.
        while totalAudioSeconds <= 0 || loadCursor < totalAudioSeconds {
            // Cooperative cancellation between chunks — without this, a
            // cancelled job only stops once WhisperKit's own internals
            // happen to check, which can be a full chunk (~19 s) later.
            try Task.checkCancellation()
            let chunkStart = loadCursor
            let chunkEnd = totalAudioSeconds > 0
                ? min(chunkStart + loadChunkSeconds, totalAudioSeconds)
                : chunkStart + loadChunkSeconds
            // Load PAST the seam: a hard cut at `chunkEnd` slices the word
            // straddling it mid-phoneme, garbling it in both chunks. The
            // tail overlap lets THIS chunk transcribe that word cleanly; the
            // next chunk's re-transcription of the zone is dropped by the
            // seam dedup below (Flutter aligner parity).
            let loadEnd = totalAudioSeconds > 0
                ? min(chunkEnd + Self.seamOverlapSeconds, totalAudioSeconds)
                : chunkEnd

            let callback: TranscriptionCallback = { partial in
                let snippet = String(partial.text.suffix(80))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let processedAudio = min(
                    totalAudioSeconds > 0 ? totalAudioSeconds : .infinity,
                    chunkStart + Double(partial.windowId + 1) * whisperWindowSeconds
                )
                let fraction: Double? = totalAudioSeconds > 0
                    ? min(1.0, processedAudio / totalAudioSeconds)
                    : nil
                let elapsed = Date().timeIntervalSince(transcribeStart)
                let speed = elapsed > 0.5 ? processedAudio / elapsed : 0
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

            let chunkResults: [TranscriptionResult]
            do {
                let samples = try AudioProcessor.loadAudioAsFloatArray(
                    fromPath: audioURL.path,
                    startTime: chunkStart,
                    endTime: loadEnd
                )
                chunkResults = try await pipe.transcribe(
                    audioArray: samples,
                    decodeOptions: options,
                    callback: callback
                )
            } catch is CancellationError {
                // The user cancelled the job. Wrapping this in
                // `transcriptionFailed` would turn an intentional abort into
                // an "Alignment failed" alert upstream — rethrow unchanged so
                // the coordinator's CancellationError catch stays silent.
                throw CancellationError()
            } catch {
                throw AlignerError.transcriptionFailed(error.localizedDescription)
            }

            for result in chunkResults {
                for seg in result.segments {
                    for word in (seg.words ?? []) {
                        let normalized = normalizeWord(word.word)
                        let absStart = Double(word.start) + chunkStart
                        // The head of this chunk re-covers the previous
                        // chunk's tail overlap — drop re-transcriptions.
                        if Self.isSeamDuplicate(
                            text: normalized,
                            startSeconds: absStart,
                            chunkStart: chunkStart,
                            recent: audioWords.suffix(50)
                        ) {
                            continue
                        }
                        audioWords.append(AudioWord(
                            text: normalized,
                            startSeconds: absStart,
                            endSeconds: Double(word.end) + chunkStart,
                            confidence: Float(word.probability)
                        ))
                    }
                }
            }

            loadCursor = chunkEnd
            if totalAudioSeconds <= 0 { break }

            chunkIndex += 1
            // Emit a partial map for the transcript so far. Throttle: the
            // first three chunks unconditionally (chapter 1 word-follow goes
            // live after ~19 s), then every 3rd — each emit re-runs the
            // greedy matcher over the whole accumulated transcript. Skip the
            // final chunk; the full map lands right after the loop.
            let emitPartial = onPartial != nil && loadCursor < totalAudioSeconds
                && (chunkIndex <= 3 || chunkIndex % 3 == 0)
            // Ten minutes in is enough signal to judge whether this is even
            // the right audiobook: healthy narration lands well over one
            // anchor per minute, a mismatched (or wrong-language, or
            // wrong-edition) file lands near zero. Warn once — the pipe is
            // one-way, so cancelling stays the user's call.
            let checkMatchRate = chunkIndex == 2 && totalAudioSeconds > 0 && loadCursor > 0
            if emitPartial || checkMatchRate, !audioWords.isEmpty {
                let sorted = audioWords.sorted {
                    ($0.startSeconds, $0.endSeconds) < ($1.startSeconds, $1.endSeconds)
                }
                let partial = alignWords(audio: sorted, book: book, segments: input.segments, truncateTail: true)
                if checkMatchRate {
                    let perMinute = Double(partial.words.count) / (loadCursor / 60)
                    if perMinute < Self.minHealthyAnchorsPerMinute {
                        progress(.lowMatchWarning(anchorsPerMinute: perMinute))
                    }
                }
                if emitPartial {
                    onPartial?(partial, loadCursor)
                }
            }
        }

        // Overlap zones can interleave slightly (chunk i's tail word may
        // start after chunk i+1's first words); downstream walks assume
        // time order, so settle it once here.
        audioWords.sort { ($0.startSeconds, $0.endSeconds) < ($1.startSeconds, $1.endSeconds) }

        if let cacheKey {
            cache.store(audioWords, key: cacheKey)
        }

        progress(.aligning)

        let map = alignWords(audio: audioWords, book: book, segments: input.segments)
        progress(.complete(wordsAligned: map.words.count, sentencesAligned: map.sentences.count))
        return map
    }

    /// Anchors-per-minute below which the transcript almost certainly isn't
    /// this book's narration. Healthy alignments land far above it.
    static let minHealthyAnchorsPerMinute: Double = 1.0

    // MARK: - Greedy alignment

    private func alignWords(
        audio: [AudioWord],
        book: BookIndex,
        segments: [TextSegment],
        truncateTail: Bool = false
    ) -> AlignmentMap {
        let bookWords = book.words
        guard !bookWords.isEmpty, !audio.isEmpty else {
            return emptyMap()
        }

        // Frequency maps drive anchor selection. We want words that are rare in
        // BOTH sequences (so they're distinctive landmarks) and identical when
        // normalized.
        var audioFreq: [String: Int] = [:]
        for w in audio { audioFreq[w.text, default: 0] += 1 }

        // Find ordered (bookIdx, audioIdx) anchor pairs.
        let anchors = findAnchorPairs(
            bookWords: bookWords,
            audio: audio,
            bookFreq: book.freq,
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
        let wordTimes = computeWordTimes(
            bookWords: bookWords,
            audio: audio,
            anchors: validated,
            truncateTail: truncateTail
        )

        return AlignmentMap(
            words: wordAnchors,
            sentences: sentences,
            audioWordStarts: audioWordStarts,
            wordTimes: wordTimes,
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
        // How far past the cadence-predicted position a candidate may land
        // before it's rejected as a false match. Narration runs ~1 audio
        // word per book word, so a candidate hundreds of words early means
        // the matcher found a LATER occurrence of this word (e.g. the next
        // chapter's heading because Whisper mis-heard this chapter's).
        // Accepting that leap is fatal: the cursor is monotonic, so every
        // genuine match in the skipped span becomes unreachable — one
        // mis-heard word used to desync the whole rest of the book.
        // 200 audio words ≈ 80 s still tolerates narrator asides.
        let maxLeapPastExpected = 200

        for (bookIdx, bw) in bookWords.enumerated() {
            guard bw.normalized.count >= 5 else { continue }
            guard let bf = bookFreq[bw.normalized], bf <= 3 else { continue }
            guard let af = audioFreq[bw.normalized], af >= 1, af <= 5 else { continue }

            let end = min(audioCursor + searchHorizon, audio.count)
            guard audioCursor < end else { break }
            if let audioIdx = (audioCursor..<end).first(where: { audio[$0].text == bw.normalized }) {
                // The first anchor is unbounded (narrators add preambles);
                // after that, candidates must stay near the running cadence.
                if let last = pairs.last {
                    let expected = last.audioIdx + (bookIdx - last.bookIdx)
                    if audioIdx - expected > maxLeapPastExpected {
                        continue  // reject the leap; cursor stays put
                    }
                }
                pairs.append((bookIdx, audioIdx))
                audioCursor = audioIdx + 1
            }
        }
        return pairs
    }

    // MARK: - Model download

    /// Where WhisperKit's hub client materializes a downloaded model
    /// (Documents/huggingface/models/<repo>/<variant>). Mirroring the layout
    /// here lets us detect a local model without any network round-trip —
    /// `WhisperKit.download` starts with a hub file listing even when every
    /// file is already on disk, which fails offline.
    static func localModelFolder(variant: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    private static func modelIsComplete(at folder: URL) -> Bool {
        ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Returns the local model folder, downloading it first when absent or
    /// incomplete (an interrupted download leaves a partial folder; the hub
    /// snapshot resumes it). The download is the silent ~150 MB first-run
    /// cost that used to hide behind a static "2%" — surface it as its own
    /// stage with real progress.
    private static func ensureModelOnDisk(
        variant: String,
        progress: @Sendable @escaping (AlignmentStage) -> Void
    ) async throws -> URL {
        let local = localModelFolder(variant: variant)
        if modelIsComplete(at: local) { return local }
        progress(.downloadingModel(fraction: 0))
        do {
            return try await WhisperKit.download(variant: variant) { p in
                progress(.downloadingModel(fraction: p.fractionCompleted))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is URLError {
            throw AlignerError.modelDownloadFailed(
                "Internet needed once to fetch the alignment model."
            )
        } catch {
            throw AlignerError.modelDownloadFailed(
                "Internet needed once to fetch the alignment model — \(error.localizedDescription)"
            )
        }
    }

    /// Seconds of audio loaded past each chunk boundary so seam-straddling
    /// words transcribe cleanly in the earlier chunk.
    static let seamOverlapSeconds: Double = 2

    /// True when a word at the head of a chunk is a re-transcription of a
    /// word the previous chunk's tail overlap already emitted: it falls
    /// inside the overlap zone and matches an emitted word by normalized
    /// text within ±0.5 s. Pure function for testability.
    static func isSeamDuplicate(
        text: String,
        startSeconds: Double,
        chunkStart: Double,
        recent: ArraySlice<AudioWord>
    ) -> Bool {
        guard chunkStart > 0, startSeconds < chunkStart + seamOverlapSeconds else { return false }
        return recent.contains { $0.text == text && abs($0.startSeconds - startSeconds) <= 0.5 }
    }

    /// Dense per-book-word start times for read-along highlighting. The sparse
    /// `anchors` give a correct coarse alignment that re-syncs the stream; here
    /// we fill in EVERY book word so the highlight never skips. Within each
    /// anchor gap we greedily match that gap's book words to that gap's audio
    /// words — the bracketing anchors keep the search local, so even common
    /// words ("the", "and") can't mis-match a far-away occurrence. Matched
    /// words get their real Whisper time; unmatched words (narrator skips, ASR
    /// misses) are linearly interpolated between matched neighbours. Times are
    /// forced strictly increasing so every word owns a distinct slice and the
    /// reader's time→word lookup is unambiguous. Pure function, no Apple deps,
    /// so it ports to the Flutter aligner unchanged.
    ///
    /// `truncateTail` is the partial-map variant: words past the last matched
    /// word get NO entries instead of clamping to its time. On a full map the
    /// clamp is right (the tail is front/back matter the narrator skipped),
    /// but on a mid-transcription partial the "tail" is the entire unread
    /// rest of the book — clamped times would send the follow path sprinting
    /// through junk-timed words the moment playback crossed the frontier.
    func computeWordTimes(
        bookWords: [BookWord],
        audio: [AudioWord],
        anchors: [(bookIdx: Int, audioIdx: Int)],
        truncateTail: Bool = false
    ) -> [SegmentWordTimes] {
        let n = bookWords.count
        guard n > 0, !audio.isEmpty, !anchors.isEmpty else { return [] }

        // Pin known times at every anchor, then match within each gap.
        var known = [Double?](repeating: nil, count: n)
        for a in anchors where a.bookIdx < n && a.audioIdx < audio.count {
            known[a.bookIdx] = audio[a.audioIdx].startSeconds
        }
        for g in 0..<(anchors.count - 1) {
            let bp = anchors[g].bookIdx, ap = anchors[g].audioIdx
            let bf = anchors[g + 1].bookIdx, af = anchors[g + 1].audioIdx
            guard bp < bf, ap < af, bf <= n, af <= audio.count else { continue }
            var cursor = ap + 1
            for bi in (bp + 1)..<bf {
                guard cursor < af else { break }
                let target = bookWords[bi].normalized
                if let ai = (cursor..<af).first(where: { audio[$0].text == target }) {
                    known[bi] = audio[ai].startSeconds
                    cursor = ai + 1
                }
            }
        }

        // Fill: walk the head backward from the first known time (clamping it
        // flat would make the strictly-increasing pass below cascade +1 ms per
        // head word THROUGH the anchor, displacing every real time after it —
        // a book with a few hundred unnarrated front-matter words would shift
        // the opening chapter's highlight by that many milliseconds). Tail
        // clamps to the last known time; interior runs linearly interpolate
        // between matched neighbours.
        let knownIdx = (0..<n).filter { known[$0] != nil }
        guard let first = knownIdx.first, let last = knownIdx.last else { return [] }
        var times = [Double](repeating: 0, count: n)
        times[first] = known[first]!
        if first > 0 {
            for i in stride(from: first - 1, through: 0, by: -1) {
                times[i] = times[i + 1] - 0.001
            }
        }
        for k in 0..<(knownIdx.count - 1) {
            let a = knownIdx[k], b = knownIdx[k + 1]
            let ta = known[a]!, tb = known[b]!
            times[a] = ta
            if b - a > 1 {
                let span = tb - ta
                for i in (a + 1)..<b {
                    times[i] = ta + span * (Double(i - a) / Double(b - a))
                }
            }
            times[b] = tb
        }
        let emitCount: Int
        if truncateTail {
            emitCount = last + 1
        } else {
            if last < n { for i in last..<n { times[i] = known[last]! } }
            emitCount = n
        }

        // Strictly increasing so each word owns a distinct time slice.
        if emitCount > 1 {
            for i in 1..<emitCount where times[i] <= times[i - 1] {
                times[i] = times[i - 1] + 0.001
            }
        }

        // Cut detection (abridged narrations, skipped passages): a long run
        // of unmatched book words whose bracketing matches imply an absurd
        // pace isn't being narrated slowly — it isn't being narrated at all.
        // Interpolating would smear the cut's few audio seconds over hundreds
        // of words. Omit such runs from the parallel arrays instead: the
        // reader's largest-below binary searches (`denseStart`,
        // `denseWordIndex`) park the highlight on the last narrated word and
        // jump the cut — zero schema or reader changes, unlike a sentinel.
        var omitted = [Bool](repeating: false, count: n)
        var paces: [Double] = []   // seconds per book word between matched neighbours
        for k in 0..<(knownIdx.count - 1) {
            let a = knownIdx[k], b = knownIdx[k + 1]
            paces.append((known[b]! - known[a]!) / Double(b - a))
        }
        if paces.count >= 3 {
            let median = paces.sorted()[paces.count / 2]
            if median > 0 {
                for k in 0..<(knownIdx.count - 1)
                where knownIdx[k + 1] - knownIdx[k] - 1 > Self.cutRunWords {
                    let pace = paces[k]
                    if pace < median / 3 || pace > median * 3 {
                        for i in (knownIdx[k] + 1)..<knownIdx[k + 1] { omitted[i] = true }
                    }
                }
            }
        }

        // Group into per-segment parallel arrays (book words are contiguous by
        // segment, in reading order). `matchedFraction` records how much of
        // each chapter got REAL transcript times vs interpolation/omission —
        // the aligner's own per-chapter confidence.
        var result: [SegmentWordTimes] = []
        var curSeg: String?
        var idxs: [Int] = []
        var starts: [Double] = []
        var segMatched = 0
        var segTotal = 0
        func flushSegment() {
            guard let s = curSeg, !idxs.isEmpty else { return }
            result.append(SegmentWordTimes(
                segmentId: s,
                wordIndices: idxs,
                starts: starts,
                matchedFraction: segTotal > 0 ? Double(segMatched) / Double(segTotal) : 0
            ))
        }
        for i in 0..<emitCount {
            let bw = bookWords[i]
            if bw.segmentId != curSeg {
                flushSegment()
                curSeg = bw.segmentId
                idxs = []
                starts = []
                segMatched = 0
                segTotal = 0
            }
            segTotal += 1
            if known[i] != nil { segMatched += 1 }
            guard !omitted[i] else { continue }
            idxs.append(bw.indexInSegment)
            starts.append(times[i])
        }
        flushSegment()
        return result
    }

    /// Unmatched runs longer than this are candidates for cut omission when
    /// their implied pace diverges >3× from the median matched pace.
    static let cutRunWords = 50

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
    case modelDownloadFailed(String)
}

extension AlignerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let message),
             .transcriptionFailed(let message),
             .modelDownloadFailed(let message):
            return message
        }
    }
}

public enum AlignmentStage: Sendable {
    case downloadingModel(fraction: Double)
    case loadingModel(model: String)
    case transcribing(snippet: String?, fraction: Double?, etaSeconds: TimeInterval?)
    case aligning
    case complete(wordsAligned: Int, sentencesAligned: Int)
    /// Diagnostic, not a pipeline phase: emitted once, early in the run, when
    /// the transcript is matching the book text suspiciously poorly (likely
    /// the wrong audiobook). Consumers should surface it persistently instead
    /// of letting the next `.transcribing` overwrite it.
    case lowMatchWarning(anchorsPerMinute: Double)

    public var displayText: String {
        switch self {
        case .downloadingModel:
            return "Downloading alignment model (one-time)…"
        case .lowMatchWarning:
            return "Very few matches so far — is this the right audiobook for this book?"
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
        case .downloadingModel(let fraction):
            // The download owns the first tenth of the bar; transcription's
            // audio fraction takes over from there.
            return min(1, max(0, fraction)) * 0.1
        case .loadingModel: return 0.02
        case .transcribing(_, let fraction, _): return fraction
        case .aligning: return 0.95
        case .complete: return 1.0
        case .lowMatchWarning: return nil
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

struct AudioWord: Sendable, Codable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
    let confidence: Float
}

struct BookWord: Sendable {
    let segmentId: String
    let indexInSegment: Int
    let normalized: String
}

/// The book side of alignment, tokenized and normalized once. Flattened
/// words carry (segmentId, segmentLocalIndex) labels — the local index
/// matches the wordIndex the reader's UI looks up. The frequency map
/// drives anchor rarity selection.
struct BookIndex: Sendable {
    let words: [BookWord]
    let freq: [String: Int]

    init(segments: [TextSegment]) {
        var words: [BookWord] = []
        for segment in segments {
            let tokens = tokenizeWords(segment.text)
            for (idx, raw) in tokens.enumerated() {
                let norm = normalizeWord(raw)
                guard !norm.isEmpty else { continue }
                words.append(BookWord(
                    segmentId: segment.id,
                    indexInSegment: idx,
                    normalized: norm
                ))
            }
        }
        var freq: [String: Int] = [:]
        for w in words { freq[w.normalized, default: 0] += 1 }
        self.words = words
        self.freq = freq
    }
}

private struct WordIndexRange {
    let start: Int
    let end: Int
}

private func tokenizeWords(_ text: String) -> [String] {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
}

private func normalizeWord(_ word: String) -> String {
    // Fold typographic apostrophes to ASCII before comparing: typeset EPUBs
    // write "don’t" (U+2019) while Whisper's vocabulary emits "don't".
    // Interior characters survive edge-trimming, so without the fold no
    // contraction in such books can ever match an audio word — they all
    // drop out of anchoring and gap-matching.
    let folded = word
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{2018}", with: "'")
    let stripped = folded.trimmingCharacters(
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
