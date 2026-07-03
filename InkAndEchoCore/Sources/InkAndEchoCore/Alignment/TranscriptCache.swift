import Foundation
import CryptoKit

/// Disk cache for Whisper transcripts, keyed by sha256(audio) + model.
/// Transcription dominates alignment cost (~30 min for a novel), so
/// re-aligning the same audio — after replacing the EPUB, attaching the
/// file to another book record, or iterating on the matcher — should cost
/// seconds, not another full pass. Lives in Caches on purpose: transcripts
/// are regenerable, so the system may purge them and they're never backed
/// up (App Support would upload multi-MB JSON to every iCloud backup).
struct TranscriptCache: Sendable {
    /// Bump whenever the transcription pipeline changes in a way that makes
    /// previously-cached transcripts wrong — `normalizeWord`,
    /// `isSeamDuplicate`, chunk/overlap sizing. Mismatched versions read as
    /// a miss and the next write replaces them.
    static let version = 1

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptCache", isDirectory: true)
    }

    /// Cache key for an audio file transcribed by `model`. The sha256 is
    /// streamed in 1 MB chunks so a multi-GB audiobook never sits in
    /// memory just to be hashed. nil when the file can't be read — the
    /// caller simply skips the cache.
    func key(forAudioAt url: URL, model: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(digest)-\(model)"
    }

    func load(key: String) -> [AudioWord]? {
        guard let data = try? Data(contentsOf: fileURL(key: key)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.version else { return nil }
        return payload.words
    }

    /// Best-effort: a failed cache write must never fail the alignment.
    func store(_ words: [AudioWord], key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Payload(version: Self.version, words: words)) else { return }
        try? data.write(to: fileURL(key: key), options: .atomic)
    }

    private func fileURL(key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private struct Payload: Codable {
        let version: Int
        let words: [AudioWord]
    }
}
