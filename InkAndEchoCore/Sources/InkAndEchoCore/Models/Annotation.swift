import Foundation
import SwiftData

/// Live model — the V2 class, re-exported under its plain name. See
/// SchemaVersions.swift for the versioning rules before changing anything.
public typealias Annotation = InkAndEchoSchemaV2.Annotation

extension InkAndEchoSchemaV2 {
    @Model
    public final class Annotation {
        @Attribute(.unique) public var id: UUID
        public var book: Book?
        /// Anchor of the highlight start. Stored as `"<segmentID>#p<paragraphIndex>"`
        /// for paragraph-level annotations; full EPUB CFI is reserved for v2 when
        /// real text-range selection lands.
        public var cfiStart: String
        public var cfiEnd: String
        public var colorRaw: String
        public var kindRaw: String
        public var note: String
        public var createdAt: Date

        public var color: AnnotationColor {
            get { AnnotationColor(rawValue: colorRaw) ?? .amber }
            set { colorRaw = newValue.rawValue }
        }

        public var kind: AnnotationKind {
            get { AnnotationKind(rawValue: kindRaw) ?? .highlight }
            set { kindRaw = newValue.rawValue }
        }

        public init(
            id: UUID = UUID(),
            book: Book? = nil,
            cfiStart: String,
            cfiEnd: String,
            kind: AnnotationKind = .highlight,
            color: AnnotationColor = .amber,
            note: String = "",
            createdAt: Date = .now
        ) {
            self.id = id
            self.book = book
            self.cfiStart = cfiStart
            self.cfiEnd = cfiEnd
            self.kindRaw = kind.rawValue
            self.colorRaw = color.rawValue
            self.note = note
            self.createdAt = createdAt
        }
    }
}

public extension Annotation {
    /// Encode a paragraph-level location.
    static func locator(segmentID: String, paragraphIndex: Int) -> String {
        "\(segmentID)#p\(paragraphIndex)"
    }

    /// Encode a word-level location (one specific word inside a paragraph).
    static func locator(segmentID: String, paragraphIndex: Int, wordIndex: Int) -> String {
        "\(segmentID)#p\(paragraphIndex)w\(wordIndex)"
    }

    /// Decode the paragraph component of either a paragraph- or word-level
    /// locator. Word-level annotations still have a paragraph anchor, so this
    /// returns that for both. Returns nil for unrecognised formats (e.g. a
    /// real EPUB CFI from a future version).
    var paragraphLocation: (segmentID: String, paragraphIndex: Int)? {
        let parts = cfiStart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let fragment = parts[1]
        guard fragment.hasPrefix("p") else { return nil }
        let afterP = fragment.dropFirst()
        let pPart = afterP.split(separator: "w", maxSplits: 1).first ?? afterP[...]
        guard let index = Int(pPart) else { return nil }
        return (String(parts[0]), index)
    }

    /// Decode a word-level locator. Returns nil for paragraph-level
    /// annotations (they have no word component).
    var wordLocation: (segmentID: String, paragraphIndex: Int, wordIndex: Int)? {
        let parts = cfiStart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let fragment = parts[1]
        guard fragment.hasPrefix("p") else { return nil }
        let afterP = fragment.dropFirst()
        let split = afterP.split(separator: "w", maxSplits: 1)
        guard split.count == 2,
              let paragraphIdx = Int(split[0]),
              let wordIdx = Int(split[1]) else { return nil }
        return (String(parts[0]), paragraphIdx, wordIdx)
    }
}

/// The five muted naturals from DESIGN.md. Bookmarks reuse this enum but
/// conventionally render in `accent` (saddle) rather than an annotation color.
public enum AnnotationColor: String, Codable, CaseIterable, Sendable {
    case amber
    case sage
    case rose
    case slate
    case plum
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case highlight
    case bookmark
    case note
}
