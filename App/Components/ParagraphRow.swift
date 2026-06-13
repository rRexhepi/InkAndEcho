import SwiftUI
import InkAndEchoCore
#if os(iOS)
import UIKit
#endif

/// Active-word highlighting mode for `ParagraphRow`. `.word` tints the word
/// currently being narrated, at any playback rate; `.none` disables
/// read-along highlighting (and skips the tracker read entirely, so rows
/// don't invalidate on word changes).
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
    /// Where this row's text begins within its original paragraph (non-zero
    /// for chunks of a split paragraph). Word-highlight locators are stored
    /// paragraph-relative; displayed indices are chunk-relative — this is
    /// the bridge between the two.
    let chunkWordOffset: Int
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
    let onPaintEnded: () -> Void

    private var activeLocalWordIndex: Int? {
        guard let aw = activeWordTracker.current, aw.segmentId == segmentID else { return nil }
        let local = aw.wordIndex - wordOffset
        let count = tokenizeWords(text).count
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
        let (attrString, ranges, backgrounds) = buildAttributedString()
        return HighlightableTextView(
            attributedString: attrString,
            wordRanges: ranges,
            wordBackgrounds: backgrounds,
            paintPreviewColor: UIColor(colorView(for: AppSettings.defaultHighlightColor())).withAlphaComponent(0.30),
            onToggleWord: onToggleWord,
            onPaintWord: onPaintWord,
            onPaintEnded: onPaintEnded
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, highlight != nil ? 8 : 0)
        .padding(.vertical, highlight != nil ? 4 : 0)
        .background(highlightBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // No `.contextMenu` on the text itself: its long-press recognizer
        // preempted UITextView's selection gesture (verified in the
        // simulator — the paragraph lifted into a preview and the loupe /
        // Copy / Look Up / edit-menu Highlight could never fire). Text
        // long-press belongs to selection; every menu action remains on the
        // row's ⋯ button, which shows the identical `contextMenuContent`.
    }

    private func buildAttributedString() -> (AttributedString, [(localIndex: Int, range: NSRange)], [(range: NSRange, color: UIColor)]) {
        // Active read-along word for this paragraph, computed once.
        let activeIdx: Int? = highlightMode == .word ? activeLocalWordIndex : nil
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

        let nsRanges: [(localIndex: Int, range: NSRange)] = attrRanges.map { entry in
            (entry.local, NSRange(entry.range, in: result))
        }
        // Per-word backgrounds carried as real UIColor and applied in the text
        // view via NSAttributedString.Key.backgroundColor. A SwiftUI `Color`
        // background set on an AttributedString does NOT survive
        // `NSAttributedString(_:)`, so paint + read-along both go out-of-band.
        // Read-along (active word) wins over a manual paint color.
        let backgrounds: [(range: NSRange, color: UIColor)] = nsRanges.compactMap { entry in
            if entry.localIndex == activeIdx {
                return (entry.range, UIColor(Theme.highlightWordSoft))
            }
            if let wc = wordHighlights[entry.localIndex] {
                return (entry.range, UIColor(colorView(for: wc)).withAlphaComponent(0.30))
            }
            return nil
        }
        return (result, nsRanges, backgrounds)
    }

    private func appendWord(_ word: String, localIndex: Int, into result: inout AttributedString, ranges: inout [(local: Int, range: Range<AttributedString.Index>)]) {
        var attr = AttributedString(word)
        attr.foregroundColor = Theme.ink
        let start = result.endIndex
        result.append(attr)
        let end = result.endIndex
        ranges.append((localIndex, start..<end))
    }

    /// Displayed-word index → highlight color for every word-level highlight
    /// on this row. Locators store PARAGRAPH-relative indices; this row may
    /// render a chunk, so subtract `chunkWordOffset` — highlights belonging
    /// to other chunks fall out of range and simply don't map. Built once
    /// per body evaluation (cheap; bookmarks and notes are filtered out, so
    /// the dictionary is small in practice).
    private var wordHighlights: [Int: AnnotationColor] {
        var map: [Int: AnnotationColor] = [:]
        for a in annotations where a.kind == .highlight {
            if let loc = a.wordLocation,
               loc.paragraphIndex == paragraphIndex {
                map[loc.wordIndex - chunkWordOffset] = a.color
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
