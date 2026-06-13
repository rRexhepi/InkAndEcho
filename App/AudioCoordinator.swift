import Foundation
import InkAndEchoCore

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

    /// True once any book's audio is loaded — drives the library mini-player.
    var hasAudio: Bool { loadedBookID != nil }

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
        engine.stop()
        loadedBookID = nil
        loadedTitle = ""
        loadedAuthor = ""
        loadedCoverData = nil
    }

    private func load(book: Book, url: URL) async -> Bool {
        do {
            try await engine.load(url: url)
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
            // Leave whatever was previously loaded untouched on failure.
            return false
        }
    }
}
