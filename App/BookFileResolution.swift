import Foundation
import PalimpsestCore

/// Resolves on-disk URLs stored on a `Book` record, falling back to a
/// sandbox-relative rebase when the absolute URL no longer points at a
/// real file.
///
/// Why this exists: `ImportService` stores absolute file URLs at import
/// time. On iOS, the data container UUID embedded in those URLs is not a
/// stable identity — it can rotate when the system rebuilds the app
/// container (some reinstalls, restored backups, certain device migrations
/// on real devices, and reliably across `simctl install` cycles in the
/// simulator if the bundle is reinstalled rather than updated). When that
/// happens, the SwiftData record survives but the embedded URL is dead,
/// so opening the book throws `ImporterError.malformedEPUB("Cannot open
/// archive: …")` and the reader never loads.
///
/// The rescue: if the stored URL doesn't exist, walk back from the
/// `Palimpsest` directory name, take the trailing components, and rejoin
/// them onto the *current* Application Support root. The Books directory
/// itself is preserved across reinstalls because Application Support
/// persists with the data container; only the absolute prefix changed.
extension Book {
    /// On-disk URL for the ebook. Returns the stored URL if it still
    /// exists, otherwise rebases to the current sandbox. Falls through to
    /// `nil` if no rescue path resolves either.
    var resolvedEbookURL: URL? {
        BookFileResolution.resolve(stored: ebookFileURL)
    }

    /// Same rescue strategy for the audiobook URL.
    var resolvedAudiobookURL: URL? {
        BookFileResolution.resolve(stored: audiobookFileURL)
    }

    /// Same for the cached AlignmentMap.
    var resolvedAlignmentMapURL: URL? {
        BookFileResolution.resolve(stored: alignmentMapURL)
    }
}

enum BookFileResolution {
    static func resolve(stored: URL?) -> URL? {
        guard let stored else { return nil }
        if FileManager.default.fileExists(atPath: stored.path) {
            return stored
        }
        return rebaseToCurrentSandbox(stored)
    }

    /// Reconstructs the URL by taking everything from `Palimpsest/` onward
    /// in the stored path and re-joining it to the current Application
    /// Support root. Returns `nil` if the file isn't there either.
    private static func rebaseToCurrentSandbox(_ stored: URL) -> URL? {
        let components = stored.pathComponents
        guard let palimpsestIdx = components.firstIndex(of: "Palimpsest") else { return nil }
        let suffix = components[(palimpsestIdx + 1)...]  // Books, <UUID>, book.<ext>
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        var rebased = appSupport.appendingPathComponent("Palimpsest", isDirectory: true)
        for component in suffix {
            rebased.append(component: component)
        }
        return FileManager.default.fileExists(atPath: rebased.path) ? rebased : nil
    }
}
