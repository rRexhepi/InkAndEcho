import Foundation
import SwiftData
import InkAndEchoCore
#if os(iOS)
import UIKit
#endif

@MainActor
struct AlignmentService {
    let modelContext: ModelContext

    /// Runs the full alignment pipeline for a book that already has both an ebook
    /// and an audiobook attached. Saves the resulting `AlignmentMap` as JSON next
    /// to the book's other files and stores the URL on the `Book` row.
    ///
    /// Survives the screen locking or the app moving to background by
    /// requesting a `UIApplication` background task and disabling the
    /// idle timer for the duration. Force-quit (swipe-away in app
    /// switcher) still kills the process — iOS doesn't offer any escape
    /// hatch for that.
    /// `onPartial` receives interim maps while transcription runs (with the
    /// audio-seconds frontier they cover) so the reader can light up synced
    /// chapters mid-job. Partials are never written to disk — only the final
    /// map lands in `alignment.json`. Returns the final map so callers don't
    /// re-decode the JSON they just watched being written.
    @discardableResult
    func runAlignment(
        for book: Book,
        onPartial: @MainActor @escaping (AlignmentMap, Double) -> Void = { _, _ in },
        progress: @MainActor @escaping (AlignmentStage) -> Void = { _ in }
    ) async throws -> AlignmentMap {
        guard let ebookURL = book.resolvedEbookURL,
              let audioURL = book.resolvedAudiobookURL else {
            throw AlignmentServiceError.missingFiles
        }

        #if os(iOS)
        // Keep the screen awake so long alignments don't pause when the
        // device auto-locks; restore on exit. `isIdleTimerDisabled` is
        // device-wide while we hold it.
        let priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        // Request a background task. If the user backgrounds the app or
        // locks the screen anyway, iOS gives us a grace window (a few
        // minutes) before suspending. Without this, suspension is
        // immediate and the alignment job stalls.
        // The expiration handler MUST end the task itself: returning without
        // calling `endBackgroundTask` when the grace window expires gets the
        // process killed (0x8badf00d) instead of suspended — locking the
        // screen during a long alignment took the whole app down. The box
        // dance lets the handler and the defer share one-shot semantics.
        final class TaskIDBox: @unchecked Sendable {
            var id: UIBackgroundTaskIdentifier = .invalid
        }
        let box = TaskIDBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "InkAndEcho.alignment") {
            if box.id != .invalid {
                UIApplication.shared.endBackgroundTask(box.id)
                box.id = .invalid
            }
        }
        defer {
            if box.id != .invalid {
                UIApplication.shared.endBackgroundTask(box.id)
                box.id = .invalid
            }
            UIApplication.shared.isIdleTimerDisabled = priorIdleTimer
        }
        #endif

        progress(.loadingModel(model: "parsing book"))
        guard let importer = EBookImporterRegistry.importer(for: ebookURL) else {
            throw ImporterError.unsupportedFormat
        }
        let imported = try await importer.importBook(from: ebookURL)
        let input = AlignmentInput(segments: imported.segments)

        let aligner = WhisperAligner()
        let map = try await aligner.align(
            audioURL: audioURL,
            input: input,
            onPartial: { partial, coveredThrough in
                Task { @MainActor in
                    onPartial(partial, coveredThrough)
                }
            }
        ) { stage in
            // WhisperKit invokes this from its own queue; bounce to main.
            Task { @MainActor in
                progress(stage)
            }
        }

        let bookDir = ebookURL.deletingLastPathComponent()
        let mapURL = bookDir.appendingPathComponent("alignment.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(map)
        try data.write(to: mapURL, options: .atomic)

        book.alignmentMapURL = mapURL
        try modelContext.save()
        progress(.complete(wordsAligned: map.words.count, sentencesAligned: map.sentences.count))
        return map
    }

    func loadAlignmentMap(for book: Book) -> AlignmentMap? {
        guard let url = book.resolvedAlignmentMapURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let map = try? decoder.decode(AlignmentMap.self, from: data) else { return nil }
        // Pre-dense caches (no per-word times) can't drive skip-free read-along.
        // Treat them as absent so the book prompts a re-align, which writes the
        // new format.
        if map.wordTimes.isEmpty && !map.words.isEmpty { return nil }
        return map
    }
}

enum AlignmentServiceError: LocalizedError {
    case missingFiles

    var errorDescription: String? {
        switch self {
        case .missingFiles:
            return "Both an ebook and an audiobook must be attached before aligning."
        }
    }
}
