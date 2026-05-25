import SwiftUI
import InkAndEchoCore

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
            HStack {
                Text("Annotations")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(Theme.ink)
                Spacer()
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
            Text("Long-press a paragraph to bookmark it, write a note, or highlight a passage. Everything you mark shows up here.")
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

    private var sortedAnnotations: [Annotation] {
        let segmentOrder = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
        return book.annotations.sorted { a, b in
            let aLoc = a.paragraphLocation
            let bLoc = b.paragraphLocation
            let aOrder = aLoc.flatMap { segmentOrder[$0.segmentID] } ?? Int.max
            let bOrder = bLoc.flatMap { segmentOrder[$0.segmentID] } ?? Int.max
            if aOrder != bOrder { return aOrder < bOrder }
            return (aLoc?.paragraphIndex ?? 0) < (bLoc?.paragraphIndex ?? 0)
        }
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
