import Foundation
import ZIPFoundation

/// Parses an ebook file into a normalized form: metadata, cover, and text segments
/// suitable as input to the aligner.
public protocol EBookImporter: Sendable {
    func importBook(from url: URL) async throws -> ImportedBook
}

public struct ImportedBook: Sendable {
    public let title: String
    public let author: String
    public let coverImageData: Data?
    public let segments: [TextSegment]
    public let totalPages: Int

    public init(title: String, author: String, coverImageData: Data?, segments: [TextSegment], totalPages: Int) {
        self.title = title
        self.author = author
        self.coverImageData = coverImageData
        self.segments = segments
        self.totalPages = totalPages
    }
}

public struct EPUBImporter: EBookImporter {
    public init() {}

    public func importBook(from url: URL) async throws -> ImportedBook {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ImporterError.malformedEPUB("Cannot open archive: \(error.localizedDescription)")
        }

        let containerXML = try extractText(from: archive, path: "META-INF/container.xml")
        let opfPath = try parseContainer(containerXML)

        let opfXML = try extractText(from: archive, path: opfPath)
        let opf = try parseOPF(opfXML)

        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // Authoritative chapter list from the EPUB's TOC. EPUB 3 nav.xhtml
        // takes precedence; fall back to EPUB 2 NCX if nav is missing or empty.
        // Stored as an ordered list (not deduped by href) so a single spine
        // file referenced by N fragments yields N chapter splits below.
        var tocEntries: [TOCEntry] = []
        if let navHref = opf.navHref {
            let navPath = resolvePath(navHref, relativeTo: opfDir)
            if let xhtml = try? extractText(from: archive, path: navPath) {
                tocEntries = parseNavTOC(xhtml: xhtml)
            }
        }
        if tocEntries.isEmpty, let ncxHref = opf.ncxHref {
            let ncxPath = resolvePath(ncxHref, relativeTo: opfDir)
            if let xml = try? extractText(from: archive, path: ncxPath) {
                tocEntries = parseNCXTOC(xml: xml)
            }
        }

        var segments: [TextSegment] = []
        for itemref in opf.spine {
            guard let item = opf.manifest[itemref] else { continue }
            let path = resolvePath(item.href, relativeTo: opfDir)
            let xhtml = (try? extractText(from: archive, path: path)) ?? ""
            appendSpineSegments(
                into: &segments,
                itemref: itemref,
                itemHref: item.href,
                xhtml: xhtml,
                tocEntries: tocEntries
            )
        }

        let cover: Data? = {
            guard let coverID = opf.coverID,
                  let item = opf.manifest[coverID] else { return nil }
            let path = resolvePath(item.href, relativeTo: opfDir)
            return try? extractData(from: archive, path: path)
        }()

        return ImportedBook(
            title: opf.title,
            author: opf.author,
            coverImageData: cover,
            segments: segments,
            totalPages: 0
        )
    }
}

// MARK: - Archive helpers

private func extractText(from archive: Archive, path: String) throws -> String {
    let data = try extractData(from: archive, path: path)
    guard let text = String(data: data, encoding: .utf8) else {
        throw ImporterError.malformedEPUB("Non-UTF8 entry: \(path)")
    }
    return text
}

private func extractData(from archive: Archive, path: String) throws -> Data {
    guard let entry = archive[path] else {
        throw ImporterError.malformedEPUB("Missing entry: \(path)")
    }
    var data = Data()
    _ = try archive.extract(entry) { chunk in
        data.append(chunk)
    }
    return data
}

private func resolvePath(_ relative: String, relativeTo base: String) -> String {
    base.isEmpty ? relative : "\(base)/\(relative)"
}

// MARK: - container.xml

private func parseContainer(_ xml: String) throws -> String {
    guard let data = xml.data(using: .utf8) else {
        throw ImporterError.malformedEPUB("container.xml not UTF-8")
    }
    let parser = XMLParser(data: data)
    let delegate = ContainerDelegate()
    parser.delegate = delegate
    guard parser.parse(), let path = delegate.opfPath else {
        throw ImporterError.malformedEPUB(parser.parserError?.localizedDescription ?? "container.xml parse failed")
    }
    return path
}

private final class ContainerDelegate: NSObject, XMLParserDelegate {
    var opfPath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if localName(of: elementName) == "rootfile" && opfPath == nil {
            opfPath = attributeDict["full-path"]
        }
    }
}

// MARK: - OPF

private struct OPFData {
    let title: String
    let author: String
    let coverID: String?
    let manifest: [String: ManifestItem]
    let spine: [String]
    let navHref: String?
    let ncxHref: String?
}

private struct ManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: String
}

private func parseOPF(_ xml: String) throws -> OPFData {
    guard let data = xml.data(using: .utf8) else {
        throw ImporterError.malformedEPUB("OPF not UTF-8")
    }
    let parser = XMLParser(data: data)
    let delegate = OPFDelegate()
    parser.delegate = delegate
    guard parser.parse() else {
        throw ImporterError.malformedEPUB(parser.parserError?.localizedDescription ?? "OPF parse failed")
    }
    guard let result = delegate.result() else {
        throw ImporterError.missingMetadata("OPF missing required title or manifest")
    }
    return result
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    private var title: String?
    private var author: String?
    private var coverID: String?
    private var manifest: [String: ManifestItem] = [:]
    private var spine: [String] = []
    private var ncxId: String?
    private var currentElement: String?
    private var buffer: String = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String : String] = [:]) {
        currentElement = localName(of: elementName)
        buffer = ""
        switch currentElement {
        case "spine":
            ncxId = attrs["toc"]
        case "item":
            guard let id = attrs["id"], let href = attrs["href"] else { return }
            let properties = attrs["properties"] ?? ""
            manifest[id] = ManifestItem(
                id: id,
                href: href,
                mediaType: attrs["media-type"] ?? "",
                properties: properties
            )
            if properties.contains("cover-image") {
                coverID = id
            }
        case "itemref":
            if let idref = attrs["idref"] {
                spine.append(idref)
            }
        case "meta":
            if attrs["name"] == "cover", let content = attrs["content"], coverID == nil {
                coverID = content
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName(of: elementName) {
        case "title":
            if title == nil && !trimmed.isEmpty { title = trimmed }
        case "creator":
            if author == nil && !trimmed.isEmpty { author = trimmed }
        default:
            break
        }
        buffer = ""
    }

    func result() -> OPFData? {
        guard let title, !manifest.isEmpty else { return nil }
        let navHref = manifest.values.first(where: { $0.properties.contains("nav") })?.href
        let ncxHref = ncxId.flatMap { manifest[$0]?.href }

        // Filename heuristic — kicks in when neither EPUB 3
        // `properties="cover-image"` nor EPUB 2 `<meta name="cover">` is
        // present. Calibre-built EPUBs (and the Crime & Punishment file we
        // tested with) frequently declare the cover only via the legacy
        // `<guide><reference type="cover">` pointing at a title page,
        // leaving the actual image findable only by filename. Mirrors the
        // identical fallback in `xplatform/lib/import/ebook_importer.dart`.
        var resolvedCoverID = coverID
        if resolvedCoverID == nil {
            for (id, item) in manifest {
                let mt = item.mediaType.lowercased()
                let href = item.href.lowercased()
                if mt.hasPrefix("image/") && href.contains("cover") {
                    resolvedCoverID = id
                    break
                }
            }
        }

        return OPFData(
            title: title,
            author: author ?? "Unknown",
            coverID: resolvedCoverID,
            manifest: manifest,
            spine: spine,
            navHref: navHref,
            ncxHref: ncxHref
        )
    }
}

private func localName(of qualified: String) -> String {
    if let colon = qualified.firstIndex(of: ":") {
        return String(qualified[qualified.index(after: colon)...])
    }
    return qualified
}

// MARK: - TOC parsing

private struct TOCEntry {
    let href: String
    let fragment: String?
    let title: String
}

private func splitHref(_ raw: String) -> (href: String, fragment: String?) {
    guard let hashIdx = raw.firstIndex(of: "#") else { return (raw, nil) }
    let href = String(raw[..<hashIdx])
    let after = raw.index(after: hashIdx)
    let fragment = after < raw.endIndex ? String(raw[after...]) : nil
    return (href, fragment)
}

/// EPUB 3 `<nav epub:type="toc">` — every anchor becomes a TOC entry in
/// document order. Fragments preserved so callers can split a spine file
/// at anchor offsets.
private func parseNavTOC(xhtml: String) -> [TOCEntry] {
    guard let data = xhtml.data(using: .utf8) else { return [] }
    let parser = XMLParser(data: data)
    let delegate = NavTOCDelegate()
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.entries
}

private final class NavTOCDelegate: NSObject, XMLParserDelegate {
    /// Final output: prefers explicit toc-tagged nav, falls back to the
    /// first top-level nav when nothing is tagged. Matches Dart's
    /// `tocNav ?? firstNav` pick.
    var entries: [TOCEntry] { tocEntries.isEmpty ? firstNavEntries : tocEntries }

    private var tocEntries: [TOCEntry] = []
    private var firstNavEntries: [TOCEntry] = []
    private var inToc = false
    private var inFirstNav = false
    private var sawFirstNav = false
    private var navDepth = 0
    private var currentHref: String?
    private var currentText: String = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String : String] = [:]) {
        let local = localName(of: elementName)
        if local == "nav" {
            navDepth += 1
            if navDepth == 1 {
                let type = attrs["epub:type"] ?? attrs["type"] ?? attrs["role"] ?? ""
                if type.contains("toc") {
                    inToc = true
                } else if !sawFirstNav {
                    inFirstNav = true
                }
                sawFirstNav = true
            }
        } else if (inToc || inFirstNav) && local == "a" {
            currentHref = attrs["href"]
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if (inToc || inFirstNav) && currentHref != nil {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(of: elementName)
        if local == "a", inToc || inFirstNav, let href = currentHref {
            let title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let parts = splitHref(href)
                let entry = TOCEntry(href: parts.href, fragment: parts.fragment, title: title)
                if inToc { tocEntries.append(entry) }
                else { firstNavEntries.append(entry) }
            }
            currentHref = nil
            currentText = ""
        } else if local == "nav" {
            navDepth -= 1
            if navDepth == 0 {
                inToc = false
                inFirstNav = false
            }
        }
    }
}

/// EPUB 2 NCX — `navPoint`s in document order with fragments preserved.
private func parseNCXTOC(xml: String) -> [TOCEntry] {
    guard let data = xml.data(using: .utf8) else { return [] }
    let parser = XMLParser(data: data)
    let delegate = NCXTOCDelegate()
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.entries
}

private final class NCXTOCDelegate: NSObject, XMLParserDelegate {
    var entries: [TOCEntry] = []

    private struct NavPointCtx {
        var src: String?
        var title: String = ""
    }

    private var stack: [NavPointCtx] = []
    private var insideNavLabel = false
    private var insideLabelText = false
    private var labelBuffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String : String] = [:]) {
        switch localName(of: elementName) {
        case "navPoint":
            stack.append(NavPointCtx())
        case "content":
            if !stack.isEmpty {
                stack[stack.count - 1].src = attrs["src"]
            }
        case "navLabel":
            insideNavLabel = true
        case "text":
            if insideNavLabel {
                insideLabelText = true
                labelBuffer = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideLabelText {
            labelBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(of: elementName) {
        case "text":
            if insideLabelText, !stack.isEmpty {
                stack[stack.count - 1].title = labelBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                insideLabelText = false
            }
        case "navLabel":
            insideNavLabel = false
        case "navPoint":
            guard let ctx = stack.popLast(), let src = ctx.src, !ctx.title.isEmpty else { return }
            let parts = splitHref(src)
            entries.append(TOCEntry(href: parts.href, fragment: parts.fragment, title: ctx.title))
        default:
            break
        }
    }
}

// MARK: - Spine splitting

/// Pre-first-anchor content shorter than this is usually running-header
/// re-runs, not real preamble. Matches the Dart importer threshold.
private let preambleMinChars = 150

private let navLabelRegex = try? NSRegularExpression(
    pattern: #"^\s*(prev(ious)?|next|up|back|home|top|continue|menu|index|table\s+of\s+contents)\s*$"#,
    options: .caseInsensitive
)

private let chapterishPrefixes = [
    "chapter", "part", "book", "volume", "prologue", "epilogue",
    "preface", "foreword", "introduction", "afterword", "dedication",
]

private func looksLikeNavLabel(_ title: String) -> Bool {
    guard let re = navLabelRegex else { return false }
    let range = NSRange(title.startIndex..<title.endIndex, in: title)
    return re.firstMatch(in: title, range: range) != nil
}

private func looksLikeChapterTitle(_ title: String) -> Bool {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.isEmpty { return false }
    if t.contains("appendix") { return true }
    return chapterishPrefixes.contains { t.hasPrefix($0) }
}

/// Locate the character offset of the tag whose `id` matches `fragment`. The
/// offset points at the opening `<` of that tag so the resulting split
/// captures the heading itself, not just its tail.
private func findAnchorOffset(in xhtml: String, fragment: String) -> Int? {
    let escaped = NSRegularExpression.escapedPattern(for: fragment)
    let pattern = #"\bid=["']"# + escaped + #"["']"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsXhtml = xhtml as NSString
    let range = NSRange(location: 0, length: nsXhtml.length)
    guard let match = re.firstMatch(in: xhtml, range: range) else { return nil }
    let matchStart = match.range.location
    let searchRange = NSRange(location: 0, length: matchStart)
    let tagStart = nsXhtml.range(of: "<", options: .backwards, range: searchRange)
    return tagStart.location == NSNotFound ? 0 : tagStart.location
}

private struct Split {
    let entry: TOCEntry
    let offset: Int
}

private func collectSplits(itemHref: String, xhtml: String, tocEntries: [TOCEntry]) -> [Split] {
    let hrefKey = splitHref(itemHref).href
    var seen: Set<Int> = []
    var splits: [Split] = []
    for entry in tocEntries {
        let hrefMatches = entry.href == hrefKey
        let offset: Int?
        if let frag = entry.fragment {
            offset = findAnchorOffset(in: xhtml, fragment: frag)
        } else {
            offset = hrefMatches ? 0 : nil
        }
        guard let off = offset else { continue }
        // Skip nav-chrome anchors (Prev / Next / Up etc.) on files where
        // the TOC doesn't otherwise reference this spine item directly.
        if !hrefMatches, !looksLikeChapterTitle(entry.title), looksLikeNavLabel(entry.title) {
            continue
        }
        if !seen.insert(off).inserted { continue }
        splits.append(Split(entry: entry, offset: off))
    }
    splits.sort { $0.offset < $1.offset }
    return splits
}

private func appendSpineSegments(
    into segments: inout [TextSegment],
    itemref: String,
    itemHref: String,
    xhtml: String,
    tocEntries: [TOCEntry]
) {
    let splits = collectSplits(itemHref: itemHref, xhtml: xhtml, tocEntries: tocEntries)
    if splits.isEmpty {
        let plain = stripHTML(xhtml)
        guard !plain.isEmpty else { return }
        let hrefKey = splitHref(itemHref).href
        let title = tocEntries.first(where: { $0.href == hrefKey && $0.fragment == nil })?.title
            ?? extractChapterTitle(from: xhtml)
        segments.append(TextSegment(id: itemref, title: title, text: plain))
        return
    }

    appendPreamble(into: &segments, itemref: itemref, xhtml: xhtml, firstSplitOffset: splits[0].offset)

    let nsXhtml = xhtml as NSString
    for i in 0..<splits.count {
        let start = splits[i].offset
        let end = i + 1 < splits.count ? splits[i + 1].offset : nsXhtml.length
        let slice = nsXhtml.substring(with: NSRange(location: start, length: end - start))
        let plain = stripHTML(slice)
        guard !plain.isEmpty else { continue }
        let fragKey = splits[i].entry.fragment ?? "\(i)"
        segments.append(TextSegment(
            id: "\(itemref)_\(fragKey)",
            title: splits[i].entry.title,
            text: plain
        ))
    }
}

private func appendPreamble(
    into segments: inout [TextSegment],
    itemref: String,
    xhtml: String,
    firstSplitOffset: Int
) {
    guard firstSplitOffset > 0 else { return }
    let nsXhtml = xhtml as NSString
    let preambleXhtml = nsXhtml.substring(with: NSRange(location: 0, length: firstSplitOffset))
    let preamble = stripHTML(preambleXhtml)
    guard preamble.count >= preambleMinChars else { return }
    segments.append(TextSegment(
        id: "\(itemref)_preamble",
        title: extractChapterTitle(from: preambleXhtml),
        text: preamble
    ))
}

// MARK: - Chapter title extraction

/// Extracts a human-readable chapter title from an xhtml document. Tries
/// `<h1>`/`<h2>`/`<h3>` (in that order) since they're the canonical chapter
/// heading tags, then falls back to the document's `<title>`. Strips any nested
/// HTML and decodes the most common entities.
private func extractChapterTitle(from xhtml: String) -> String? {
    let patterns = [
        "<h1\\b[^>]*>([\\s\\S]*?)</h1>",
        "<h2\\b[^>]*>([\\s\\S]*?)</h2>",
        "<h3\\b[^>]*>([\\s\\S]*?)</h3>",
        "<title\\b[^>]*>([\\s\\S]*?)</title>",
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
        let nsRange = NSRange(xhtml.startIndex..<xhtml.endIndex, in: xhtml)
        guard let match = regex.firstMatch(in: xhtml, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: xhtml) else { continue }

        let cleaned = stripHTML(String(xhtml[range]))
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return nil
}

// MARK: - HTML stripping

func stripHTML(_ html: String) -> String {
    var text = html

    // Drop script/style blocks entirely.
    text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)

    // Convert common block-end tags to paragraph breaks before stripping.
    let blockEnds = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</li>", "</blockquote>", "</section>"]
    for tag in blockEnds {
        text = text.replacingOccurrences(of: tag, with: "\n\n", options: .caseInsensitive)
    }
    let lineBreaks = ["<br/>", "<br />", "<br>"]
    for tag in lineBreaks {
        text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
    }

    // Strip all remaining tags.
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

    // Decode the most common HTML entities.
    let entities: [(String, String)] = [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&nbsp;", " "),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&hellip;", "…"),
        ("&ldquo;", "\u{201C}"),
        ("&rdquo;", "\u{201D}"),
        ("&lsquo;", "\u{2018}"),
        ("&rsquo;", "\u{2019}"),
    ]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }
    // Numeric entities like &#x...; or &#N;
    text = text.replacingOccurrences(
        of: "&#(\\d+);",
        with: "",
        options: .regularExpression
    )

    // Collapse runs of whitespace inside lines but preserve paragraph breaks.
    text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum ImporterError: LocalizedError, Sendable {
    case malformedEPUB(String)
    case malformedMOBI(String)
    case malformedPDF(String)
    case unsupportedFormat
    case unsupportedKF8
    case drmProtected
    case missingMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .malformedEPUB(let detail):
            return "Couldn't read this EPUB. \(detail)"
        case .malformedMOBI(let detail):
            return "Couldn't read this MOBI. \(detail)"
        case .malformedPDF(let detail):
            return "Couldn't read this PDF. \(detail)"
        case .unsupportedFormat:
            return "This file isn't a supported ebook format."
        case .unsupportedKF8:
            return "AZW3 / KF8 files aren't supported. Convert to EPUB first."
        case .drmProtected:
            return "This file is DRM-protected and can't be imported."
        case .missingMetadata(let detail):
            return "EPUB metadata is missing or unreadable. \(detail)"
        }
    }
}
