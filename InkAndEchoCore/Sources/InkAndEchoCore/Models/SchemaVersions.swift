import Foundation
import SwiftData

// MARK: - Versioned schema spine
//
// V1 is the schema exactly as shipped in 0.2.0 (build 11), frozen below —
// these nested classes are never instantiated by app code; they exist so
// SwiftData can identify an on-disk V1 store and run the migration plan.
// The LIVE model classes are the V2 ones (declared in Book.swift /
// ReadingProgress.swift / Annotation.swift as extensions of
// `InkAndEchoSchemaV2`, re-exported through `public typealias`).
//
// Rules for future model changes:
//   1. NEVER edit a frozen version's classes. Copy the latest version's
//      classes into a new `InkAndEchoSchemaV<N+1>`, point the typealiases
//      at it, and add a stage to `InkAndEchoMigrationPlan`.
//   2. Keep changes lightweight (added properties need defaults) unless
//      you write a custom stage with willMigrate/didMigrate.
//   3. `InkAndEchoApp.makeContainer()` is the only container constructor;
//      it carries the recovery path for failed migrations.

public enum InkAndEchoSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Book.self, Annotation.self, ReadingProgress.self]
    }

    @Model
    public final class Book {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var author: String
        public var coverImageData: Data?
        public var ebookFileURL: URL?
        public var audiobookFileURL: URL?
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

    @Model
    public final class ReadingProgress {
        @Attribute(.unique) public var id: UUID
        public var book: Book?
        public var currentCFI: String
        public var currentAudioSeconds: TimeInterval
        public var currentPageIndex: Int = 0
        public var lastReadAt: Date

        public init(
            id: UUID = UUID(),
            book: Book? = nil,
            currentCFI: String = "",
            currentAudioSeconds: TimeInterval = 0,
            currentPageIndex: Int = 0,
            lastReadAt: Date = .now
        ) {
            self.id = id
            self.book = book
            self.currentCFI = currentCFI
            self.currentAudioSeconds = currentAudioSeconds
            self.currentPageIndex = currentPageIndex
            self.lastReadAt = lastReadAt
        }
    }

    @Model
    public final class Annotation {
        @Attribute(.unique) public var id: UUID
        public var book: Book?
        public var cfiStart: String
        public var cfiEnd: String
        public var colorRaw: String
        public var kindRaw: String
        public var note: String
        public var createdAt: Date

        public init(
            id: UUID = UUID(),
            book: Book? = nil,
            cfiStart: String,
            cfiEnd: String,
            kindRaw: String,
            colorRaw: String,
            note: String = "",
            createdAt: Date = .now
        ) {
            self.id = id
            self.book = book
            self.cfiStart = cfiStart
            self.cfiEnd = cfiEnd
            self.kindRaw = kindRaw
            self.colorRaw = colorRaw
            self.note = note
            self.createdAt = createdAt
        }
    }
}

/// V2 — current. Changes from V1, both lightweight:
///   - `Book.coverImageData` gains `.externalStorage` (covers were inlined
///     in the store, bloating it and materializing on every library row).
///   - `ReadingProgress.firstWordIndex` added (chapter-global word the saved
///     page starts at, so restore survives pagination-budget changes;
///     -1 = unknown, fall back to the raw page index).
public enum InkAndEchoSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Book.self, Annotation.self, ReadingProgress.self]
    }
}

public enum InkAndEchoMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [InkAndEchoSchemaV1.self, InkAndEchoSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: InkAndEchoSchemaV1.self,
                toVersion: InkAndEchoSchemaV2.self
            ),
        ]
    }
}
