import Foundation
import Testing
@testable import InkAndEchoCore

@Suite("AudiobookChapters")
struct AudiobookChaptersTests {
    @Test func roundTripsThroughDisk() throws {
        let chapters = AudiobookChapters(chapters: [
            .init(title: "Part 1", startSeconds: 0),
            .init(title: "Part 2", startSeconds: 1832.5),
            .init(title: "Part 3", startSeconds: 3719.25),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chapters-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try chapters.write(to: url)
        #expect(try AudiobookChapters.load(from: url) == chapters)
    }
}
