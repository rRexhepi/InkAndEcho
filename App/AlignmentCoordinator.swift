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
        guard !isRunning else { return }
        let bookID = book.id
        generation += 1
        let myGeneration = generation
        currentBookID = bookID
        stage = .loadingModel(model: "preparing")
        error = nil
        partialMap = nil
        partialCoveredThrough = 0
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
                try await service.runAlignment(for: book, onPartial: { [weak self] map, coveredThrough in
                    guard let self, self.generation == myGeneration else { return }
                    self.partialMap = map
                    self.partialCoveredThrough = coveredThrough
                    self.partialRevision += 1
                }) { [weak self] s in
                    guard let self, self.generation == myGeneration else { return }
                    self.stage = s
                }
                let count = service.loadAlignmentMap(for: book)?.words.count ?? 0
                self.toast = count == 0
                    ? "Alignment finished but no anchors landed. The audiobook may not match this EPUB."
                    : "Alignment complete · \(count) paragraph anchors synced"
                let snapshot = self.toast
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if self?.toast == snapshot { self?.toast = nil }
                }
            } catch is CancellationError {
                // Silent — the user explicitly aborted.
            } catch {
                if self.generation == myGeneration {
                    self.error = error.localizedDescription
                }
            }
            guard self.generation == myGeneration else { return }
            self.currentBookID = nil
            self.stage = nil
            self.partialMap = nil
            self.partialCoveredThrough = 0
            self.lastFinishedBookID = bookID
        }
    }

    func cancel() {
        task?.cancel()
        // Keep the task reference: the next start() awaits it so the
        // cancelled job fully unwinds before a new pipeline spins up.
        // Bump the generation so the cancelled task's epilogue becomes a
        // no-op, then clear state here (the epilogue won't).
        generation += 1
        currentBookID = nil
        stage = nil
        partialMap = nil
        partialCoveredThrough = 0
    }

    func dismissError() { error = nil }

    func acknowledgeFinished() { lastFinishedBookID = nil }
}
