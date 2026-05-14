import Foundation

public protocol PDFToEPUBConverter: Sendable {
    func convert(pdfURL: URL, outputDirectory: URL) async throws -> URL
}

/// Shells out to Calibre's bundled `ebook-convert` binary.
///
/// **No longer wired into the app**: PDF goes through `PDFImporter` (PDFKit)
/// and MOBI through the pure-Swift `MOBIImporter`. Both are App Sandbox-safe
/// and App Store-eligible. This type is kept for the local-dev path on a
/// developer-installed macOS where someone might still want to bulk-convert
/// AZW3 / KF8 / DOCX files outside the app.
///
/// Expects Calibre installed at `/Applications/calibre.app`. If absent, throws
/// `ConverterError.calibreNotFound`.
public struct CalibreConverter: PDFToEPUBConverter {
    public static let defaultBinaryPath = "/Applications/calibre.app/Contents/MacOS/ebook-convert"
    public let binaryPath: String

    public init(binaryPath: String = defaultBinaryPath) {
        self.binaryPath = binaryPath
    }

    public func convert(pdfURL: URL, outputDirectory: URL) async throws -> URL {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw ConverterError.calibreNotFound(binaryPath)
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = outputDirectory
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("epub")

        return try await spawn(binary: binaryPath, args: [pdfURL.path, outputURL.path], output: outputURL)
        #else
        throw ConverterError.unsupportedPlatform
        #endif
    }
}

#if os(macOS)
private func spawn(binary: String, args: [String], output: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        process.terminationHandler = { proc in
            if proc.terminationStatus == 0 {
                continuation.resume(returning: output)
            } else {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                let msg = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n")
                    .suffix(3)
                    .joined(separator: " · ")
                continuation.resume(throwing: ConverterError.conversionFailed(
                    msg.isEmpty ? "ebook-convert exit \(proc.terminationStatus)" : msg
                ))
            }
        }

        do {
            try process.run()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}
#endif

public enum ConverterError: Error, Sendable {
    case unsupportedPlatform
    case calibreNotFound(String)
    case conversionFailed(String)
}
