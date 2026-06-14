import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Portable page-break logic
//
// The reader splits a chapter into fixed-size pages. Counting words to guess
// where a page is "full" is wrong by design: a page of dialogue wraps to far
// more lines than a page of dense prose at the same word count, so any
// word budget either clips (too high) or wastes space (too low).
//
// Instead we measure the real rendered height of each paragraph at the page
// width and pack paragraphs until the next line wouldn't fit, then break.
// A paragraph taller than the remaining space is split at the exact
// word boundary that fills the page — which, with no hyphenation, is the same
// line a TextKit/Core Text framesetter would break at. This is the
// `measure-and-pack` strategy used by readers that render block-by-block
// rather than as one text run.
//
// `paginateByMeasuredHeight` is deliberately pure: it takes a `measure`
// closure and knows nothing about UIKit. The Swift app injects a TextKit
// measurer (`BodyTextMetrics.measuredHeight`); the Flutter `xplatform/` port
// can inject a `TextPainter`-based one and reuse this exact algorithm. Keep it
// dependency-free so the two stay in sync.

/// Per-page layout budget handed to the paginator. All values are in points.
struct MeasuredPageGeometry {
    /// Text column width for a paragraph that is the FIRST on its page (no
    /// leading indent).
    let firstRowWidth: CGFloat
    /// Text column width for any later paragraph on the page (indented).
    let bodyRowWidth: CGFloat
    /// Vertical space available for the paragraph block (page height minus
    /// header, page number, paddings and a one-line safety margin).
    let availableHeight: CGFloat
    /// Gap between stacked paragraphs.
    let paragraphSpacing: CGFloat
}

/// Greedy height-packer. Fills each page to the last line that fits, splitting
/// a straddling paragraph at the word boundary that fills the page. Avoids
/// orphans (a lone first line stranded at a page bottom) by pushing a
/// paragraph that would get fewer than ~2 lines down to a fresh page, unless
/// the paragraph is itself taller than a whole page (then it must split).
///
/// - Parameters:
///   - paragraphs: the chapter's paragraphs, in order.
///   - g: the measured page budget.
///   - lineUnit: height of one body line (font line height + line spacing);
///     the orphan threshold and progress floor are expressed in these.
///   - measure: rendered height of `text` wrapped to `width`. MUST match how
///     the paragraph is actually drawn, or breaks drift.
func paginateByMeasuredHeight(
    paragraphs: [String],
    geometry g: MeasuredPageGeometry,
    lineUnit: CGFloat,
    measure: (_ text: String, _ width: CGFloat) -> CGFloat
) -> [PageContent] {
    var pages: [PageContent] = []
    var current: [PagedParagraph] = []
    var used: CGFloat = 0
    var chunkID = 0
    // A head chunk must be at least this tall to split a paragraph here;
    // otherwise the paragraph is pushed to the next page to avoid a sliver.
    let minHeadHeight = 1.5 * lineUnit

    func flush() {
        guard !current.isEmpty else { return }
        pages.append(PageContent(index: pages.count, paragraphs: current))
        current = []
        used = 0
    }

    func place(_ originalIndex: Int, _ text: String, wordOffset: Int, height: CGFloat, spacing: CGFloat) {
        current.append(PagedParagraph(
            originalIndex: originalIndex,
            text: text,
            wordOffsetWithinParagraph: wordOffset,
            chunkID: chunkID
        ))
        chunkID += 1
        used += spacing + height
    }

    /// Largest prefix word count of `words[start...]` whose rendered height at
    /// `width` is ≤ `maxHeight`. Binary search over the word count.
    func maxPrefixWords(_ words: [String], start: Int, width: CGFloat, maxHeight: CGFloat) -> Int {
        let n = words.count - start
        guard n > 0, maxHeight > 0 else { return 0 }
        var lo = 1, hi = n, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let text = words[start..<start + mid].joined(separator: " ")
            if measure(text, width) <= maxHeight {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    for (originalIndex, paragraph) in paragraphs.enumerated() {
        // Word splitting mirrors the historical chunker (`split(separator: " ")`)
        // so `wordOffsetWithinParagraph` stays consistent with the read-along
        // word→page map keyed off the same offsets.
        let words = paragraph.split(separator: " ").map(String.init)
        if words.isEmpty { continue }

        var startWord = 0
        while startWord < words.count {
            let firstOnPage = current.isEmpty
            let width = firstOnPage ? g.firstRowWidth : g.bodyRowWidth
            let spacing = firstOnPage ? 0 : g.paragraphSpacing
            let available = g.availableHeight - used - spacing

            let tailText = words[startWord...].joined(separator: " ")
            let tailHeight = measure(tailText, width)

            if tailHeight <= available {
                // The rest of the paragraph fits on this page.
                place(originalIndex, tailText, wordOffset: startWord, height: tailHeight, spacing: spacing)
                startWord = words.count
                continue
            }

            // The remainder doesn't fit. Either fill this page with a head
            // chunk of at least ~2 lines, push the paragraph to a fresh page,
            // or — only on an already-empty page — force a split for progress.
            let headWords = maxPrefixWords(words, start: startWord, width: width, maxHeight: available)
            let leavesTail = (startWord + headWords) < words.count
            let headHeight = headWords > 0
                ? measure(words[startWord..<startWord + headWords].joined(separator: " "), width)
                : 0

            if headWords >= 1, headHeight >= minHeadHeight, leavesTail {
                // Fill the rest of this page with a head chunk, then break.
                let headText = words[startWord..<startWord + headWords].joined(separator: " ")
                place(originalIndex, headText, wordOffset: startWord, height: headHeight, spacing: spacing)
                startWord += headWords
                flush()
            } else if !firstOnPage {
                // Only a sliver (or nothing) fits in the space left on this
                // page. A fresh full-height page splits more cleanly than
                // stranding an orphan line or forcing a word past the page
                // bottom, so close this page and retry the paragraph as the
                // first on the next one. (`firstOnPage` is then true, so this
                // can't loop.)
                flush()
            } else {
                // Fresh page and the paragraph is STILL taller than a whole
                // page: split to fill. `headWords` is bounded by `available`
                // (≈ a full page here) so the placed chunk does not overflow —
                // except when a SINGLE token is itself taller than a full page
                // (a 100+ character word that character-wraps past the page,
                // i.e. malformed content). There is no clean break for that, so
                // place it anyway to guarantee the loop makes progress.
                let k = max(headWords, 1)
                let headText = words[startWord..<startWord + k].joined(separator: " ")
                place(originalIndex, headText, wordOffset: startWord, height: measure(headText, width), spacing: spacing)
                startWord += k
                flush()
            }
        }
    }

    flush()
    if pages.isEmpty {
        pages.append(PageContent(index: 0, paragraphs: []))
    }
    return pages
}

// MARK: - TextKit measurer (matches HighlightableTextView exactly)

#if canImport(UIKit)
/// Body-text metrics shared between the rendered `HighlightableTextView` and
/// the paginator's measurement. These MUST stay identical to the view's setup
/// (serif 17, lineSpacing 8, zero container inset, zero fragment padding) or
/// the measured break drifts from where the text actually wraps.
enum BodyTextMetrics {
    static let font: UIFont = {
        let base = UIFont.systemFont(ofSize: 17)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: 17)
        }
        return base
    }()

    static let lineSpacing: CGFloat = 8

    /// One body line's vertical footprint, line spacing included.
    static var lineUnit: CGFloat { ceil(font.lineHeight + lineSpacing) }

    /// Rendered height of `text` wrapped to `width`, laid out with the same
    /// TextKit configuration `UITextView` uses inside `HighlightableTextView`
    /// (`textContainerInset = .zero`, `lineFragmentPadding = 0`). Using a raw
    /// layout manager rather than `boundingRect` matches the on-screen wrap
    /// line-for-line.
    static func measuredHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let storage = NSTextStorage(string: text, attributes: [
            .font: font,
            .paragraphStyle: style,
        ])
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }
}
#endif

// MARK: - Caches & geometry plumbing

/// Memoizes paginations so flipping pages (which rebuilds the page view) and
/// the read-along word→page lookup don't re-measure a whole chapter every
/// call. Keyed by chapter + geometry signature, so a rotation or spread flip
/// produces fresh keys and the stale entries simply go unused.
@MainActor
final class PaginationCache {
    private var store: [String: [PageContent]] = [:]

    func pages(forKey key: String, compute: () -> [PageContent]) -> [PageContent] {
        if let cached = store[key] { return cached }
        let pages = compute()
        store[key] = pages
        return pages
    }

    func invalidateAll() { store.removeAll() }
}

/// Reports the live size of the page surface (one page of the curl container)
/// up to `ReaderView`, which derives the measured page budget from it.
struct PageAreaSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
