import SwiftUI
import InkAndEchoCore
#if os(iOS)
import UIKit
#endif

/// Active-word highlighting mode for `ParagraphRow`. Set to `.none` to
/// disable; word/sentence variants tint the audible word or its sentence
/// while the audiobook plays at 1× rate.
enum HighlightMode {
    case word
    case none
}

/// One paragraph as it appears on the reader page.
///
/// Layout: a 16pt margin column on the left (bookmark / note indicators),
/// the selectable serif text in the middle, and a 22pt actions column on
/// the right (`⋯` menu — highlight, bookmark, add note, play-from-here).
/// The paragraph itself uses 17pt system serif at `lineSpacing(8)`, and
/// gets a tinted background pill when a highlight annotation is attached.
struct ParagraphRow: View {
    let text: String
    let paragraphIndex: Int
    let wordOffset: Int
    let seekEnabled: Bool
    let segmentID: String
    /// `@Observable` so the read of `activeWordTracker.current` happens
    /// inside `ParagraphRow.body` — `ReaderView.body` no longer becomes a
    /// dependent of the per-tick active-word change.
    let activeWordTracker: ActiveWordTracker
    let highlightMode: HighlightMode
    let annotations: [Annotation]
    let onPlayFromWord: (Int) -> Void
    let onHighlight: (AnnotationColor) -> Void
    let onBookmark: () -> Void
    let onAddNote: () -> Void
    let onTapNote: (Annotation) -> Void
    let onDelete: (Annotation) -> Void
    let onToggleWord: (Int) -> Void
    let onPaintWord: (Int) -> Void

    private var activeLocalWordIndex: Int? {
        guard let aw = activeWordTracker.current, aw.segmentId == segmentID else { return nil }
        let local = aw.wordIndex - wordOffset
        let count = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        return (local >= 0 && local < count) ? local : nil
    }

    /// Paragraph-level highlight only. Word-level highlights (locator has a
    /// `w<index>` suffix) tint just the word via `wordHighlights`; matching
    /// them here would also light up the wide paragraph pill.
    private var highlight: Annotation? {
        annotations.first(where: { $0.kind == .highlight && $0.wordLocation == nil })
    }
    private var bookmark: Annotation? { annotations.first(where: { $0.kind == .bookmark }) }
    private var notes: [Annotation] { annotations.filter { $0.kind == .note } }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            margin
            paragraphText
            actionsButton
        }
    }

    private var actionsButton: some View {
        Menu {
            contextMenuContent
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22)
    }

    private var margin: some View {
        VStack(spacing: 4) {
            if bookmark != nil {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
            ForEach(notes) { note in
                Button {
                    onTapNote(note)
                } label: {
                    Image(systemName: "text.bubble.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 16, alignment: .center)
        .padding(.top, 4)
    }

    private var paragraphText: some View {
        let (attrString, ranges) = buildAttributedString()
        return HighlightableTextView(
            attributedString: attrString,
            wordRanges: ranges,
            onToggleWord: onToggleWord,
            onPaintWord: onPaintWord
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, highlight != nil ? 8 : 0)
        .padding(.vertical, highlight != nil ? 4 : 0)
        .background(highlightBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contextMenu { contextMenuContent }
    }

    private func buildAttributedString() -> (AttributedString, [(localIndex: Int, range: NSRange)]) {
        var result = AttributedString()
        var inWord = false
        var wordStart = text.startIndex
        var localWordIdx = 0
        var attrRanges: [(local: Int, range: Range<AttributedString.Index>)] = []

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace || ch.isNewline {
                if inWord {
                    let wordSlice = String(text[wordStart..<i])
                    appendWord(wordSlice, localIndex: localWordIdx, into: &result, ranges: &attrRanges)
                    localWordIdx += 1
                    inWord = false
                }
                result.append(AttributedString(String(ch)))
            } else {
                if !inWord {
                    wordStart = i
                    inWord = true
                }
            }
            i = text.index(after: i)
        }
        if inWord {
            let wordSlice = String(text[wordStart..<text.endIndex])
            appendWord(wordSlice, localIndex: localWordIdx, into: &result, ranges: &attrRanges)
        }

        if let active = activeLocalWordIndex {
            switch highlightMode {
            case .word:
                if let entry = attrRanges.first(where: { $0.local == active }) {
                    result[entry.range].backgroundColor = Theme.highlightWordSoft
                }
            case .none:
                break
            }
        }

        let nsRanges: [(localIndex: Int, range: NSRange)] = attrRanges.map { entry in
            (entry.local, NSRange(entry.range, in: result))
        }
        return (result, nsRanges)
    }

    private func appendWord(_ word: String, localIndex: Int, into result: inout AttributedString, ranges: inout [(local: Int, range: Range<AttributedString.Index>)]) {
        var attr = AttributedString(word)
        attr.foregroundColor = Theme.ink
        // Per-word background. The wider paragraph-level pill is drawn
        // separately in `highlightBackground` so both can coexist.
        if let wordColor = wordHighlights[localIndex] {
            attr.backgroundColor = colorView(for: wordColor).opacity(0.30)
        }
        let start = result.endIndex
        result.append(attr)
        let end = result.endIndex
        ranges.append((localIndex, start..<end))
    }

    /// Word index → highlight color for every word-level highlight on this
    /// paragraph. Built once per body evaluation (cheap; bookmarks and
    /// notes are filtered out, so the dictionary is small in practice).
    private var wordHighlights: [Int: AnnotationColor] {
        var map: [Int: AnnotationColor] = [:]
        for a in annotations where a.kind == .highlight {
            if let loc = a.wordLocation,
               loc.paragraphIndex == paragraphIndex {
                map[loc.wordIndex] = a.color
            }
        }
        return map
    }

    @ViewBuilder
    private var highlightBackground: some View {
        if let highlight {
            colorView(for: highlight.color).opacity(0.22)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        // Always-visible entry point. Disabled when no AlignmentMap exists
        // yet so users discover the feature even before running alignment;
        // the button label switches to an instruction in that case.
        Button {
            onPlayFromWord(0)
        } label: {
            Label(
                seekEnabled ? "Play audiobook from here" : "Play from here (align audio first)",
                systemImage: "play.fill"
            )
        }
        .disabled(!seekEnabled)
        Divider()
        if highlight == nil {
            Menu("Highlight") {
                ForEach(AnnotationColor.allCases, id: \.self) { color in
                    colorPickerButton(for: color)
                }
            }
        } else {
            Button("Remove Highlight") {
                if let h = highlight { onDelete(h) }
            }
            Menu("Change Color") {
                ForEach(AnnotationColor.allCases, id: \.self) { color in
                    colorPickerButton(for: color)
                }
            }
        }

        Divider()

        Button(bookmark == nil ? "Add Bookmark" : "Remove Bookmark") {
            onBookmark()
        }
        Button("Add Note…") {
            onAddNote()
        }

        if !notes.isEmpty {
            Divider()
            ForEach(notes) { note in
                Menu(notePreview(note)) {
                    Button("View") { onTapNote(note) }
                    Button(role: .destructive) {
                        onDelete(note)
                    } label: {
                        Text("Delete")
                    }
                }
            }
        }
    }

    private func colorView(for color: AnnotationColor) -> Color { color.swatch }

    @ViewBuilder
    private func colorPickerButton(for color: AnnotationColor) -> some View {
        Button {
            onHighlight(color)
        } label: {
            // iOS Menu items strip `foregroundStyle` from a Label's
            // systemImage, leaving the circle the menu's default tint
            // (black/ink). Pre-tinting a UIImage with .alwaysOriginal
            // preserves the color when UIKit renders the UIMenuElement.
            #if os(iOS)
            Label {
                Text(color.rawValue.capitalized)
            } icon: {
                Image(uiImage: tintedCircle(for: color))
            }
            #else
            Label(color.rawValue.capitalized, systemImage: "circle.fill")
                .foregroundStyle(colorView(for: color))
            #endif
        }
    }

    #if os(iOS)
    private func tintedCircle(for color: AnnotationColor) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let base = UIImage(systemName: "circle.fill", withConfiguration: config) ?? UIImage()
        return base.withTintColor(UIColor(colorView(for: color)), renderingMode: .alwaysOriginal)
    }
    #endif

    private func notePreview(_ note: Annotation) -> String {
        let snippet = note.note.prefix(40)
        return "Note: \(snippet)\(note.note.count > 40 ? "…" : "")"
    }
}
