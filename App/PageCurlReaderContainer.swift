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
    /// When false, the PVC's built-in pan recognizers are disabled. Arrow
    /// keys and edge taps still flip; click-drag is free for text selection.
    var swipeToFlipEnabled: Bool = true

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
        applySwipeEnabled(to: pvc)
        // Deferred so the binding write happens after representable construction.
        DispatchQueue.main.async { [weak coord = context.coordinator] in
            flipController = { forward in coord?.flipPage(forward: forward) }
        }
        return pvc
    }

    /// `UIPageViewController.pageCurl` exposes its swipe / pan via the PVC
    /// view's gesture recognizers. Disabling them leaves edge taps + the
    /// imperative flipController (arrow keys) as the remaining flip paths.
    private func applySwipeEnabled(to pvc: UIPageViewController) {
        for g in pvc.view.gestureRecognizers ?? [] {
            if g is UIPanGestureRecognizer || g is UIScreenEdgePanGestureRecognizer {
                g.isEnabled = swipeToFlipEnabled
            }
        }
    }

    /// Mirror of `Theme.canvas` — UIKit needs `UIColor`. Keep in sync.
    static let parchmentCanvasUIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red:  27/255, green:  24/255, blue:  21/255, alpha: 1)
            : UIColor(red: 244/255, green: 239/255, blue: 230/255, alpha: 1)
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        applySwipeEnabled(to: pvc)
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
            let leftIdx = (safe / 2) * 2
            let leftVC = makePage(at: leftIdx)
            if leftIdx + 1 < totalPages {
                let rightVC = makePage(at: leftIdx + 1)
                pvc.setViewControllers([leftVC, rightVC], direction: direction, animated: animated)
            } else {
                pvc.setViewControllers([leftVC], direction: direction, animated: animated)
            }
        } else {
            pvc.setViewControllers([makePage(at: safe)], direction: direction, animated: animated)
        }
    }

    private func makePage(at index: Int) -> IndexedHostingController {
        IndexedHostingController(pageIndex: index, rootView: pageBuilder(index))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let parent: PageCurlReaderContainer
        /// One-shot — consumed by the next `updateUIViewController` so
        /// chapter picks and progress restore still snap.
        private var pendingAnimatedFlip = false

        init(parent: PageCurlReaderContainer) {
            self.parent = parent
        }

        func flipPage(forward: Bool) {
            let target = forward ? parent.currentIndex + 1 : parent.currentIndex - 1
            guard target >= 0, target < parent.totalPages else { return }
            pendingAnimatedFlip = true
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
            guard let current = viewController as? IndexedHostingController,
                  current.pageIndex > 0 else { return nil }
            let prev = current.pageIndex - 1
            return IndexedHostingController(pageIndex: prev, rootView: parent.pageBuilder(prev))
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? IndexedHostingController,
                  current.pageIndex < parent.totalPages - 1 else { return nil }
            let next = current.pageIndex + 1
            return IndexedHostingController(pageIndex: next, rootView: parent.pageBuilder(next))
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard finished, completed,
                  let current = pageViewController.viewControllers?.first as? IndexedHostingController
            else { return }
            // Defer so we don't re-enter the representable update path mid-animation.
            DispatchQueue.main.async {
                self.parent.currentIndex = current.pageIndex
            }
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
