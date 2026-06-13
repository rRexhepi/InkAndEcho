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
        guard let ebookURL = book.resolvedEbookURL else {
            throw ImportServiceError.missingEbook
        }
        let bookDir = ebookURL.deletingLastPathComponent()
        let stored = bookDir.appendingPathComponent("audiobook.\(url.pathExtension)")

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

        // New audio is safe — now retire the old audio and its alignment
        // (computed against the old audio's timestamps). The new pick may
        // have a different extension, so a same-name remove isn't enough.
        if let contents = try? FileManager.default.contentsOfDirectory(at: bookDir, includingPropertiesForKeys: nil) {
            for entry in contents
            where entry.lastPathComponent.hasPrefix("audiobook.") && entry != tempURL {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        let alignmentPath = bookDir.appendingPathComponent("alignment.json")
        try? FileManager.default.removeItem(at: alignmentPath)
        book.alignmentMapURL = nil

        try FileManager.default.moveItem(at: tempURL, to: stored)

        let asset = AVURLAsset(url: stored)
        let duration = (try? await asset.load(.duration)) ?? .zero

        book.audiobookFileURL = stored
        book.totalDurationSeconds = CMTimeGetSeconds(duration)
        try modelContext.save()
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

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file type: .\(ext). Use .epub, .mobi, or .pdf."
        case .missingEbook:
            return "Book has no associated ebook file."
        }
    }
}
