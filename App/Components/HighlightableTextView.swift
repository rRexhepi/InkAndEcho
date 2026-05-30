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
    let onToggleWord: (Int) -> Void
    let onPaintWord: (Int) -> Void

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
                inner?.selectedTextRange = nil
            }
            return UIMenu(children: [highlight] + suggestedActions)
        }
    }

    final class InnerTextView: UITextView {
        var wordRanges: [(localIndex: Int, range: NSRange)] = []
        var onToggleWord: ((Int) -> Void)?
        var onPaintWord: ((Int) -> Void)?

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
            para.lineSpacing = 8
            ns.addAttribute(NSAttributedString.Key.paragraphStyle, value: para, range: full)
            // SwiftUI `Color` backgrounds don't survive `NSAttributedString(_:)`,
            // so per-word paint + read-along backgrounds are applied here as real
            // UIColor attributes (same reason `textColor` is force-set below).
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
            font = Self.serifBody
            textColor = UIColor(Theme.ink)
            tintColor = UIColor(Theme.ink)
        }

        private static let serifBody: UIFont = {
            let base = UIFont.systemFont(ofSize: 17)
            if let d = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: d, size: 17)
            }
            return base
        }()

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
                        onPaintWord?(w)
                    }
                }
            }
            if inDragSession, let idx = wordIndex(at: p), !visited.contains(idx) {
                visited.insert(idx)
                onPaintWord?(idx)
            }
            super.touchesMoved(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if !inDragSession, let w = startWord {
                onToggleWord?(w)
            }
            touchStart = nil
            startWord = nil
            visited.removeAll()
            inDragSession = false
            super.touchesEnded(touches, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
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
