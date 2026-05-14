import Foundation
import PDFKit
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// PDFKit-based importer. Replaces the dormant Calibre subprocess path with
// an App Sandbox-safe, App Store-eligible extractor that works on iOS and
// macOS without third-party dependencies.
//
// Outline-aware: if the PDF has bookmarks we treat each top-level entry as
// a chapter (segment). Otherwise the document becomes a single segment.
// Cover is rendered from page 1 to a PNG via CoreGraphics + ImageIO, so we
// don't pull in UIKit or AppKit at this layer.

public struct PDFImporter: EBookImporter {
    public init() {}

    public func importBook(from url: URL) async throws -> ImportedBook {
        guard let doc = PDFDocument(url: url) else {
            throw ImporterError.malformedPDF("PDFKit could not open the file.")
        }
        if doc.isLocked {
            throw ImporterError.drmProtected
        }
        guard doc.pageCount > 0 else {
            throw ImporterError.malformedPDF("PDF has no pages.")
        }

        let attrs = doc.documentAttributes ?? [:]
        let rawTitle = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false ? rawTitle! : url.deletingPathExtension().lastPathComponent)
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "Unknown"

        let segments = extractSegments(from: doc)
        let cover = renderCover(from: doc)

        return ImportedBook(
            title: title,
            author: author,
            coverImageData: cover,
            segments: segments,
            totalPages: doc.pageCount
        )
    }
}

// MARK: - Segmentation

private func extractSegments(from doc: PDFDocument) -> [TextSegment] {
    if let outline = doc.outlineRoot, outline.numberOfChildren > 0 {
        let entries = collectTopLevelOutline(outline, doc: doc)
        if let segments = segmentsFromOutline(entries: entries, doc: doc), !segments.isEmpty {
            return segments
        }
    }
    return singleSegment(from: doc)
}

private struct OutlineEntry {
    let title: String
    let startPage: Int
}

private func collectTopLevelOutline(_ root: PDFOutline, doc: PDFDocument) -> [OutlineEntry] {
    var entries: [OutlineEntry] = []
    for i in 0..<root.numberOfChildren {
        guard let child = root.child(at: i) else { continue }
        let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dest = child.destination, let page = dest.page else { continue }
        let pageIdx = doc.index(for: page)
        entries.append(OutlineEntry(title: label, startPage: pageIdx))
    }
    return entries.sorted { $0.startPage < $1.startPage }
}

private func segmentsFromOutline(entries: [OutlineEntry], doc: PDFDocument) -> [TextSegment]? {
    guard !entries.isEmpty else { return nil }
    var out: [TextSegment] = []
    for (i, entry) in entries.enumerated() {
        let endPage = i + 1 < entries.count ? entries[i + 1].startPage : doc.pageCount
        guard entry.startPage < endPage else { continue }
        let text = pageRangeText(doc: doc, from: entry.startPage, until: endPage)
        if text.isEmpty { continue }
        out.append(TextSegment(
            id: "pdf-\(i + 1)",
            title: entry.title.isEmpty ? nil : entry.title,
            text: text
        ))
    }
    return out.isEmpty ? nil : out
}

private func singleSegment(from doc: PDFDocument) -> [TextSegment] {
    let text = pageRangeText(doc: doc, from: 0, until: doc.pageCount)
    return text.isEmpty ? [] : [TextSegment(id: "pdf-1", title: nil, text: text)]
}

private func pageRangeText(doc: PDFDocument, from: Int, until: Int) -> String {
    var buf = ""
    for i in from..<until {
        guard let page = doc.page(at: i), let str = page.string else { continue }
        let cleaned = normalizePageText(str)
        if cleaned.isEmpty { continue }
        if !buf.isEmpty { buf += "\n\n" }
        buf += cleaned
    }
    return buf.trimmingCharacters(in: .whitespacesAndNewlines)
}

// Collapse soft-hyphen breaks ("foo-\nbar" -> "foobar") and runs of
// whitespace that PDFKit emits when a page's word layout is sparse.
private func normalizePageText(_ raw: String) -> String {
    var s = raw
    s = s.replacingOccurrences(of: "-\n", with: "")
    s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Cover rendering

private func renderCover(from doc: PDFDocument) -> Data? {
    guard let page = doc.page(at: 0) else { return nil }
    let bounds = page.bounds(for: .mediaBox)
    let maxEdge: CGFloat = 1024
    let longest = max(bounds.width, bounds.height)
    let scale = longest > 0 ? min(maxEdge / longest, 2.0) : 1.0
    let width = Int(bounds.width * scale)
    let height = Int(bounds.height * scale)
    guard width > 0, height > 0 else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }

    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: bounds.size))
    page.draw(with: .mediaBox, to: ctx)

    guard let cgImage = ctx.makeImage() else { return nil }
    let mutable = NSMutableData()
    let type = "public.png" as CFString
    guard let dest = CGImageDestinationCreateWithData(mutable, type, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return mutable as Data
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
