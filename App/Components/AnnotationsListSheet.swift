import SwiftUI
import InkAndEchoCore

/// Reading-order sort shared by the sheet and the exporter — chapter order
/// first (unresolvable locators last), paragraph order within.
func annotationsInReadingOrder(_ annotations: [Annotation], segments: [TextSegment]) -> [Annotation] {
    let segmentOrder = Dictionary(
        segments.enumerated().map { ($0.element.id, $0.offset) },
        uniquingKeysWith: { first, _ in first }
    )
    return annotations.sorted { a, b in
        let aLoc = a.paragraphLocation
        let bLoc = b.paragraphLocation
        let aOrder = aLoc.flatMap { segmentOrder[$0.segmentID] } ?? Int.max
        let bOrder = bLoc.flatMap { segmentOrder[$0.segmentID] } ?? Int.max
        if aOrder != bOrder { return aOrder < bOrder }
        return (aLoc?.paragraphIndex ?? 0) < (bLoc?.paragraphIndex ?? 0)
    }
}

/// Modal sheet listing every annotation (highlight / bookmark / note) on
/// the current book, sorted in reading order. Tapping a row jumps the
/// reader to that paragraph via the `onJump` callback.
struct AnnotationsListSheet: View {
    let book: Book
    let segments: [TextSegment]
    let onJump: (Annotation) -> Void
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("Annotations")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !book.annotations.isEmpty {
                    exportMenu
                }
                Button("Done") {
                    onDismiss()
                    dismiss()
                }
            }
            .padding(20)

            Divider().background(Theme.hairline)

            if book.annotations.isEmpty {
                emptyAnnotationsState
            } else {
                List {
                    ForEach(sortedAnnotations) { annotation in
                        AnnotationRow(annotation: annotation, segments: segments)
                            .onTapGesture {
                                onJump(annotation)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Theme.canvas)
    }

    /// Empty-state body matching `Screens.html`: a small triplet of glyphs
    /// (bookmark / note bubble / highlight pill), serif headline, supporting
    /// prose. Centered in the sheet.
    private var emptyAnnotationsState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                Image(systemName: "bookmark")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.inkMuted)
                Image(systemName: "text.bubble")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.inkMuted)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.35))
                    .frame(width: 22, height: 12)
            }
            .padding(.bottom, 22)
            Text("Nothing marked yet.")
                .font(.system(.title3, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.ink)
            Text("Tap the ⋯ beside a paragraph to bookmark it, write a note, or highlight a passage. Everything you mark shows up here.")
                .font(.system(.callout, design: .serif))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 8)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    /// Both files are written when the menu opens — they're tiny, and
    /// ShareLink needs a concrete item up front.
    private var exportMenu: some View {
        Menu {
            let exporter = AnnotationExporter(book: book, segments: segments)
            if let url = try? exporter.markdownFileURL() {
                ShareLink(item: url) {
                    Label("Export Markdown", systemImage: "doc.text")
                }
            }
            if let url = try? exporter.jsonFileURL() {
                ShareLink(item: url) {
                    Label("Export JSON (with progress)", systemImage: "curlybraces")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private var sortedAnnotations: [Annotation] {
        annotationsInReadingOrder(book.annotations, segments: segments)
    }
}

/// Serializes a book's annotations for export — the user's escape hatch, so
/// a store reset or lost device never takes their notes with it. Markdown
/// for reading, JSON (with reading progress) for a recovery round-trip.
@MainActor
struct AnnotationExporter {
    let book: Book
    let segments: [TextSegment]

    /// Markdown export written to tmp, for ShareLink.
    func markdownFileURL() throws -> URL {
        try write(Data(markdown().utf8), ext: "md")
    }

    /// JSON export written to tmp, for ShareLink.
    func jsonFileURL() throws -> URL {
        try write(jsonData(), ext: "json")
    }

    // MARK: - Markdown

    func markdown() -> String {
        var out = "# \(book.title)\n\nby \(book.author)\n"
        var currentChapter: String?
        for annotation in annotationsInReadingOrder(book.annotations, segments: segments) {
            let chapter = chapterLabel(annotation)
            if chapter != currentChapter {
                out += "\n## \(chapter)\n\n"
                currentChapter = chapter
            }
            let kind = annotation.kind.rawValue.capitalized
            let place = annotation.paragraphLocation.map { "¶\($0.paragraphIndex + 1)" } ?? "?"
            switch annotation.kind {
            case .note:
                out += "- **\(kind)** (\(place)): \(annotation.note)\n"
                if let snippet = paragraphText(annotation) {
                    out += "  > \(snippet)\n"
                }
            case .highlight, .bookmark:
                out += "- **\(kind)** (\(place)): \(paragraphText(annotation) ?? "—")\n"
            }
        }
        return out
    }

    // MARK: - JSON

    private struct Payload: Encodable {
        struct Item: Encodable {
            let kind: String
            let locator: String
            let chapterIndex: Int?
            let paragraphIndex: Int?
            let color: String
            let note: String
            let snippet: String?
            let createdAt: Date
        }
        struct Progress: Encodable {
            let chapterID: String
            let pageIndex: Int
            let firstWordIndex: Int
            let audioSeconds: Double
            let lastReadAt: Date
        }
        let title: String
        let author: String
        let exportedAt: Date
        let annotations: [Item]
        let readingProgress: Progress?
    }

    func jsonData() -> Data {
        let items = annotationsInReadingOrder(book.annotations, segments: segments).map { annotation in
            Payload.Item(
                kind: annotation.kind.rawValue,
                locator: annotation.cfiStart,
                chapterIndex: chapterIndex(annotation),
                paragraphIndex: annotation.paragraphLocation?.paragraphIndex,
                color: annotation.color.rawValue,
                note: annotation.note,
                snippet: paragraphText(annotation),
                createdAt: annotation.createdAt
            )
        }
        let progress = book.progress.map {
            Payload.Progress(
                chapterID: $0.currentCFI,
                pageIndex: $0.currentPageIndex,
                firstWordIndex: $0.firstWordIndex,
                audioSeconds: $0.currentAudioSeconds,
                lastReadAt: $0.lastReadAt
            )
        }
        let payload = Payload(
            title: book.title,
            author: book.author,
            exportedAt: .now,
            annotations: items,
            readingProgress: progress
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encodable structs of plain values can't fail in practice; an empty
        // object beats throwing through the share UI.
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    // MARK: - Resolution

    private func chapterIndex(_ annotation: Annotation) -> Int? {
        guard let loc = annotation.paragraphLocation else { return nil }
        return segments.firstIndex(where: { $0.id == loc.segmentID })
    }

    private func chapterLabel(_ annotation: Annotation) -> String {
        guard let idx = chapterIndex(annotation) else { return "Unknown chapter" }
        if let title = segments[idx].title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return "Chapter \(idx + 1) · \(title)"
        }
        return "Chapter \(idx + 1)"
    }

    /// Same paragraph resolution the sheet rows use (importer maps `</p>`
    /// to `\n\n`).
    private func paragraphText(_ annotation: Annotation) -> String? {
        guard let loc = annotation.paragraphLocation,
              let segment = segments.first(where: { $0.id == loc.segmentID }) else { return nil }
        let paras = segment.text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard loc.paragraphIndex < paras.count else { return nil }
        return paras[loc.paragraphIndex]
    }

    private func write(_ data: Data, ext: String) throws -> URL {
        let safeTitle = book.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle) annotations.\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// One row in `AnnotationsListSheet` — kind icon, chapter / paragraph
/// label, and a 3-line preview of either the note text or the
/// highlighted/bookmarked paragraph.
struct AnnotationRow: View {
    let annotation: Annotation
    let segments: [TextSegment]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            kindIcon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(chapterLabel)
                    .font(.system(.caption, design: .default))
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(Theme.inkMuted)
                Text(snippet)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var kindIcon: some View {
        switch annotation.kind {
        case .highlight:
            Image(systemName: "highlighter")
                .foregroundStyle(Theme.accent)
        case .bookmark:
            Image(systemName: "bookmark.fill")
                .foregroundStyle(Theme.accent)
        case .note:
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(Theme.accent)
        }
    }

    private var chapterLabel: String {
        guard let loc = annotation.paragraphLocation,
              let idx = segments.firstIndex(where: { $0.id == loc.segmentID }) else {
            return "Unknown"
        }
        return "Chapter \(idx + 1) · ¶\(loc.paragraphIndex + 1)"
    }

    private var snippet: String {
        if annotation.kind == .note, !annotation.note.isEmpty {
            return annotation.note
        }
        guard let loc = annotation.paragraphLocation,
              let segment = segments.first(where: { $0.id == loc.segmentID }) else {
            return "—"
        }
        let paras = segment.text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard loc.paragraphIndex < paras.count else { return "—" }
        return paras[loc.paragraphIndex]
    }
}
