import Foundation
import InkAndEchoCore

/// When the sleep timer pauses playback.
enum SleepTarget: Equatable {
    /// Fixed wall-clock deadline (the 15/30/45/60-minute presets). Keeps
    /// counting while paused, like every audiobook player's sleep timer.
    case wallClock(Date)
    /// Playhead position in audio seconds ("End of chapter"). Compared
    /// against `engine.currentTime`, so it's rate-change-proof for free and
    /// waits out a manual pause.
    case audioTime(TimeInterval)
}

/// App-level owner of the single shared `AudioEngine`. Lives for the whole
/// session (held by `InkAndEchoApp`, injected via environment) so audio keeps
/// playing when a `ReaderView` is popped — the foundation for lock-screen
/// controls and "listen while you browse the library".
///
/// Tracks WHICH book the engine is currently loaded with (`loadedBookID`),
/// separate from whatever book a reader is displaying. Read-along, progress
/// saving, and the audio bar all gate on whether the displayed book IS the
/// loaded one, so a reader showing book B never drives its highlight or
/// clobbers its saved position from book A's playback timeline.
@MainActor
@Observable
final class AudioCoordinator {
    /// The one engine. Audio bars and the reader talk to it directly for
    /// transport; the coordinator owns load/switch and book identity.
    let engine = AudioEngine()

    private(set) var loadedBookID: UUID?
    private(set) var loadedTitle: String = ""
    private(set) var loadedAuthor: String = ""
    private(set) var loadedCoverData: Data?

    /// Why the most recent load failed, keyed to the book it failed for.
    /// A failed `switchTo`/`present` used to be silent — the bar just showed
    /// a disabled play button with no explanation and no way to retry.
    private(set) var loadFailureMessage: String?
    private var loadFailureBookID: UUID?

    /// The failure message if the last load failure was for `book`.
    func loadError(for book: Book) -> String? {
        loadFailureBookID == book.id ? loadFailureMessage : nil
    }

    /// True once any book's audio is loaded — drives the library mini-player.
    var hasAudio: Bool { loadedBookID != nil }

    // MARK: - Sleep timer

    /// Armed sleep timer, if any. Lives here (not the engine) so it survives
    /// reader pops and works from the lock screen; lives here (not the view)
    /// so a 1 Hz tick exists at all while the bar is off screen.
    private(set) var sleepTarget: SleepTarget?
    /// Wall-clock seconds until the target fires, refreshed at 1 Hz for the
    /// audio bar's pill label.
    private(set) var sleepRemainingSeconds: TimeInterval?
    private var sleepTimer: Timer?

    deinit {
        // App-lifetime object, so this is belt-and-braces — but if ownership
        // ever changes, a repeating timer must not outlive its target. Same
        // isolation argument as `AudioEngine.deinit`.
        MainActor.assumeIsolated {
            sleepTimer?.invalidate()
        }
    }

    func setSleepTimer(minutes: Int) {
        armSleep(.wallClock(Date.now.addingTimeInterval(TimeInterval(minutes) * 60)))
    }

    /// End of chapter: pause when the playhead reaches `time` (audio seconds).
    func setSleepTimer(untilAudioTime time: TimeInterval) {
        armSleep(.audioTime(time))
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTarget = nil
        sleepRemainingSeconds = nil
    }

    private func armSleep(_ target: SleepTarget) {
        cancelSleepTimer()
        sleepTarget = target
        sleepRemainingSeconds = remaining(of: target)
        // Same pattern as the engine's display timer: `Timer` closures run
        // nonisolated, so hop to the main actor explicitly. `.common` mode
        // keeps the countdown label live during scrolls and curl drags.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickSleep() }
        }
        sleepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tickSleep() {
        guard let target = sleepTarget else { return }
        let left = remaining(of: target)
        guard left > 0 else {
            cancelSleepTimer()
            // Fade rather than cut mid-word; a no-op if already paused
            // (wall-clock deadline reached while the user had paused).
            engine.pause(fadeOver: 3)
            return
        }
        sleepRemainingSeconds = left
    }

    /// Wall-clock seconds until `target` fires. Audio-time targets convert
    /// remaining audio seconds at the current rate.
    private func remaining(of target: SleepTarget) -> TimeInterval {
        switch target {
        case .wallClock(let date):
            return date.timeIntervalSinceNow
        case .audioTime(let time):
            return (time - engine.currentTime) / Double(max(engine.rate, 0.01))
        }
    }

    /// Present a book's audio when its reader appears.
    ///
    /// - Same book already loaded: no-op, returns true (re-opening keeps the
    ///   playback position instead of reloading from 0).
    /// - Different book, has an audiobook: load it in *switch* mode (replacing
    ///   whatever played). In *background* mode, only load if nothing is
    ///   playing — an already-playing book keeps going and this reader shows a
    ///   "play this audiobook" affordance instead.
    /// - Text-only book: never disturbs current audio.
    ///
    /// Returns whether the engine now reflects `book`.
    @discardableResult
    func present(book: Book, backgroundMode: Bool) async -> Bool {
        if loadedBookID == book.id { return true }
        guard let url = book.resolvedAudiobookURL else { return false }
        if backgroundMode && loadedBookID != nil { return false }
        return await load(book: book, url: url)
    }

    /// Explicit user switch: pressed play on a book whose audio isn't the one
    /// currently loaded (background mode). Replaces the current audio.
    @discardableResult
    func switchTo(book: Book) async -> Bool {
        if loadedBookID == book.id { return true }
        guard let url = book.resolvedAudiobookURL else { return false }
        return await load(book: book, url: url)
    }

    /// Whether `book` is the one the engine is currently loaded with — the
    /// gate for read-along, audio-position saving, and live transport UI.
    func isLoaded(_ book: Book) -> Bool { loadedBookID == book.id }

    /// Drop the current audio (e.g. the playing book was deleted, or its
    /// audiobook was replaced and must be reloaded fresh).
    func unload(ifBookID id: UUID? = nil) {
        if let id, id != loadedBookID { return }
        cancelSleepTimer()
        engine.stop()
        loadedBookID = nil
        loadedTitle = ""
        loadedAuthor = ""
        loadedCoverData = nil
    }

    private func load(book: Book, url: URL) async -> Bool {
        // A sleep target belongs to the book it was armed on — especially an
        // audio-time (end-of-chapter) one, which is meaningless on another
        // book's timeline.
        cancelSleepTimer()
        do {
            try await engine.load(url: url)
            loadFailureMessage = nil
            loadFailureBookID = nil
            // Re-apply the persisted playback rate: a fresh engine (app
            // relaunch) is at 1×. `setRate` clamps and no-ops on same-rate.
            let storedRate = UserDefaults.standard.double(forKey: AppSettings.playbackRateKey)
            if storedRate > 0 {
                engine.setRate(Float(storedRate))
            }
            loadedBookID = book.id
            loadedTitle = book.title
            loadedAuthor = book.author
            loadedCoverData = book.coverImageData
            engine.setNowPlayingMetadata(
                title: book.title,
                artist: book.author,
                artworkData: book.coverImageData
            )
            return true
        } catch {
            // Leave whatever was previously loaded untouched on failure (the
            // engine's open-before-touch guarantees its half) — but record
            // why, so the audio bar can say so and offer Retry.
            loadFailureMessage = error.localizedDescription
            loadFailureBookID = book.id
            return false
        }
    }
}
