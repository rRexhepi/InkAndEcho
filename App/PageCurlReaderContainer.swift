#if os(iOS)
import SwiftUI
import UIKit

struct PageCurlReaderContainer: UIViewControllerRepresentable {
    let totalPages: Int
    @Binding var currentIndex: Int
    /// Toggling at runtime requires rebuilding — bump the SwiftUI `.id`.
    let useSpread: Bool
    let pageBuilder: (Int) -> AnyView
    /// Escape hatch for imperative animated flips. Snap flips go through `currentIndex`.
    @Binding var flipController: ((Bool) -> Void)?
    /// When false, PVC's built-in curl gestures are disabled and a custom
    /// horizontal pan instant-flips the page. Programmatic flips also
    /// drop the commit animation.
    var animationsEnabled: Bool = true

    func makeUIViewController(context: Context) -> UIPageViewController {
        let options: [UIPageViewController.OptionsKey: Any] = useSpread
            ? [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.mid.rawValue)]
            : [:]
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: options
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        // iOS ≤25: this paints the curl-back face parchment instead of white.
        // iOS 26: regression — `.pageCurl` hardcodes the back face to white
        // regardless of this. Left set for older iOS and in case Apple fixes it.
        pvc.view.backgroundColor = Self.parchmentCanvasUIColor
        pvc.view.isOpaque = true
        if totalPages > 0 {
            setControllers(on: pvc, animated: false, direction: .forward)
        }
        // UITextView (HighlightableTextView) inside each page has greedy
        // selection recognizers that otherwise starve the curl pan; this
        // delegate makes the curl recognize alongside them.
        for g in pvc.gestureRecognizers {
            g.delegate = context.coordinator
        }
        // Standby instant-pan: replaces the built-in curl when animations
        // are off. The curl can't be turned off on `.pageCurl` itself, so
        // we disable PVC's gestures and route swipes through this one,
        // calling `setControllers(animated: false)` for an instant flip.
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleInstantPan(_:))
        )
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        pvc.view.addGestureRecognizer(pan)
        context.coordinator.instantPan = pan
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgeTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        pvc.view.addGestureRecognizer(tap)
        context.coordinator.edgeTap = tap
        applyAnimationMode(to: pvc, coordinator: context.coordinator)
        // Deferred so the binding write happens after representable construction.
        DispatchQueue.main.async { [weak coord = context.coordinator] in
            flipController = { forward in coord?.flipPage(forward: forward) }
        }
        return pvc
    }

    private func applyAnimationMode(to pvc: UIPageViewController, coordinator: Coordinator) {
        for g in pvc.gestureRecognizers {
            g.isEnabled = animationsEnabled
        }
        coordinator.instantPan?.isEnabled = !animationsEnabled
        coordinator.edgeTap?.isEnabled = !animationsEnabled
    }

    /// Mirror of `Theme.canvas` — UIKit needs `UIColor`. Keep in sync.
    static let parchmentCanvasUIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red:  27/255, green:  24/255, blue:  21/255, alpha: 1)
            : UIColor(red: 244/255, green: 239/255, blue: 230/255, alpha: 1)
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        // A user curl may be mid-flight (finger holding a half-turned page).
        // Refreshing the coordinator's `parent` snapshot, re-applying gesture
        // state, OR calling `setViewControllers` during that transition
        // corrupts the pageCurl's internal state — and re-renders are frequent
        // (narration-follow writes the bound index from 30 Hz audio ticks;
        // measured pagination updates geometry), so this overlap is real, not
        // theoretical. Touch NOTHING until the gesture finishes;
        // `didFinishAnimating` flips the flag and the next update reconciles.
        guard !context.coordinator.isUserTransitioning else { return }
        // Coordinator's `parent` is captured at init — refresh so toggles
        // (animationsEnabled, page count, content) reflect the latest snapshot.
        context.coordinator.parent = self
        applyAnimationMode(to: pvc, coordinator: context.coordinator)
        guard totalPages > 0 else { return }
        let safe = max(0, min(currentIndex, totalPages - 1))
        let visible = pvc.viewControllers?.compactMap { ($0 as? IndexedHostingController)?.pageIndex } ?? []
        let animated = context.coordinator.consumeAnimatedFlip()
        if useSpread {
            // Spread: visible pair is `[N, N+1]`; current normalises to the even (LEFT) index.
            let leftIdx = (safe / 2) * 2
            if visible.first == leftIdx { return }
            let direction: UIPageViewController.NavigationDirection =
                leftIdx > (visible.first ?? 0) ? .forward : .reverse
            setControllers(on: pvc, animated: animated, direction: direction, override: leftIdx)
        } else {
            guard let firstShown = visible.first, firstShown != safe else { return }
            let direction: UIPageViewController.NavigationDirection =
                safe > firstShown ? .forward : .reverse
            pvc.setViewControllers([makePage(at: safe)], direction: direction, animated: animated)
        }
    }

    private func setControllers(
        on pvc: UIPageViewController,
        animated: Bool,
        direction: UIPageViewController.NavigationDirection,
        override: Int? = nil
    ) {
        let safe = max(0, min(override ?? currentIndex, totalPages - 1))
        if useSpread {
            // A `.mid`-spine pageCurl requires EXACTLY two view controllers
            // in every `setViewControllers` call — handing it one raises
            // NSInvalidArgumentException. Odd page counts therefore pair the
            // final page with a blank parchment filler.
            let leftIdx = (safe / 2) * 2
            pvc.setViewControllers(
                [makePage(at: leftIdx), makePage(at: leftIdx + 1)],
                direction: direction,
                animated: animated
            )
        } else {
            pvc.setViewControllers([makePage(at: safe)], direction: direction, animated: animated)
        }
    }

    private func makePage(at index: Int) -> IndexedHostingController {
        // Out-of-range at EITHER edge = a blank parchment filler. Crucially the
        // data source hands these back instead of nil, so a built-in pageCurl
        // tap/pan at a boundary can never assemble 0 view controllers — the
        // UIKit abort "The number of view controllers provided (0) doesn't
        // match the number required (1)". It also squares off an odd page
        // count's final spread. `didFinishAnimating` clamps the landing back
        // onto a real page, so the curl simply bounces at the ends.
        guard index >= 0, index < totalPages else {
            return IndexedHostingController(
                pageIndex: index,
                rootView: AnyView(Color(uiColor: Self.parchmentCanvasUIColor))
            )
        }
        return IndexedHostingController(pageIndex: index, rootView: pageBuilder(index))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PageCurlReaderContainer
        weak var instantPan: UIPanGestureRecognizer?
        weak var edgeTap: UITapGestureRecognizer?
        /// One-shot — consumed by the next `updateUIViewController` so
        /// chapter picks and progress restore still snap.
        private var pendingAnimatedFlip = false
        /// True from `willTransitionTo` until `didFinishAnimating` — i.e.
        /// while a gesture-driven curl owns the page controller. Binding
        /// reconciliation must not call `setViewControllers` in that window.
        private(set) var isUserTransitioning = false

        init(parent: PageCurlReaderContainer) {
            self.parent = parent
        }

        @objc func handleInstantPan(_ g: UIPanGestureRecognizer) {
            guard g.state == .ended, let view = g.view else { return }
            let dx = g.translation(in: view).x
            let threshold: CGFloat = 50
            if dx < -threshold {
                flipPage(forward: true)
            } else if dx > threshold {
                flipPage(forward: false)
            }
        }

        @objc func handleEdgeTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            let p = g.location(in: view)
            let edge: CGFloat = 24
            if p.x < edge {
                flipPage(forward: false)
            } else if p.x > view.bounds.width - edge {
                flipPage(forward: true)
            }
        }

        func flipPage(forward: Bool) {
            // Spread mode steps by two from the normalized LEFT index — a ±1
            // step lands on the odd half of the same visible pair, which the
            // reconciler normalizes straight back: every other key press or
            // edge tap became a silent no-op (that still suspended
            // narration-follow and force-saved progress).
            let target: Int
            if parent.useSpread {
                let left = (parent.currentIndex / 2) * 2
                target = forward ? left + 2 : left - 2
            } else {
                target = forward ? parent.currentIndex + 1 : parent.currentIndex - 1
            }
            guard target >= 0, target < parent.totalPages else { return }
            pendingAnimatedFlip = parent.animationsEnabled
            parent.currentIndex = target
        }

        func consumeAnimatedFlip() -> Bool {
            let v = pendingAnimatedFlip
            pendingAnimatedFlip = false
            return v
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? IndexedHostingController else { return nil }
            // Filler (never nil) below the first page — see `makePage`. A nil
            // here is what aborts a boundary curl; the filler lets it bounce
            // back via `didFinishAnimating`'s clamp instead.
            return parent.makePage(at: current.pageIndex - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? IndexedHostingController else { return nil }
            // Filler (never nil) past the last page — see `makePage`.
            return parent.makePage(at: current.pageIndex + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isUserTransitioning = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isUserTransitioning = false
            guard finished, completed,
                  let current = pageViewController.viewControllers?.first as? IndexedHostingController
            else { return }
            let landed = max(0, min(current.pageIndex, parent.totalPages - 1))
            let landedOnFiller = current.pageIndex != landed
            // Defer everything out of this delegate callback. Calling
            // `setViewControllers` synchronously from inside `didFinishAnimating`
            // re-enters UIPageViewController's transition machinery and corrupts
            // it (the displayed page desyncs from the binding and gestures wedge).
            DispatchQueue.main.async {
                if landedOnFiller {
                    // Curled onto a boundary filler past an end. Snap straight
                    // back to the real page — the binding may already equal
                    // `landed` (we curled off the last real page), so a SwiftUI
                    // reconcile alone wouldn't replace the blank filler.
                    self.parent.setControllers(
                        on: pageViewController,
                        animated: false,
                        direction: .reverse,
                        override: landed
                    )
                }
                self.parent.currentIndex = landed
            }
        }

        // Allow the curl pan to coexist with UITextView's selection
        // gestures; otherwise the text view eats every touch.
        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // Sustained long-press is text selection, not a curl.
        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            other is UILongPressGestureRecognizer
        }

        // Instant-pan only fires for mostly-horizontal motion so vertical
        // drags (e.g. text selection) still reach the text view.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === instantPan, let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        // Edge tap defers to any subview that owns its own gesture
        // recognizer (⋯ menu, text view), so its only field of action is
        // empty page area on the outer 24pt.
        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard g === edgeTap, let container = g.view else { return true }
            var v: UIView? = touch.view
            while let cur = v, cur !== container {
                if let rs = cur.gestureRecognizers,
                   rs.contains(where: { $0 !== g && $0.isEnabled }) {
                    return false
                }
                v = cur.superview
            }
            return true
        }
    }
}

/// Subclass so the data source can recover `pageIndex` from a returned VC.
final class IndexedHostingController: UIHostingController<AnyView> {
    let pageIndex: Int

    init(pageIndex: Int, rootView: AnyView) {
        self.pageIndex = pageIndex
        super.init(rootView: rootView)
        view.backgroundColor = PageCurlReaderContainer.parchmentCanvasUIColor
        view.isOpaque = true
        view.layer.isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
