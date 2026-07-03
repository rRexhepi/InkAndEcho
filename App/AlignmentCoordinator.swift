import Foundation
import SwiftData
import InkAndEchoCore

/// App-level alignment state. Owns the long-running WhisperKit Task so it
/// survives `ReaderView` being popped off the navigation stack. Library
/// rows + reader banner both subscribe to the same instance.
///
/// Single in-flight job at a time — the WhisperKit instance and the JIT
/// CoreML kernels can't safely be shared across two concurrent alignment
/// runs. The `start(book:)` call is a no-op when another job is running.
@MainActor
@Observable
final class AlignmentCoordinator {
    private(set) var currentBookID: UUID?
    /// Title of the running job's book, for named busy copy when a second
    /// book asks for the single alignment slot.
    private(set) var currentBookTitle: String?
    private(set) var stage: AlignmentStage?
    private(set) var toast: String?
    private(set) var error: String?
    /// Set briefly after each completed job (success or failure) so views
    /// can react (`ReaderView` reloads its local AlignmentMap, etc.) and
    /// then clear back to `nil`.
    private(set) var lastFinishedBookID: UUID?
    /// Interim alignment for the running job, truncated at the transcription
    /// frontier (`partialCoveredThrough`, audio seconds). Never persisted —
    /// the final map replaces it via `lastFinishedBookID`. Views observe
    /// `partialRevision` (monotonic, bumped per emit) instead of comparing
    /// multi-MB maps.
    private(set) var partialMap: AlignmentMap?
    private(set) var partialCoveredThrough: Double = 0
    private(set) var partialRevision = 0
    /// Anchors-per-minute measured a couple of chunks in, when suspiciously
    /// low (likely the wrong audiobook for this book). Persistent for the
    /// rest of the job — the stage pipe is one-way, so the existing cancel
    /// affordances are the escape hatch, not a blocking dialog.
    private(set) var lowMatchWarning: Double?

    var isRunning: Bool { currentBookID != nil }

    func isRunning(for bookID: UUID) -> Bool { currentBookID == bookID }

    private var task: Task<Void, Never>?

    /// Monotonic job counter. Cancellation is cooperative — a cancelled
    /// task's epilogue can land seconds later, after a NEW job has started;
    /// the generation check keeps that stale epilogue from clearing the
    /// successor's state (which read as "nothing running" and allowed a
    /// third, genuinely concurrent WhisperKit run).
    private var generation = 0

    func start(book: Book, modelContext: ModelContext) {
        guard !isRunning else {
            // One WhisperKit pipeline at a time. The old silent return read
            // as a dead Align button from another book's reader — say why.
            let running = currentBookTitle.map { "“\($0)”" } ?? "another book"
            showToast("Still aligning \(running) — one book at a time. Cancel it from its reader to start this one.")
            return
        }
        let bookID = book.id
        generation += 1
        let myGeneration = generation
        currentBookID = bookID
        currentBookTitle = book.title
        stage = .loadingModel(model: "preparing")
        error = nil
        partialMap = nil
        partialCoveredThrough = 0
        lowMatchWarning = nil
        // Re-arm the completion signal: it's only consumed via onChange, so
        // re-aligning the same book in one session would otherwise write the
        // same value over itself and never fire the reader's reload.
        lastFinishedBookID = nil
        // A cancelled predecessor unwinds cooperatively — its WhisperKit
        // instance (and JIT CoreML kernels) can still be alive when the
        // user starts the next job. Await it HERE, inside the new task,
        // so two pipelines never run concurrently. Never await inside
        // `cancel()` — that would block the main actor.
        let predecessor = task
        task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self, self.generation == myGeneration else { return }
            let service = AlignmentService(modelContext: modelContext)
            do {
                let map = try await service.runAlignment(for: book, onPartial: { [weak self] map, coveredThrough in
                    guard let self, self.generation == myGeneration else { return }
                    // Emissions hop to the main actor as unstructured Tasks,
                    // which aren't strictly FIFO — never let a late-arriving
                    // older partial regress the frontier.
                    guard coveredThrough > self.partialCoveredThrough else { return }
                    self.partialMap = map
                    self.partialCoveredThrough = coveredThrough
                    self.partialRevision += 1
                }) { [weak self] s in
                    guard let self, self.generation == myGeneration else { return }
                    // Diagnostics ride the same pipe as phases but must
                    // persist — the next .transcribing would overwrite them.
                    if case .lowMatchWarning(let perMinute) = s {
                        self.lowMatchWarning = perMinute
                    } else {
                        self.stage = s
                    }
                }
                self.showToast(Self.completionToast(for: map))
            } catch is CancellationError {
                // Silent — the user explicitly aborted.
            } catch {
                if self.generation == myGeneration {
                    self.error = error.localizedDescription
                }
            }
            guard self.generation == myGeneration else { return }
            // Retire this job's callbacks BEFORE clearing: emissions hop to
            // the main actor as unstructured Tasks, so a straggler landing
            // after this epilogue would pass the generation guard and pin a
            // multi-MB partial map (and a stale stage) on this app-lifetime
            // object until the next job.
            self.generation += 1
            self.currentBookID = nil
            self.currentBookTitle = nil
            self.stage = nil
            self.partialMap = nil
            self.partialCoveredThrough = 0
            self.lowMatchWarning = nil
            self.lastFinishedBookID = bookID
        }
    }

    /// Set the toast with the shared 4 s auto-clear (a newer toast wins).
    private func showToast(_ message: String) {
        toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }

    /// "Synced N% · K rough chapters" when the map carries per-chapter
    /// confidence and any chapter fell under the rough threshold; the
    /// familiar anchor-count line otherwise.
    private static func completionToast(for map: AlignmentMap) -> String {
        let count = map.words.count
        guard count > 0 else {
            return "Alignment finished but no anchors landed. The audiobook may not match this EPUB."
        }
        let rough = map.roughSegmentIDs().count
        if rough > 0, let fraction = map.overallMatchedFraction {
            let pct = Int((fraction * 100).rounded())
            return "Alignment complete · synced ~\(pct)% · \(rough) rough chapter\(rough == 1 ? "" : "s") won't word-highlight"
        }
        return "Alignment complete · \(count) paragraph anchors synced"
    }

    func cancel() {
        task?.cancel()
        // Keep the task reference: the next start() awaits it so the
        // cancelled job fully unwinds before a new pipeline spins up.
        // Bump the generation so the cancelled task's epilogue becomes a
        // no-op, then clear state here (the epilogue won't).
        generation += 1
        currentBookID = nil
        currentBookTitle = nil
        stage = nil
        partialMap = nil
        partialCoveredThrough = 0
        lowMatchWarning = nil
    }

    func dismissError() { error = nil }

    func acknowledgeFinished() { lastFinishedBookID = nil }
}
