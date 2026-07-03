#if os(iOS)
import SwiftUI
import InkAndEchoCore

/// iOS layouts for `ReaderView`. Dispatches between iPhone (compact width)
/// and iPad (regular width). Both layouts share the same underlying
/// pagination, alignment, and annotation machinery from `ReaderView`; the
/// chrome around the page surface is different per device class.
extension ReaderView {

    @ViewBuilder
    var iosReaderLayout: some View {
        if horizontalSizeClass == .compact {
            phoneLayout
        } else {
            padLayout
        }
    }

    /// The reader's page surface. Uses `PageCurlReaderContainer`
    /// (UIPageViewController.pageCurl) so the page-turn animation is
    /// identical to Apple's Books app — gesture-driven curl from any
    /// edge, peek-the-next-page when you lift the corner, swipe-velocity
    /// determines whether the turn completes or springs back. Catalyst
    /// runs the same UIKit path on macOS.
    ///
    /// `useSpread = true` switches the underlying `UIPageViewController`
    /// to `.mid` spine so two pages render side-by-side. iPad landscape
    /// passes `true`; iPhone and iPad portrait pass `false`.
    @ViewBuilder
    func iosPageContent(useSpread: Bool) -> some View {
        Group {
            if loadingSegments {
                ProgressView().padding(.top, 80)
            } else if let loadError {
                Text(loadError).font(.callout).foregroundStyle(.red).padding()
            } else if !segments.isEmpty, paginated, flatTotalPages > 0 {
                PageCurlReaderContainer(
                    totalPages: flatTotalPages,
                    currentIndex: iosCurlBinding,
                    useSpread: useSpread,
                    pageBuilder: { idx in iosBuildPage(at: idx) },
                    flipController: $iosFlipController,
                    animationsEnabled: animationsEnabled
                )
                // Re-create the container whenever the boundary budget OR
                // spread mode flips so UIPageViewController throws away its
                // cached view controllers and rebuilds for the new layout.
                //
                // `annotationRevision` is a `@State` counter incremented by
                // every insert/delete/edit of an annotation. SwiftData
                // relationship reads (`book.annotations`) don't reliably
                // trigger body re-evaluation on iOS 17, so we drive the
                // identity change explicitly. Without it the action saves
                // but the page looks unchanged until you flip away and back
                // — or worse, until you relaunch the app.
                .id("curl-\(useSpread ? "spread" : "single")-\(flatBoundariesBudget)-\(flatBoundariesAreaKey)-\(segments.count)-\(annotationRevision)-ra\(readAlongMode.rawValue)")
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.hairlineStrong, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
                .padding(.horizontal, useSpread ? 24 : 12)
                .padding(.vertical, 16)
            } else if let segment = currentSegment {
                // Scroll mode (paginate toggle off) — fall through to the
                // shared scroll renderer.
                scrollView(segment: segment)
            } else {
                Text("Empty chapter").foregroundStyle(Theme.inkMuted).padding()
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.canvasCool)
        // Measure the page-content SLOT (not the curling container) so a page
        // curl — which transforms child pages and spams scene relayouts — can
        // never report a changed size mid-gesture and re-paginate underneath
        // the live UIPageViewController. The curl surface is this slot minus
        // the container's fixed padding; derived + rounded in the handler.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PageAreaSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(PageAreaSizeKey.self) { slot in
            updateReaderPageArea(fromSlot: slot, useSpread: useSpread)
        }
        .focusable()
        // Without explicitly taking focus, `onKeyPress` never fires —
        // arrow-key / space page turns on iPad keyboards and Catalyst
        // depended on the focus system happening to pick this Group.
        .focused($pageFocused)
        .onAppear { pageFocused = true }
        .onKeyPress(.leftArrow) {
            iosFlipController?(false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            iosFlipController?(true)
            return .handled
        }
        .onKeyPress(.space) {
            iosFlipController?(true)
            return .handled
        }
        .task(id: "\(segments.count)-\(useSpread)-\(pageAreaKey)") {
            recomputeFlatPageBoundaries(useSpread: useSpread)
        }
    }

    private var iosCurlBinding: Binding<Int> {
        Binding(
            get: {
                let segID = selectedSegmentID ?? segments.first?.id ?? ""
                return flatGlobalIndex(segmentID: segID, pageIdx: currentPageIndex)
            },
            set: { newGlobal in
                guard let mapping = flatSegmentAndPage(forGlobalIndex: newGlobal) else { return }
                if mapping.segmentID != selectedSegmentID {
                    isRestoringProgress = true
                    selectedSegmentID = mapping.segmentID
                }
                currentPageIndex = mapping.pageIdx
            }
        )
    }

    private func iosBuildPage(at globalIndex: Int) -> AnyView {
        guard let mapping = flatSegmentAndPage(forGlobalIndex: globalIndex),
              let segment = segments.first(where: { $0.id == mapping.segmentID })
        else {
            return AnyView(Color(uiColor: .systemBackground))
        }
        let pages = paginatedPages(for: segment)
        let safeIdx = max(0, min(mapping.pageIdx, pages.count - 1))
        guard pages.indices.contains(safeIdx) else {
            return AnyView(Color(uiColor: .systemBackground))
        }
        // Border lives INSIDE the page surface, so when this page curls
        // away the border curls with it instead of staying anchored in
        // screen space (which is what made the spine look like it was
        // painted on top of the lifted leaf). In spread mode the inner
        // edges of two adjacent pages meet to form the gutter line — no
        // separate spine overlay needed.
        return AnyView(
            pageSurface(segment: segment, page: pages[safeIdx], pageIndex: safeIdx)
                .background(Theme.canvas)
                .overlay(
                    Rectangle()
                        .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                )
        )
    }

    /// Derive the curl page-surface size from the page-content slot (slot minus
    /// the curl container's fixed padding) and store it ROUNDED, so sub-point
    /// layout flutter during a curl never bumps `pageAreaKey` and re-paginates
    /// the live page controller. Captures the current page's first word before a
    /// genuine resize so the reading position survives the re-pagination.
    func updateReaderPageArea(fromSlot slot: CGSize, useSpread: Bool) {
        let horizontalInset: CGFloat = useSpread ? 48 : 24   // .padding(.horizontal, 24|12) × 2
        let verticalInset: CGFloat = 32                       // .padding(.vertical, 16) × 2
        let area = CGSize(
            width: max(0, (slot.width - horizontalInset).rounded()),
            height: max(0, (slot.height - verticalInset).rounded())
        )
        guard area.width > 1, area.height > 1, area != readerPageArea else { return }
        if readerPageArea != .zero { pendingAnchorWord = currentPageFirstWord() }
        readerPageArea = area
    }

    // MARK: - iPad layout

    /// iPad: collapsible icon-rail sidebar (44pt) on the left, two-page
    /// spread (or single page in portrait) in the middle, audio bar at the
    /// bottom. Tapping the rail icon expands the sidebar to ~280pt with
    /// the same Chapters / Bookmarks / Notes tabs from macOS.
    var padLayout: some View {
        GeometryReader { geo in
            // Two-page spread when the iPad is landscape (width > height),
            // matching Books.app. Portrait drops to single-page since each
            // half would otherwise be too narrow for the 17pt serif body.
            let useSpread = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if iosSidebarVisible {
                        iosExpandedSidebar
                            .frame(width: 280)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        iosCollapsedRail
                            .frame(width: 64)
                    }
                    Divider().background(Theme.hairline)
                    iosPageContent(useSpread: useSpread)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let notice = seekNotice {
                    seekNoticeBanner(notice)
                } else if alignmentRunning {
                    alignmentBanner
                } else if let toast = alignmentToast {
                    alignmentToastBanner(toast)
                }
                iosAudioFooter
            }
            .background(Theme.canvas)
            .animation(.easeInOut(duration: 0.22), value: iosSidebarVisible)
            .ignoresSafeArea(.keyboard)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $iosShowSettings) {
            iosSettingsSheet
        }
    }

    var iosCollapsedRail: some View {
        VStack(spacing: 4) {
            iosRailButton(icon: "line.3.horizontal", isSelected: false) {
                withAnimation { iosSidebarVisible = true }
            }
            Spacer().frame(height: 14)
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                iosRailButton(
                    icon: railIcon(for: tab),
                    isSelected: sidebarTab == tab && iosSidebarVisible
                ) {
                    sidebarTab = tab
                    withAnimation { iosSidebarVisible = true }
                }
            }
            Spacer()
            iosRailButton(icon: "gearshape", isSelected: false) {
                iosShowSettings = true
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 14)
        .frame(maxHeight: .infinity)
        .background(Theme.canvasCool)
    }

    private func railIcon(for tab: SidebarTab) -> String {
        switch tab {
        case .chapters: return "list.bullet"
        case .bookmarks: return "bookmark"
        case .notes: return "text.bubble"
        }
    }

    private func iosRailButton(icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.inkMuted)
                .frame(width: 40, height: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.accent.opacity(0.14))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var iosExpandedSidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 15, design: .serif))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(book.author)
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation { iosSidebarVisible = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            Divider().background(Theme.hairline)
            sidebarTabBar
            Divider().background(Theme.hairline)
            sidebarTabContent()
            Divider().background(Theme.hairline)
            sidebarFooter
        }
        .background(Theme.canvasCool)
    }

    // MARK: - iPad audio footer

    @ViewBuilder
    var iosAudioFooter: some View {
        if showSwitchToAudioBar {
            switchToAudiobookBar
        } else if book.audiobookFileURL != nil {
            AudioBarTouchView(
                engine: engine,
                compact: false,
                onAlign: alignmentRunning ? nil : { runAlignment() },
                alignmentExists: alignmentMap != nil,
                onRequestExpand: nil,
                chapterEndTime: { currentChapterEndSeconds() },
                loadError: audioLoadErrorMessage,
                onRetry: { retryAudioLoad() },
                onSentenceStep: denseWords.isEmpty ? nil : { seekToSentence(offset: $0) }
            )
        } else {
            attachAudiobookBar
        }
    }

    /// Background mode, another book playing: a single tap to bring the shared
    /// engine onto this book (resuming its saved spot) instead of live
    /// transport for a book that isn't currently loaded.
    var switchToAudiobookBar: some View {
        Button {
            activateThisBookAudio()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Play this audiobook")
                        .font(.system(size: 14, weight: .semibold))
                    Text("“\(audio.loadedTitle)” is playing")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvasCool)
            .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - iPhone layout

    /// iPhone: full-bleed single page, top header (chapter title + drawer
    /// access), bottom compact audio bar that taps to expand. Slide-up
    /// chapter drawer reuses the macOS sidebar tab content.
    ///
    /// Ambient mode: tap the page to slide the chrome off and read with
    /// nothing but the type and a faint right-edge gesture cue. Tap again
    /// to bring the chrome back.
    var phoneLayout: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                phoneHeader
                iosPageContent(useSpread: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = seekNotice {
                    seekNoticeBanner(notice)
                } else if alignmentRunning {
                    alignmentBanner
                } else if let toast = alignmentToast {
                    alignmentToastBanner(toast)
                }
                phoneAudioBarOrAttach
            }
            .background(Theme.canvas)
        }
        .navigationBarBackButtonHidden(false)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $iosShowSettings) {
            iosSettingsSheet
        }
        .sheet(isPresented: $iosShowChapterSheet) {
            phoneDrawerSheet
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $iosShowAudioSheet) {
            phoneAudioSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Alignment in progress",
            isPresented: $iosShowLeaveAlignmentConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave anyway") { iosDismiss() }
            Button("Cancel alignment", role: .destructive) {
                alignment.cancel()
                iosDismiss()
            }
            Button("Stay", role: .cancel) { }
        } message: {
            Text("WhisperKit is still transcribing this book. Leaving keeps the job running in the background — the library row will show progress.")
        }
    }

    /// Right-edge swipe-to-turn gesture cue. Slowly fades in/out so it
    /// reads as a hint rather than an active control. Only visible while
    /// the chrome is hidden (ambient reading).
    private var phoneEdgeHint: some View {
        TimelineView(.animation(minimumInterval: 0.04, paused: false)) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)) / 2.4
            let pulse = 0.30 + 0.25 * sin(phase * .pi * 2)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkMuted.opacity(pulse))
        }
    }

    var phoneHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            phoneHeaderButton(icon: "chevron.left") { iosBackToLibrary() }
            phoneHeaderButton(icon: "line.3.horizontal") { iosShowChapterSheet = true }
            Spacer(minLength: 0)
            Text(currentSegment.map { displayChapterLabel(for: $0) } ?? book.title)
                .font(.system(size: 13, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            phoneHeaderButton(icon: "textformat.size") { showTypographyPopover = true }
                .popover(isPresented: $showTypographyPopover) {
                    TypographyStepper()
                        .padding(16)
                        .presentationCompactAdaptation(.popover)
                }
            Menu {
                Button {
                    paginated.toggle()
                } label: {
                    Label(paginated ? "Switch to scroll" : "Switch to paginated",
                          systemImage: paginated ? "scroll" : "book.pages")
                }
                Button {
                    showAnnotationsSheet = true
                } label: {
                    Label("All annotations", systemImage: "list.bullet.indent")
                }
                if book.audiobookFileURL != nil {
                    Button {
                        runAlignment()
                    } label: {
                        Label(alignmentMap != nil ? "Re-align audio" : "Align audio",
                              systemImage: "waveform.path")
                    }
                    .disabled(alignmentRunning)
                    Button {
                        showAudioImporter = true
                    } label: {
                        Label("Replace audiobook…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(alignmentRunning)
                }
                Divider()
                Button {
                    iosShowSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 40, height: 40)
                    .background(Theme.canvasDeep.opacity(0.5))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.canvas)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .bottom)
    }

    /// Pop the navigation stack back to the library list. Bound to the
    /// chevron-left in the phone header since hiding the navbar disables
    /// the system back-swipe gesture.
    ///
    /// If alignment is running for this book, surface a confirmation
    /// first — the job survives popping the view (the coordinator owns
    /// the Task), but the user has no way to know that without being
    /// told. iPad's system back doesn't route through here; on iPad the
    /// library row's "Aligning…" pill plays the same role.
    private func iosBackToLibrary() {
        if alignmentRunning {
            iosShowLeaveAlignmentConfirm = true
        } else {
            iosDismiss()
        }
    }

    private func phoneHeaderButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 40, height: 40)
                .background(Theme.canvasDeep.opacity(0.5))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var phoneAudioBarOrAttach: some View {
        if showSwitchToAudioBar {
            switchToAudiobookBar
        } else if book.audiobookFileURL != nil {
            AudioBarTouchView(
                engine: engine,
                compact: true,
                onAlign: nil,
                alignmentExists: alignmentMap != nil,
                onRequestExpand: { iosShowAudioSheet = true },
                loadError: audioLoadErrorMessage,
                onRetry: { retryAudioLoad() }
            )
        } else {
            attachAudiobookBar
        }
    }

    var phoneDrawerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Contents")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.inkMuted)
                Text(book.title)
                    .font(.system(size: 22, design: .serif))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 14)
            HStack(spacing: 8) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Button {
                        sidebarTab = tab
                    } label: {
                        Text(tab.rawValue.capitalized)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(sidebarTab == tab ? Theme.accent : Theme.inkMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background {
                                if sidebarTab == tab {
                                    Capsule().fill(Theme.accent.opacity(0.14))
                                } else {
                                    Capsule().stroke(Theme.hairline, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            Divider().background(Theme.hairline)
            sidebarTabContent(onNavigate: { iosShowChapterSheet = false })
                .background(Theme.canvas)
        }
        .background(Theme.canvas)
    }

    var iosSettingsSheet: some View {
        NavigationStack {
            IOSSettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { iosShowSettings = false }
                    }
                }
        }
    }

    var phoneAudioSheet: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Now reading")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.inkMuted)
                Text(currentSegment.map { displayChapterLabel(for: $0) } ?? book.title)
                    .font(.system(size: 18, design: .serif))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(book.author)
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 22)
            AudioBarTouchView(
                engine: engine,
                compact: false,
                onAlign: alignmentRunning ? nil : { runAlignment() },
                alignmentExists: alignmentMap != nil,
                onRequestExpand: nil,
                chapterEndTime: { currentChapterEndSeconds() },
                loadError: audioLoadErrorMessage,
                onRetry: { retryAudioLoad() },
                onSentenceStep: denseWords.isEmpty ? nil : { seekToSentence(offset: $0) }
            )
            .background(Color.clear)
            Spacer(minLength: 0)
        }
        .background(Theme.canvas)
    }
}
#endif
