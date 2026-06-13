import Foundation
import SwiftData

/// Live model — the V2 class, re-exported under its plain name. See
/// SchemaVersions.swift for the versioning rules before changing anything.
public typealias Book = InkAndEchoSchemaV2.Book

extension InkAndEchoSchemaV2 {
    @Model
    public final class Book {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var author: String
        /// Cover bytes live OUTSIDE the store file (V2): full-resolution
        /// covers inlined in SQLite bloated it and materialized on every
        /// library-grid row fetch.
        @Attribute(.externalStorage) public var coverImageData: Data?

        /// On-disk URL of the book file. Stored as `book.<ext>` where `<ext>`
        /// is the format's canonical extension (epub / mobi / pdf). The reader
        /// dispatches to the right `EBookImporter` via `EBookImporterRegistry`
        /// on each open.
        public var ebookFileURL: URL?
        /// On-disk URL of the .m4b (or other audiobook format) file.
        public var audiobookFileURL: URL?
        /// On-disk URL of the cached AlignmentMap JSON for this book.
        public var alignmentMapURL: URL?

        public var totalDurationSeconds: TimeInterval
        public var totalPages: Int
        public var addedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \Annotation.book)
        public var annotations: [Annotation] = []

        @Relationship(deleteRule: .cascade, inverse: \ReadingProgress.book)
        public var progress: ReadingProgress?

        public init(
            id: UUID = UUID(),
            title: String,
            author: String,
            coverImageData: Data? = nil,
            ebookFileURL: URL? = nil,
            audiobookFileURL: URL? = nil,
            alignmentMapURL: URL? = nil,
            totalDurationSeconds: TimeInterval = 0,
            totalPages: Int = 0,
            addedAt: Date = .now
        ) {
            self.id = id
            self.title = title
            self.author = author
            self.coverImageData = coverImageData
            self.ebookFileURL = ebookFileURL
            self.audiobookFileURL = audiobookFileURL
            self.alignmentMapURL = alignmentMapURL
            self.totalDurationSeconds = totalDurationSeconds
            self.totalPages = totalPages
            self.addedAt = addedAt
        }
    }
}
