import Foundation

/// Part boundaries recorded when a multi-file audiobook is stitched into one
/// file at attach time. Sits beside the audio as `chapters.json` — future
/// scrubber ticks / chapter labels read it. The engine, aligner, and Book
/// schema stay single-URL and never look at this.
public struct AudiobookChapters: Codable, Sendable, Equatable {
    public struct Chapter: Codable, Sendable, Equatable {
        /// Source-part title (metadata title tag, else filename stem).
        public let title: String
        /// Cumulative offset of this part's start in the stitched file.
        public let startSeconds: Double

        public init(title: String, startSeconds: Double) {
            self.title = title
            self.startSeconds = startSeconds
        }
    }

    public let chapters: [Chapter]

    public init(chapters: [Chapter]) {
        self.chapters = chapters
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> AudiobookChapters {
        try JSONDecoder().decode(AudiobookChapters.self, from: Data(contentsOf: url))
    }
}
