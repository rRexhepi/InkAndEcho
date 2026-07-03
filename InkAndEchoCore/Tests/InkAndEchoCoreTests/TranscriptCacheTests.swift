import Foundation
import Testing
@testable import InkAndEchoCore

/// The transcript cache must round-trip Whisper output exactly, invalidate
/// itself on version bumps, and treat any unreadable state as a miss —
/// a cache bug here silently corrupts every subsequent alignment.
@Suite("Transcript cache")
struct TranscriptCacheTests {
    private func makeCache() throws -> TranscriptCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TranscriptCache(directory: dir)
    }

    private var words: [AudioWord] {
        [
            AudioWord(text: "quiet", startSeconds: 0.5, endSeconds: 0.9, confidence: 0.98),
            AudioWord(text: "harbor", startSeconds: 1.0, endSeconds: 1.6, confidence: 0.72),
        ]
    }

    @Test func roundTripsWords() throws {
        let cache = try makeCache()
        cache.store(words, key: "abc-base.en")
        let loaded = try #require(cache.load(key: "abc-base.en"))
        #expect(loaded.count == 2)
        #expect(loaded[0].text == "quiet")
        #expect(abs(loaded[1].startSeconds - 1.0) < 1e-9)
        #expect(abs(loaded[1].confidence - 0.72) < 1e-6)
    }

    @Test func missesOnUnknownKey() throws {
        let cache = try makeCache()
        cache.store(words, key: "abc-base.en")
        #expect(cache.load(key: "abc-tiny.en") == nil)
    }

    @Test func versionMismatchReadsAsMiss() throws {
        let cache = try makeCache()
        cache.store(words, key: "abc-base.en")
        // Rewrite the payload with a stale version.
        let file = cache.directory.appendingPathComponent("abc-base.en.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["version"] = TranscriptCache.version - 1
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(cache.load(key: "abc-base.en") == nil)
    }

    @Test func corruptFileReadsAsMiss() throws {
        let cache = try makeCache()
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cache.directory.appendingPathComponent("bad.json"))
        #expect(cache.load(key: "bad") == nil)
    }

    @Test func keyChangesWithContentAndModel() throws {
        let cache = try makeCache()
        let a = cache.directory.appendingPathComponent("a.bin")
        let b = cache.directory.appendingPathComponent("b.bin")
        try Data([1, 2, 3]).write(to: a)
        try Data([1, 2, 4]).write(to: b)
        let keyA = try #require(cache.key(forAudioAt: a, model: "base.en"))
        let keyB = try #require(cache.key(forAudioAt: b, model: "base.en"))
        let keyA2 = try #require(cache.key(forAudioAt: a, model: "tiny.en"))
        #expect(keyA != keyB)
        #expect(keyA != keyA2)
        #expect(keyA == cache.key(forAudioAt: a, model: "base.en"))
        #expect(cache.key(forAudioAt: cache.directory.appendingPathComponent("missing.bin"), model: "base.en") == nil)
    }
}
