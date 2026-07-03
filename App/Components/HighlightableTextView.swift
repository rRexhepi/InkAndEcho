#if os(iOS)
import SwiftUI
import UIKit

/// UITextView wrapper that supports per-word tap (toggle) and drag (paint).
/// `wordRanges` maps a local word index to its `NSRange` in the rendered
/// string. `onToggleWord` fires once on a tap-without-drag; `onPaintWord`
/// fires once per newly-entered word during a drag.
struct HighlightableTextView: UIViewRepresentable {
    let attributedString: AttributedString
    let wordRanges: [(localIndex: Int, range: NSRange)]
    let wordBackgrounds: [(range: NSRange, color: UIColor)]
    /// Tint shown live under the finger while drag-painting, before the
    /// annotations commit at gesture end.
    let paintPreviewColor: UIColor
    let onToggleWord: (Int) -> Void
    let onPaintWord: (Int) -> Void
    /// Fired once when a paint gesture (drag or edit-menu Highlight)
    /// finishes — the canonical-re-render point.
    let onPaintEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InnerTextView {
        let v = InnerTextView()
        v.isEditable = false
        // `isSelectable = true` enables the system long-press → loupe →
        // Copy / Look Up / Translate menu on a per-word basis. Our
        // overridden touchesBegan/Moved/Ended still see the touch first;
        // a quick tap fires `onToggleWord`, a sustained press hands off
        // to UIKit's selection gesture.
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.dataDetectorTypes = []
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: InnerTextView, context: Context) {
        v.wordRanges = wordRanges
        v.onToggleWord = onToggleWord
        v.onPaintWord = onPaintWord
        v.onPaintEnded = onPaintEnded
        v.paintPreviewColor = paintPreviewColor
        v.applyAttributedString(attributedString, backgrounds: wordBackgrounds)
    }

    /// `textView(_:editMenuForTextIn:suggestedActions:)` is the documented
    /// hook for adding actions to the system selection menu; overriding
    /// `editMenu(...)` on the UITextView subclass compiles but isn't what
    /// iOS calls.
    final class Coordinator: NSObject, UITextViewDelegate {
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let inner = textView as? InnerTextView else { return nil }
            let words = inner.wordRanges
                .filter { NSIntersectionRange($0.range, range).length > 0 }
                .map(\.localIndex)
            guard !words.isEmpty, let paint = inner.onPaintWord else { return nil }
            let highlight = UIAction(title: "Highlight") { [weak inner] _ in
                for idx in words { paint(idx) }
                inner?.onPaintEnded?()
                inner?.selectedTextRange = nil
            }
            return UIMenu(children: [highlight] + suggestedActions)
        }
    }

    final class InnerTextView: UITextView {
        var wordRanges: [(localIndex: Int, range: NSRange)] = []
        var onToggleWord: ((Int) -> Void)?
        var onPaintWord: ((Int) -> Void)?
        var onPaintEnded: (() -> Void)?
        var paintPreviewColor: UIColor = .systemYellow.withAlphaComponent(0.3)

        /// Squared pixel threshold before a press is reclassified as a drag.
        /// Below this, lift = tap (toggle); at/above, the drag begins and we
        /// paint everything visited from the press onward.
        private let moveThresholdSquared: CGFloat = 64

        private var touchStart: CGPoint?
        private var startWord: Int?
        private var visited: Set<Int> = []
        private var inDragSession = false
        private var lastLaidOutWidth: CGFloat = 0

        /// SwiftUI hands us a layout width via `bounds`; pin the text
        /// container to it and recompute intrinsic height from there.
        /// Without this, UITextView (isScrollEnabled = false) reports
        /// the unbounded line width as its intrinsic content size and
        /// SwiftUI lays a whole paragraph out on one line.
        override func layoutSubviews() {
            super.layoutSubviews()
            let w = bounds.width
            if w > 0, abs(w - lastLaidOutWidth) > 0.5 {
                lastLaidOutWidth = w
                textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)
                invalidateIntrinsicContentSize()
            }
        }

        override var intrinsicContentSize: CGSize {
            let w = lastLaidOutWidth > 0 ? lastLaidOutWidth : bounds.width
            guard w > 0 else { return super.intrinsicContentSize }
            let size = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
        }

        func applyAttributedString(_ s: AttributedString, backgrounds: [(range: NSRange, color: UIColor)] = []) {
            let ns = NSMutableAttributedString(attributedString: NSAttributedString(s))
            let full = NSRange(location: 0, length: ns.length)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = BodyTextMetrics.lineSpacing
            ns.addAttribute(NSAttributedString.Key.paragraphStyle, value: para, range: full)
            // Font + ink go INTO the candidate string, not onto the view
            // after assignment. The old view-level `font =` / `textColor =`
            // setters wrote `.font`/`.foregroundColor` into the live storage
            // only, so the freshly built `ns` never compared equal and every
            // update reassigned `attributedText` — a full TextKit relayout
            // per row per word tick that also killed any in-progress text
            // selection. (They're also why UIKit renders a color at all: the
            // bridged SwiftUI.ForegroundColor key means nothing to UITextView.)
            ns.addAttribute(.font, value: BodyTextMetrics.font, range: full)
            ns.addAttribute(.foregroundColor, value: UIColor(Theme.ink), range: full)
            // SwiftUI `Color` backgrounds don't survive `NSAttributedString(_:)`,
            // so per-word paint + read-along backgrounds are applied here as real
            // UIColor attributes.
            for bg in backgrounds {
                let r = NSIntersectionRange(bg.range, full)
                if r.length > 0 {
                    ns.addAttribute(.backgroundColor, value: bg.color, range: r)
                }
            }
            if attributedText?.isEqual(to: ns) != true {
                attributedText = ns
                invalidateIntrinsicContentSize()
            }
            tintColor = UIColor(Theme.ink)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let p = touches.first?.location(in: self) else {
                super.touchesBegan(touches, with: event); return
            }
            touchStart = p
            inDragSession = false
            visited.removeAll()
            startWord = wordIndex(at: p)
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let start = touchStart,
                  let p = touches.first?.location(in: self) else {
                super.touchesMoved(touches, with: event); return
            }
            if !inDragSession {
                let dx = p.x - start.x, dy = p.y - start.y
                if dx*dx + dy*dy >= moveThresholdSquared {
                    inDragSession = true
                    if let w = startWord, !visited.contains(w) {
                        visited.insert(w)
                        paintWordDuringDrag(w)
                    }
                }
            }
            if inDragSession, let idx = wordIndex(at: p), !visited.contains(idx) {
                visited.insert(idx)
                paintWordDuringDrag(idx)
            }
            super.touchesMoved(touches, with: event)
        }

        /// Insert the annotation AND tint the word locally. The canonical
        /// re-render is deferred to gesture end (`onPaintEnded`) because it
        /// re-identifies the page container — doing that per word destroyed
        /// this very text view mid-drag. The transient attribute is what the
        /// user sees until then; the commit's rebuild replaces it.
        private func paintWordDuringDrag(_ idx: Int) {
            onPaintWord?(idx)
            if let entry = wordRanges.first(where: { $0.localIndex == idx }) {
                textStorage.addAttribute(.backgroundColor, value: paintPreviewColor, range: entry.range)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if !inDragSession, let w = startWord {
                onToggleWord?(w)
            } else if inDragSession, !visited.isEmpty {
                onPaintEnded?()
            }
            touchStart = nil
            startWord = nil
            visited.removeAll()
            inDragSession = false
            super.touchesEnded(touches, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if inDragSession, !visited.isEmpty {
                // The words painted so far are already inserted; commit the
                // re-render so the canonical tint replaces the transient one.
                onPaintEnded?()
            }
            touchStart = nil
            startWord = nil
            visited.removeAll()
            inDragSession = false
            super.touchesCancelled(touches, with: event)
        }

        private func wordIndex(at point: CGPoint) -> Int? {
            guard let position = closestPosition(to: point) else { return nil }
            let offset = self.offset(from: beginningOfDocument, to: position)
            // Bias the lookup toward the word that *contains* the offset; fall
            // back to the closest end-of-range so taps just past the last
            // character of a word still register on that word.
            for entry in wordRanges where NSLocationInRange(offset, entry.range) {
                return entry.localIndex
            }
            return wordRanges.min(by: {
                abs($0.range.location + $0.range.length / 2 - offset)
                < abs($1.range.location + $1.range.length / 2 - offset)
            })?.localIndex
        }
    }
}
#endif
