import Foundation
import SwiftData
import PalimpsestCore

@MainActor
struct AlignmentService {
    let modelContext: ModelContext

    /// Runs the full alignment pipeline for a book that already has both an ebook
    /// and an audiobook attached. Saves the resulting `AlignmentMap` as JSON next
    /// to the book's other files and stores the URL on the `Book` row.
    func runAlignment(
        for book: Book,
        progress: @MainActor @escaping (AlignmentStage) -> Void = { _ in }
    ) async throws {
        guard let ebookURL = book.resolvedEbookURL,
              let audioURL = book.resolvedAudiobookURL else {
            throw AlignmentServiceError.missingFiles
        }

        progress(.loadingModel(model: "parsing book"))
        guard let importer = EBookImporterRegistry.importer(for: ebookURL) else {
            throw ImporterError.unsupportedFormat
        }
        let imported = try await importer.importBook(from: ebookURL)
        let input = AlignmentInput(segments: imported.segments)

        let aligner = WhisperAligner()
        let map = try await aligner.align(audioURL: audioURL, input: input) { stage in
            // WhisperKit invokes this from its own queue; bounce to main.
            Task { @MainActor in
                progress(stage)
            }
        }

        let bookDir = ebookURL.deletingLastPathComponent()
        let mapURL = bookDir.appendingPathComponent("alignment.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(map)
        try data.write(to: mapURL, options: .atomic)

        book.alignmentMapURL = mapURL
        try modelContext.save()
        progress(.complete(wordsAligned: map.words.count, sentencesAligned: map.sentences.count))
    }

    func loadAlignmentMap(for book: Book) -> AlignmentMap? {
        guard let url = book.resolvedAlignmentMapURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AlignmentMap.self, from: data)
    }
}

enum AlignmentServiceError: LocalizedError {
    case missingFiles

    var errorDescription: String? {
        switch self {
        case .missingFiles:
            return "Both an ebook and an audiobook must be attached before aligning."
        }
    }
}
