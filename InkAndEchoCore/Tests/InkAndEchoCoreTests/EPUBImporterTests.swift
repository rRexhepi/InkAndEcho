import Foundation
import Testing
import ZIPFoundation
@testable import InkAndEchoCore

/// Golden assertions against the in-repo Crime and Punishment fixture —
/// value-identical to `xplatform/test/ebook_importer_test.dart` so a drift
/// in either importer breaks the shared-alignment.json invariant loudly.
@Suite("EPUBImporter golden — Crime and Punishment fixture")
struct EPUBImporterTests {
    /// Parsed once, shared by every test in the suite.
    static let bookTask = Task { () throws -> ImportedBook in
        let url = Bundle.module.url(forResource: "sample", withExtension: "epub", subdirectory: "Resources")!
        return try await EPUBImporter().importBook(from: url)
    }
    var book: ImportedBook { get async throws { try await Self.bookTask.value } }

    @Test func metadataAndCover() async throws {
        let book = try await book
        #expect(book.title == "Crime and Punishment")
        #expect(book.author == "Fyodor Dostoyevsky")
        #expect(book.coverImageData?.count == 69425)
        #expect(book.warnings.isEmpty)
    }

    @Test func segmentIDsAreStableAndUnique() async throws {
        let ids = try await book.segments.map(\.id)
        #expect(ids.count == 51)
        #expect(Set(ids).count == ids.count)
        #expect(ids[0] == "id2.1")
        #expect(ids[2] == "id2.3__Toc230227608")
        #expect(ids[5] == "id2.6__Toc230227611")
        #expect(ids[49] == "id2.50__Toc230227657")
        #expect(ids[50] == "id2.51__Toc230227658")
    }

    @Test func tocTitlesAttach() async throws {
        let titles = try await book.segments.map { $0.title ?? "" }
        #expect(titles[2] == "TRANSLATOR'S PREFACE")
        #expect(titles[3] == "CRIME AND PUNISHMENT")
        #expect(titles[4] == "PART I")
        #expect(titles[5] == "CHAPTER I")
        #expect(titles[49] == "EPILOGUE")
        #expect(titles[50] == "II")
    }

    @Test func firstWordsMatchGolden() async throws {
        let book = try await book
        #expect(firstWords(book, 0) == "CRIME AND PUNISHMENT By Fyodor Dostoevsky")
        // The head-strip golden: this file's <head><title> is "Unknown" —
        // it must NOT prepend itself to the body text.
        #expect(firstWords(book, 1) == "TABLE OF CONTENTS TRANSLATOR'S PREFACE CRIME")
        #expect(firstWords(book, 2) == "TRANSLATOR'S PREFACE A few words about")
        #expect(firstWords(book, 5) == "CHAPTER I On an exceptionally hot")
        #expect(firstWords(book, 9) == "CHAPTER V \"Of course, I've been")
        #expect(firstWords(book, 50) == "II He was ill a long")
    }

    @Test func preambleBehavior() async throws {
        // Anchor offsets point at the heading's opening tag, so pre-anchor
        // chrome strips to under the preamble threshold — no _preamble
        // segments for this fixture, and no empty texts anywhere.
        let book = try await book
        #expect(!book.segments.contains { $0.id.hasSuffix("_preamble") })
        #expect(!book.segments.contains { $0.text.isEmpty })
    }

    @Test func totalTextLengthMatchesGolden() async throws {
        // UTF-16 units (== Dart String.length), so both platforms assert
        // the same number over byte-identical segment text.
        let total = try await book.segments.reduce(0) { $0 + $1.text.utf16.count }
        #expect(total == 1154386)
    }

    private func firstWords(_ book: ImportedBook, _ index: Int) -> String {
        book.segments[index].text
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(6)
            .joined(separator: " ")
    }
}

@Suite("EPUBImporter compatibility")
struct EPUBImporterCompatibilityTests {
    @Test func normalizeHrefDecodesAndCollapses() {
        #expect(normalizeHref("Text/chapter%201.xhtml") == "Text/chapter 1.xhtml")
        #expect(normalizeHref("Text/../Images/cover.jpg") == "Images/cover.jpg")
        #expect(normalizeHref("./Text/ch1.xhtml") == "Text/ch1.xhtml")
        // Raw spaces survive decoding unchanged (the fixture's shape).
        #expect(normalizeHref("content/CRIME AND PUNISHMENT_split_1.html") == "content/CRIME AND PUNISHMENT_split_1.html")
        // A literal % that isn't a valid escape keeps the raw spelling.
        #expect(normalizeHref("100% proof.xhtml") == "100% proof.xhtml")
        // Leading ../ can't collapse further; the join with opfDir does it.
        #expect(normalizeHref("../Text/ch1.xhtml") == "../Text/ch1.xhtml")
    }

    @Test func percentEncodedHrefsResolveAgainstRawEntryNames() async throws {
        // Both directions: encoded href → raw entry name (parse-time
        // decode), and encoded entry name → any href spelling (the
        // normalized rescan fallback).
        let epub = try makeEPUB(spineFiles: [
            "chapter one.xhtml": "<html><body><p>It was the best of times.</p></body></html>",
            "chapter%20two.xhtml": "<html><body><p>It was the worst of times.</p></body></html>",
        ], hrefs: ["chapter%20one.xhtml", "chapter%20two.xhtml"])
        let book = try await EPUBImporter().importBook(from: epub)
        #expect(book.segments.map(\.text) == ["It was the best of times.", "It was the worst of times."])
        #expect(book.warnings.isEmpty)
    }

    @Test func unreadableSpineEntryWarnsButImports() async throws {
        let epub = try makeEPUB(spineFiles: [
            "ch1.xhtml": "<html><body><p>Real text.</p></body></html>",
        ], hrefs: ["ch1.xhtml", "missing.xhtml"])
        let book = try await EPUBImporter().importBook(from: epub)
        #expect(book.segments.count == 1)
        #expect(book.warnings == ["Unreadable spine entry: OEBPS/missing.xhtml"])
    }

    @Test func throwsMalformedEPUBListingFailedPaths() async throws {
        let epub = try makeEPUB(spineFiles: [:], hrefs: ["gone.xhtml"])
        await #expect(throws: ImporterError.self) {
            _ = try await EPUBImporter().importBook(from: epub)
        }
        do {
            _ = try await EPUBImporter().importBook(from: epub)
        } catch let error as ImporterError {
            #expect(error.errorDescription?.contains("OEBPS/gone.xhtml") == true)
        }
    }

    /// Minimal one-spine-per-href EPUB written to a temp file. `spineFiles`
    /// maps raw zip entry names (relative to OEBPS/) to xhtml; `hrefs` are
    /// the manifest/spine spellings, possibly percent-encoded or dangling.
    private func makeEPUB(spineFiles: [String: String], hrefs: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ text: String) throws {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        try add("META-INF/container.xml", """
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        let items = hrefs.enumerated()
            .map { #"<item id="s\#($0.offset)" href="\#($0.element)" media-type="application/xhtml+xml"/>"# }
            .joined()
        let itemrefs = hrefs.indices.map { #"<itemref idref="s\#($0)"/>"# }.joined()
        try add("OEBPS/content.opf", """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test</dc:title><dc:creator>Tester</dc:creator></metadata>
        <manifest>\(items)</manifest><spine>\(itemrefs)</spine></package>
        """)
        for (name, xhtml) in spineFiles {
            try add("OEBPS/\(name)", xhtml)
        }
        return url
    }
}
