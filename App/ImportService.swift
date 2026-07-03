import Foundation
import AVFoundation
import SwiftData
import InkAndEchoCore

@MainActor
struct ImportService {
    let modelContext: ModelContext

    /// Imports a book from a source URL. Supported formats route through
    /// `EBookImporterRegistry`: EPUB and MOBI/PRC/AZW (pure Swift parsers),
    /// PDF (PDFKit). The original file is copied into the app's Application
    /// Support directory under `book.<canonical-ext>` and re-parsed on every
    /// open, so adding a new format requires no schema changes.
    ///
    /// Calibre's `ebook-convert` was the prior PDF / AZW3 path on macOS but
    /// is dormant — App Sandbox blocks subprocess execution of arbitrary
    /// binaries, and Calibre's GPLv3 license is incompatible with App Store
    /// distribution. PDFKit replaces it for PDF; AZW3 / KF8 throw
    /// `unsupportedKF8` and prompt the user to convert externally.
    func importBook(from sourceURL: URL) async throws -> Book {
        let ext = sourceURL.pathExtension.lowercased()
        guard let storedExt = EBookImporterRegistry.storedExtension(forSource: ext),
              let importer = EBookImporterRegistry.importer(forExtension: ext) else {
            throw ImportServiceError.unsupportedFormat(ext)
        }

        // `.fileImporter` returns security-scoped URLs on iOS; reads
        // succeed only between start/stop calls. Without this, the
        // open + copy below fail with EPERM and the picker appears
        // to silently no-op.
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let imported = try await importer.importBook(from: sourceURL)

        let bookID = UUID()
        let bookDir = try appStorageURL()
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

        let storedURL = bookDir.appendingPathComponent("book.\(storedExt)")
        try await Self.copyOffMain(from: sourceURL, to: storedURL)

        let book = Book(
            id: bookID,
            title: imported.title,
            author: imported.author,
            coverImageData: imported.coverImageData.map { downsampledCoverData($0) },
            ebookFileURL: storedURL,
            audiobookFileURL: nil,
            alignmentMapURL: nil,
            totalDurationSeconds: 0,
            totalPages: imported.totalPages,
            addedAt: .now
        )
        modelContext.insert(book)
        try modelContext.save()
        return book
    }

    /// Attaches an audiobook file to an existing book. Copies the file into the
    /// book's storage directory and reads its duration for display.
    func attachAudiobook(_ url: URL, to book: Book) async throws {
        let bookDir = try bookDir(for: book)

        // See `importBook` — picker URLs are security-scoped on iOS and
        // the copy below fails silently without start/stop access.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        // Copy FIRST, into a temp name. The old flow deleted the previous
        // `audiobook.*` and `alignment.json` before copying — and `copyItem`
        // fails routinely (undownloaded iCloud file, disk full on a multi-GB
        // m4b), which destroyed the user's working audiobook plus a
        // 30-minute alignment and left `audiobookFileURL` pointing at
        // nothing. Nothing is removed until the new file is safely on disk.
        let tempURL = bookDir.appendingPathComponent("audiobook.incoming.\(url.pathExtension)")
        try? FileManager.default.removeItem(at: tempURL)
        try await Self.copyOffMain(from: url, to: tempURL)

        try await finalizeAttach(tempURL: tempURL, ext: url.pathExtension, bookDir: bookDir, book: book, chapters: nil)
    }

    /// Multi-part attach: parts are ordered (track tags, natural-sort
    /// fallback), stitched into one AAC m4a, and handed to the exact same
    /// temp-then-retire dance as the single-file path — crash safety and
    /// stale-alignment purge are reused verbatim. Part offsets land in
    /// `chapters.json` beside the audio. Cancel via the surrounding Task;
    /// nothing on disk changes on cancellation or failure.
    func attachAudiobook(_ urls: [URL], to book: Book, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard urls.count > 1 else {
            guard let url = urls.first else { return }
            return try await attachAudiobook(url, to: book)
        }
        let bookDir = try bookDir(for: book)

        // Scope spans the whole merge: the export streams from every source
        // until it finishes.
        let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, needsScope) in scoped where needsScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ordered = await Self.resolvedPartOrder(urls)
        let tempURL = bookDir.appendingPathComponent("audiobook.incoming.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        let chapters = try await Self.mergeParts(ordered, into: tempURL, progress: progress)

        try await finalizeAttach(tempURL: tempURL, ext: "m4a", bookDir: bookDir, book: book, chapters: chapters)
    }

    /// Bundled demo trio (epub + m4b + PRE-BAKED alignment.json): the epub
    /// imports through the normal path, the audio attaches through the
    /// normal path, then the baked map drops in and `alignmentMapURL` is
    /// set directly (it's just a stored URL) — read-along is live seconds
    /// after "Try it", no model download, no align wait. The map was baked
    /// headless with the same importer + aligner against these exact
    /// files, so segment IDs and word indices match what the app derives
    /// when it re-parses the epub at open.
    func installDemoBook(epub: URL, audio: URL, alignment: URL) async throws -> Book {
        let book = try await importBook(from: epub)
        try await attachAudiobook(audio, to: book)
        let mapURL = try bookDir(for: book).appendingPathComponent("alignment.json")
        try FileManager.default.copyItem(at: alignment, to: mapURL)
        book.alignmentMapURL = mapURL
        try modelContext.save()
        return book
    }

    /// The parts in playback order: by track-number tag (ID3 `TRCK` /
    /// iTunes `trkn`) when every part carries a distinct one, otherwise
    /// Finder-style natural filename sort (zero-padding-proof).
    nonisolated static func resolvedPartOrder(_ urls: [URL]) async -> [URL] {
        guard urls.count > 1 else { return urls }
        var tracks: [URL: Int] = [:]
        for url in urls {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            guard let metadata = try? await AVURLAsset(url: url).load(.metadata) else { continue }
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataTrackNumber)
                + AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataTrackNumber)
            for item in items {
                if let number = (try? await item.load(.numberValue)) ?? nil {
                    tracks[url] = number.intValue
                    break
                }
                // ID3 track tags are strings, routinely "3/12".
                if let string = (try? await item.load(.stringValue)) ?? nil,
                   let number = Int(string.prefix(while: \.isNumber)) {
                    tracks[url] = number
                    break
                }
            }
        }
        if tracks.count == urls.count, Set(tracks.values).count == urls.count {
            return urls.sorted { tracks[$0]! < tracks[$1]! }
        }
        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// One AAC m4a from the ordered parts via `AVMutableComposition` —
    /// re-encoding through the AppleM4A preset also irons out mixed source
    /// codecs and sample rates. Composition inserts are metadata work; the
    /// export is the long pole, so progress polls it and Task cancellation
    /// cancels it mid-flight. Nonisolated: sample-table reads during insert
    /// must not stall the main actor.
    private nonisolated static func mergeParts(
        _ urls: [URL],
        into outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AudiobookChapters {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ImportServiceError.unplayableAudio("Couldn't create a composition track.")
        }
        var chapters: [AudiobookChapters.Chapter] = []
        var cursor = CMTime.zero
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration) else {
                throw ImportServiceError.unplayableAudio("\(url.lastPathComponent) has no readable audio track.")
            }
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: cursor)
            } catch {
                throw ImportServiceError.unplayableAudio("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            chapters.append(.init(title: await partTitle(for: asset, fallback: url), startSeconds: cursor.seconds))
            cursor = cursor + duration
            progress(0.05 * Double(index + 1) / Double(urls.count))
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportServiceError.unplayableAudio("Audio export isn't available for these files.")
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a

        let box = ExportBox(session)
        let poll = Task.detached {
            while !Task.isCancelled {
                progress(0.05 + 0.95 * Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poll.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            try Task.checkCancellation()
            throw ImportServiceError.unplayableAudio(session.error?.localizedDescription ?? "Audio export failed.")
        }
        return AudiobookChapters(chapters: chapters)
    }

    private nonisolated static func partTitle(for asset: AVAsset, fallback url: URL) async -> String {
        if let metadata = try? await asset.load(.commonMetadata),
           let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first,
           let title = (try? await item.load(.stringValue)) ?? nil,
           !title.isEmpty {
            return title
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `AVAssetExportSession` isn't Sendable, but `progress`,
    /// `cancelExport()`, and `exportAsynchronously` are thread-safe; this box
    /// carries exactly those uses across the poll/cancellation boundaries.
    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    /// Shared tail of every attach: probe, retire the old artifacts, move
    /// the new audio into place, persist.
    private func finalizeAttach(tempURL: URL, ext: String, bookDir: URL, book: Book, chapters: AudiobookChapters?) async throws {
        // Probe BEFORE retiring anything: a file the engine can't open
        // (DRM-protected m4b, corrupt download) must fail the attach while
        // the user's working audiobook and its alignment are still on disk —
        // otherwise it surfaces later as a dead play button.
        do {
            _ = try AVAudioFile(forReading: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImportServiceError.unplayableAudio(error.localizedDescription)
        }

        // New audio is safe — now retire the old audio, its alignment
        // (computed against the old audio's timestamps), and any part
        // offsets from a previous multi-file attach. The new pick may have
        // a different extension, so a same-name remove isn't enough.
        if let contents = try? FileManager.default.contentsOfDirectory(at: bookDir, includingPropertiesForKeys: nil) {
            for entry in contents
            where entry.lastPathComponent.hasPrefix("audiobook.") && entry != tempURL {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        try? FileManager.default.removeItem(at: bookDir.appendingPathComponent("alignment.json"))
        try? FileManager.default.removeItem(at: bookDir.appendingPathComponent("chapters.json"))
        book.alignmentMapURL = nil

        let stored = bookDir.appendingPathComponent("audiobook.\(ext)")
        try FileManager.default.moveItem(at: tempURL, to: stored)
        // Sidecar for future scrubber ticks — losing it doesn't fail the attach.
        try? chapters?.write(to: bookDir.appendingPathComponent("chapters.json"))

        let asset = AVURLAsset(url: stored)
        let duration = (try? await asset.load(.duration)) ?? .zero

        book.audiobookFileURL = stored
        book.totalDurationSeconds = CMTimeGetSeconds(duration)
        try modelContext.save()
    }

    private func bookDir(for book: Book) throws -> URL {
        guard let ebookURL = book.resolvedEbookURL else {
            throw ImportServiceError.missingEbook
        }
        return ebookURL.deletingLastPathComponent()
    }

    /// Removes a book and its on-disk files. Record first, files second: if
    /// the save fails, the book is still intact rather than a zombie row
    /// pointing at deleted files. The directory is derived from the book ID
    /// (not the ebook URL), so a book whose ebook copy failed but whose
    /// audio exists doesn't orphan its files forever.
    func deleteBook(_ book: Book) throws {
        let bookID = book.id
        modelContext.delete(book)
        try modelContext.save()
        let dir = try appStorageURL()
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Byte copies happen off the main actor — a multi-hundred-MB m4b copy
    /// inline froze the UI for its full duration. The security-scoped access
    /// started by the caller is process-wide per URL, so it remains valid on
    /// the worker thread (the caller's `defer` stops it only after this
    /// returns). Same-volume moves/removals stay inline: they're metadata
    /// operations.
    private static func copyOffMain(from src: URL, to dst: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: src, to: dst)
        }.value
    }

    private func appStorageURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("InkAndEcho", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum ImportServiceError: LocalizedError {
    case unsupportedFormat(String)
    case missingEbook
    case unplayableAudio(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file type: .\(ext). Use .epub, .mobi, or .pdf."
        case .missingEbook:
            return "Book has no associated ebook file."
        case .unplayableAudio(let detail):
            return "This audio file can't be played — it may be DRM-protected or damaged. Your current audiobook was left untouched. (\(detail))"
        }
    }
}
