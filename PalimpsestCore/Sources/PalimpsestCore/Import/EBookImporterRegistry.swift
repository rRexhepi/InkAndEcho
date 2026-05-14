import Foundation

/// Picks the right `EBookImporter` for a file. Centralises the extension →
/// importer mapping so callers (ImportService, ReaderView, AlignmentService)
/// never have to know which concrete type handles which format.
///
/// Stored files inside a book directory follow the convention `book.<ext>`
/// where `<ext>` matches the original source; the reader re-parses on every
/// open. Adding a new format = implement EBookImporter, add a case below.
public enum EBookImporterRegistry {
    public static func importer(for url: URL) -> EBookImporter? {
        importer(forExtension: url.pathExtension.lowercased())
    }

    public static func importer(forExtension ext: String) -> EBookImporter? {
        switch ext {
        case "epub":
            return EPUBImporter()
        case "mobi", "prc", "azw":
            return MOBIImporter()
        case "pdf":
            return PDFImporter()
        default:
            return nil
        }
    }

    /// Canonical extension we use to name the on-disk copy of `<format>`.
    /// Distinct from the source extension only for aliased formats like
    /// `.prc` / `.azw`, which we store as `.mobi`.
    public static func storedExtension(forSource ext: String) -> String? {
        switch ext.lowercased() {
        case "epub": return "epub"
        case "mobi", "prc", "azw": return "mobi"
        case "pdf": return "pdf"
        default: return nil
        }
    }
}
