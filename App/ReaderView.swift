import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import InkAndEchoCore

struct ReaderView: View {
    let book: Book
    @Environment(\.modelContext) var modelContext
    @Environment(\.colorScheme) var colorScheme

    @State var segments: [TextSegment] = []
    @State var selectedSegmentID: String?
    @State var loadingSegments = true
    @State var loadError: String?

    /// The shared, app-owned engine (lives in `AudioCoordinator`). The
    /// computed `engine` below keeps every existing `engine.foo` call working
    /// while the instance now outlives this view — audio keeps playing when
    /// the reader is popped.
    @Environment(AudioCoordinator.self) var audio
    var engine: AudioEngine { audio.engine }
    /// True when the engine is loaded with THIS book's audiobook. Gates
    /// read-along, audio-position saving, and live transport UI — in
    /// background mode the engine may be playing a different book.
    var audioIsThisBook: Bool { audio.isLoaded(book) }
    @State var showAudioImporter = false
    @State var attachError: String?
    /// Multi-file pick: resolved playback order awaiting the user's confirm.
    @State var pendingAudioParts: [URL]?
    /// Non-nil while a multi-part merge runs; drives the attach bar's
    /// progress + Cancel rendering.
    @State var attachProgress: Double?
    @State var attachTask: Task<Void, Never>?
    /// One-shot alert when a SwiftData save fails. Annotation and progress
    /// writes used `try?` — a persistent failure (disk full beside multi-GB
    /// audiobooks) silently discarded highlights/notes/positions while the
    /// UI confirmed them.
    @State var persistError: String?

    @State var alignmentMap: AlignmentMap?
    /// Alignment progress + completion banner are sourced from the
    /// app-level `AlignmentCoordinator`. Going `back` while alignment is
    /// running pops this view but the coordinator keeps the job alive.
    @Environment(AlignmentCoordinator.self) var alignment

    var alignmentRunning: Bool { alignment.isRunning(for: book.id) }
    var alignmentStage: AlignmentStage { alignment.stage ?? .aligning }
    var alignmentToast: String? { alignmentRunning ? nil : alignment.toast }
    var alignmentError: String? { alignment.error }
    /// Transcription frontier (audio seconds) of a live partial alignment
    /// for THIS book; nil once the job completes or when another book's
    /// job is running. Everything at or past it is "not synced yet".
    var partialFrontier: Double? {
        guard alignmentRunning, alignment.partialMap != nil else { return nil }
        return alignment.partialCoveredThrough
    }
    /// Transient reader notice (e.g. tapping a not-yet-synced word during a
    /// running alignment). Auto-clears; rendered in the banner slot.
    @State var seekNotice: String?

    @State var noteAnchor: ParagraphAnchor?
    @State var noteEditingExisting: Annotation?
    @State var noteText: String = ""
    @State var viewingNote: Annotation?
    @State var showAnnotationsSheet = false

    /// Bumped on every annotation mutation. SwiftData relationship reads
    /// (`book.annotations`) don't reliably trigger SwiftUI body re-evaluation
    /// in iOS 17, so we bind page identity to this counter and increment it
    /// from every insert/delete/edit. Without it, highlights/notes/bookmarks
    /// save correctly but the page surface doesn't refresh until the next
    /// app launch.
    @State var annotationRevision: Int = 0

    @AppStorage("inkandecho.paginated") var paginated: Bool = true
    @AppStorage(AppSettings.readAlongModeKey) var readAlongModeRaw: String = AppSettings.initialReadAlongModeRaw()
    /// Three-way read-along mode (off / word / sentence). Replaces the old
    /// wordHighlighting bool; `initialReadAlongModeRaw` migrates it.
    var readAlongMode: ReadAlongMode { ReadAlongMode(rawValue: readAlongModeRaw) ?? .off }
    /// When on, opening a different audiobook leaves the current one playing
    /// in the background instead of switching. See `AudioCoordinator`.
    @AppStorage(AppSettings.backgroundAudioKey) var backgroundAudioEnabled: Bool = false
    @AppStorage(AppSettings.animationsEnabledKey) var animationsEnabled: Bool = true
    /// Aa ladder step. `BodyTextMetrics` reads the same key — this property
    /// exists so the reader can observe changes and re-paginate.
    @AppStorage(AppSettings.typographyStepKey) var typographyStep: Int = BodyTextMetrics.defaultStep
    @State var showTypographyPopover = false
    @State var currentPageIndex: Int = 0
    @State var sidebarTab: SidebarTab = .chapters
    @FocusState var pageFocused: Bool

    #if os(iOS)
    @State var iosSidebarVisible: Bool = false
    @State var iosShowChapterSheet: Bool = false
    @State var iosShowAudioSheet: Bool = false
    @State var iosShowSettings: Bool = false
    /// Confirmation surfaced when the back button is tapped while
    /// alignment is running — the job will continue in the background
    /// either way, but the prompt is the only place the user learns that.
    @State var iosShowLeaveAlignmentConfirm: Bool = false
    /// iPhone ambient mode: when true, the header + audio bar slide off so
    /// the page is the only thing on screen. Tap the page to toggle.
    @State var iosChromeHidden: Bool = false
    /// Filled by `PageCurlReaderContainer.makeUIViewController` so the
    /// SwiftUI tap zones can request an animated page flip (left half →
    /// back, right half → forward). The container clears `nil` checks
    /// before invoking, so transient nil during reconfigure is safe.
    @State var iosFlipController: ((Bool) -> Void)? = nil
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dismiss) var iosDismiss
    #endif

    /// Stored on an `@Observable` class so writes invalidate only the views
    /// that actually read `current` (the visible `ParagraphRow`s) — not
    /// `ReaderView.body`, which would otherwise rebuild the entire reader
    /// (PVC, audio bar, scroll view) on every word change during aligned
    /// audio playback.
    @State var activeWordTracker = ActiveWordTracker()
    /// Read-along page-follow bookkeeping. `drivenPage` is the page the
    /// narration-follow last set, so a `currentPageIndex` change to anything
    /// else reads as a manual turn and suspends follow briefly. A plain class
    /// in `@State` (same pattern as `wordLayoutCache`): nothing in `body`
    /// reads these, so writes — which arrive per touch-move event from the
    /// scroll-suspension gesture — must not invalidate the view tree.
    @State var followState = FollowState()
    @State var activeScrollParagraph: Int?
    @State var lastProgressSaveAt: Date?

    /// Pre-filtered + pre-sorted anchors per segment. Built once when the
    /// alignment map loads (or changes) and looked up by segment ID in
    /// O(1). The previous code re-filtered the *entire* `map.words` list
    /// (10s of thousands of entries on a long audiobook) every audio tick
    /// — 10 Hz × O(N) blocked the main thread enough to freeze playback.
    @State var anchorsBySegment: [String: [WordAnchor]] = [:]
    /// Monotonic token for `applyAlignmentMap`: the off-main index build of
    /// a superseded apply must not clobber its successor's state.
    @State var alignmentApplyGeneration = 0
    /// Every book word with its narration start time, flattened across all
    /// chapters and time-sorted. The read-along highlight binary-searches this.
    @State var denseWords: [DenseWord] = []
    /// Chapters whose matched fraction fell under the rough threshold:
    /// word highlighting is disabled there (honest no-highlight beats
    /// confidently wrong) and the chapter drawer shows a warning dot.
    @State var roughSegments: Set<String> = []
    /// Memoized word→paragraph / word→page tables for the current chapter and
    /// pagination budget. A plain class held in `@State` on purpose: refreshing
    /// it is invisible to SwiftUI (it's a derived cache, not view state), so it
    /// can rebuild during body evaluation — the DEBUG HUD consults it there —
    /// without illegal state writes, and narration-follow can consult it per
    /// word change without re-rendering the reader.
    @State var wordLayoutCache = SegmentWordLayoutCache()
    /// True while `restoreProgress` is mid-flight. Suppresses the
    /// `selectedSegmentID → currentPageIndex = 0` reset so the restored
    /// page index survives the chapter assignment.
    @State var isRestoringProgress: Bool = false

    /// Cached per-chapter page counts at the current word budget. Used by
    /// the page-curl containers (UIPageViewController.pageCurl on iOS,
    /// NSPageController.book on macOS) to expose a flat 0..<total page
    /// index. Recomputed on segments load and any size-class change.
    @State var flatPageBoundaries: [(segmentID: String, count: Int)] = []
    @State var flatBoundariesBudget: Int = 0
    /// Whether the flat boundaries were paginated for a two-page spread.
    /// This is the mode the curl is REALLY in — follow's spread-visibility
    /// math keys off it rather than any layout-path-local flag.
    @State var flatBoundariesUseSpread: Bool = false
    /// Live pixel size of one page surface, reported by the curl container.
    /// Drives measured-height pagination; `.zero` until the first layout
    /// (paginator falls back to the word budget meanwhile).
    @State var readerPageArea: CGSize = .zero
    /// Geometry signature the flat boundaries were paginated at. A change
    /// (rotation, keyboard inset) invalidates page indices the same way a
    /// budget change does.
    @State var flatBoundariesAreaKey: Int = 0
    /// First word of the current page, captured under the OLD geometry the
    /// instant before it changes, so the reading position survives a
    /// re-pagination. Consumed once by `recomputeFlatPageBoundaries`.
    @State var pendingAnchorWord: Int?
    /// Memoized measured paginations, shared by page building, the read-along
    /// lookup, and the flat-boundary count so a chapter is measured once per
    /// geometry rather than on every page flip.
    @State var paginationCache = PaginationCache()

    var body: some View {
        applyAlertsAndSheets(to: readerEventLayer)
    }

    /// Layout plus the event/watcher half of the reader's modifier chain.
    /// Alerts, sheets, and the toolbar apply in `applyAlertsAndSheets` —
    /// the full chain in one expression exceeds the type-checker's budget.
    private var readerEventLayer: some View {
        readerLayout
            .background(Theme.canvas)
            .navigationTitle(book.title)
        .background {
            // Engine ticks `currentTime` at 30 Hz; isolating the read
            // here keeps it out of `ReaderView.body`, which would
            // otherwise become a dependent of `currentTime` and re-eval
            // the entire reader (breaking SwiftUI Menu state + gestures
            // during playback).
            AudioTimeWatcher(engine: engine) {
                refreshActiveWord()
                saveProgressIfNeeded()
            }
        }
        .onChange(of: selectedSegmentID) { _, _ in
            // This handler used to live on the long-dead `pageContent` view,
            // which meant it never registered: the restore flag latched true
            // forever (permanently disabling narration-follow) and chapter
            // picks kept the previous chapter's page index, landing the
            // reader mid-chapter and persisting that corrupted position.
            if isRestoringProgress {
                // Restore / narration-follow / cross-chapter curl set the
                // index deliberately; consume the token and keep it.
                isRestoringProgress = false
            } else {
                // User-driven chapter switch: start at the first page, and
                // back narration-follow off briefly — same contract as a
                // manual page turn, or follow would yank the user straight
                // back to the narrated chapter.
                currentPageIndex = 0
                followState.suspendedUntil = Date().addingTimeInterval(4)
            }
            refreshActiveWord()
            saveProgressIfNeeded(force: true)
        }
        .onChange(of: currentPageIndex) { _, newValue in
            if newValue == followState.drivenPage {
                // Our own narration-follow turn arriving. Consume the token so
                // a later MANUAL turn onto this same page isn't mistaken for
                // follow and left unsuspended.
                followState.drivenPage = nil
            } else {
                // A turn we didn't drive — the user flipped the page. Back off
                // narration-follow briefly so we don't yank them back.
                followState.suspendedUntil = Date().addingTimeInterval(4)
            }
            saveProgressIfNeeded(force: true)
        }
        .onChange(of: alignment.lastFinishedBookID) { _, finished in
            // Coordinator just finished a job for THIS book — reload the
            // alignment map from disk so anchors light up immediately.
            // Skip otherwise so jobs running for a different book don't
            // clobber our state.
            guard finished == book.id else { return }
            reloadAlignmentAfterCompletion()
        }
        .onChange(of: typographyStep) { _, _ in
            // Capture the reading position under the OUTGOING typography:
            // the layout cache still holds the old tables (wordLayout(for:)
            // would rebuild them keyed to the new step). Then drop every
            // pagination and recompute — the word-anchor remap in
            // recomputeFlatPageBoundaries restores the page.
            pendingAnchorWord = wordLayoutCache.startWord(ofPage: currentPageIndex)
            paginationCache.invalidateAll()
            recomputeFlatPageBoundaries(useSpread: flatBoundariesUseSpread)
        }
        .onChange(of: alignment.partialRevision) { _, _ in
            // A partial map landed for the running job. Swap it in (only
            // when the job is THIS book's) so read-along and tap-to-play go
            // live in already-transcribed chapters mid-alignment.
            guard alignment.isRunning(for: book.id),
                  let partial = alignment.partialMap else { return }
            Task { await applyAlignmentMap(partial) }
        }
        .onDisappear {
            saveProgressIfNeeded(force: true)
            // The engine is shared and app-owned now: leave playback running
            // so it continues in the library (the mini-player + lock screen
            // drive it). No pause-on-pop.
        }
        .task(id: book.id) {
            await loadEverything()
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: audioContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleAudioPicked(result)
        }
    }

    /// Alert / sheet / toolbar half of the reader's modifier chain (see
    /// `readerEventLayer`).
    private func applyAlertsAndSheets(to content: some View) -> some View {
        content
        .alert("Audio attach failed", isPresented: Binding(
            get: { attachError != nil },
            set: { if !$0 { attachError = nil } }
        )) {
            Button("OK", role: .cancel) { attachError = nil }
        } message: {
            Text(attachError ?? "")
        }
        .alert(
            "Stitch \(pendingAudioParts?.count ?? 0) files into one audiobook?",
            isPresented: Binding(
                get: { pendingAudioParts != nil },
                set: { if !$0 { pendingAudioParts = nil } }
            ),
            presenting: pendingAudioParts
        ) { parts in
            Button("Stitch in this order") {
                pendingAudioParts = nil
                attachAudio(parts)
            }
            Button("Cancel", role: .cancel) { pendingAudioParts = nil }
        } message: { parts in
            Text(parts.enumerated()
                .map { "\($0.offset + 1). \($0.element.lastPathComponent)" }
                .joined(separator: "\n"))
        }
        .alert("Alignment failed", isPresented: Binding(
            get: { alignmentError != nil },
            set: { if !$0 { alignment.dismissError() } }
        )) {
            Button("OK", role: .cancel) { alignment.dismissError() }
        } message: {
            Text(alignmentError ?? "")
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { persistError != nil },
            set: { if !$0 { persistError = nil } }
        )) {
            Button("OK", role: .cancel) { persistError = nil }
        } message: {
            Text(persistError ?? "")
        }
        .alert(noteEditingExisting == nil ? "Add Note" : "Edit Note", isPresented: Binding(
            get: { noteAnchor != nil || noteEditingExisting != nil },
            set: { if !$0 { noteAnchor = nil; noteEditingExisting = nil; noteText = "" } }
        )) {
            TextField("Your note", text: $noteText)
            Button("Save") {
                saveNote()
            }
            Button("Cancel", role: .cancel) {
                noteAnchor = nil
                noteEditingExisting = nil
                noteText = ""
            }
        }
        .sheet(item: $viewingNote) { annotation in
            noteViewSheet(for: annotation)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    paginated.toggle()
                } label: {
                    Label(paginated ? "Scroll" : "Paginate",
                          systemImage: paginated ? "scroll" : "book.pages")
                }
                .help(paginated ? "Switch to scroll mode" : "Switch to paginated mode")
            }
            // Aa (iPad / Catalyst chrome; the phone header has its own).
            ToolbarItem(placement: .primaryAction) {
                typographyButton
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAnnotationsSheet = true
                } label: {
                    Label("Annotations", systemImage: "list.bullet.indent")
                }
            }
        }
        .sheet(isPresented: $showAnnotationsSheet) {
            AnnotationsListSheet(
                book: book,
                segments: segments,
                onJump: { annotation in
                    jump(to: annotation)
                    showAnnotationsSheet = false
                },
                onDismiss: { showAnnotationsSheet = false }
            )
        }
    }

    /// Aa entry point: pops the shared `TypographyStepper`. One `@State`
    /// backs both chrome placements (toolbar on iPad/Catalyst, phone
    /// header) — only one is ever on screen.
    var typographyButton: some View {
        Button {
            showTypographyPopover = true
        } label: {
            Label("Text size", systemImage: "textformat.size")
        }
        .popover(isPresented: $showTypographyPopover) {
            TypographyStepper()
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Annotation helpers

    /// Every annotation/progress write funnels through here. Saving with
    /// `try?` meant a failing store silently discarded highlights, notes,
    /// and positions while the UI confirmed them. One alert per failure
    /// episode (`persistError` holds until dismissed).
    func saveOrReport() {
        do {
            try modelContext.save()
        } catch {
            if persistError == nil {
                persistError = error.localizedDescription
            }
        }
    }

    /// Jump the reader to an annotation's paragraph — chapter AND position.
    /// Setting only the chapter landed cross-chapter jumps on page 0 and made
    /// same-chapter jumps a silent no-op (the sheet just closed).
    func jump(to annotation: Annotation) {
        guard let loc = annotation.paragraphLocation,
              let segment = segments.first(where: { $0.id == loc.segmentID }) else { return }
        let layout = wordLayout(for: segment)
        if loc.segmentID != selectedSegmentID {
            // Suppress the chapter-change page reset for the same reason
            // restoreProgress does: we're about to set the page deliberately.
            isRestoringProgress = true
            selectedSegmentID = loc.segmentID
        }
        if paginated {
            if let word = layout.firstWord(ofParagraph: loc.paragraphIndex),
               let page = layout.pageIndex(forWord: word) {
                currentPageIndex = page
            } else {
                currentPageIndex = 0
            }
        } else {
            activeScrollParagraph = loc.paragraphIndex
        }
    }

    /// Annotations that should render on a given paragraph. Includes both
    /// paragraph-level (`<seg>#p<n>`) and word-level (`<seg>#p<n>w<m>`)
    /// rows — `ParagraphRow` reads both and renders them differently
    /// (a pill behind the whole paragraph vs. a tint behind a single word).
    func annotations(forSegment segmentID: String, paragraph: Int) -> [Annotation] {
        let paragraphLocator = Annotation.locator(segmentID: segmentID, paragraphIndex: paragraph)
        let wordPrefix = paragraphLocator + "w"
        return book.annotations.filter {
            $0.cfiStart == paragraphLocator || $0.cfiStart.hasPrefix(wordPrefix)
        }
    }

    func toggleHighlight(segmentID: String, paragraphIndex: Int, color: AnnotationColor) {
        let locator = Annotation.locator(segmentID: segmentID, paragraphIndex: paragraphIndex)
        if let existing = book.annotations.first(where: { $0.cfiStart == locator && $0.kind == .highlight }) {
            if existing.color == color {
                modelContext.delete(existing)
            } else {
                existing.color = color
            }
        } else {
            let annotation = Annotation(
                book: book,
                cfiStart: locator,
                cfiEnd: locator,
                kind: .highlight,
                color: color
            )
            insertAnnotation(annotation)
        }
        saveOrReport()
        annotationRevision &+= 1
    }

    func toggleBookmark(segmentID: String, paragraphIndex: Int) {
        let locator = Annotation.locator(segmentID: segmentID, paragraphIndex: paragraphIndex)
        if let existing = book.annotations.first(where: { $0.cfiStart == locator && $0.kind == .bookmark }) {
            modelContext.delete(existing)
        } else {
            let annotation = Annotation(
                book: book,
                cfiStart: locator,
                cfiEnd: locator,
                kind: .bookmark
            )
            insertAnnotation(annotation)
        }
        saveOrReport()
        annotationRevision &+= 1
    }

    /// Insert an annotation and make sure it's reflected in
    /// `book.annotations` immediately. Setting `annotation.book = book` in
    /// the init is supposed to maintain the inverse relationship, but on
    /// iOS 17 SwiftData doesn't always push the new object into the
    /// parent's collection until the next change-tracking cycle. The
    /// explicit append guarantees the next `book.annotations` read — which
    /// drives the page's `highlightBackground` and margin glyphs — sees
    /// the new annotation right away.
    private func insertAnnotation(_ annotation: Annotation) {
        modelContext.insert(annotation)
        if !book.annotations.contains(where: { $0.id == annotation.id }) {
            book.annotations.append(annotation)
        }
    }

    /// Tap → toggle a word-level highlight (amber by default). Drag/paint
    /// goes through `paintWordHighlight`, which only adds.
    func toggleWordHighlight(segmentID: String, paragraphIndex: Int, wordIndex: Int) {
        let locator = Annotation.locator(
            segmentID: segmentID,
            paragraphIndex: paragraphIndex,
            wordIndex: wordIndex
        )
        if let existing = book.annotations.first(where: {
            $0.cfiStart == locator && $0.kind == .highlight
        }) {
            modelContext.delete(existing)
        } else {
            insertAnnotation(Annotation(
                book: book,
                cfiStart: locator,
                cfiEnd: locator,
                kind: .highlight,
                color: AppSettings.defaultHighlightColor()
            ))
        }
        saveOrReport()
        annotationRevision &+= 1
    }

    /// Drag-paint: insert a word highlight if absent; no-op if it already
    /// exists. Toggling mid-drag would erase highlights as the finger crossed
    /// them, which reads as a glitch.
    func paintWordHighlight(segmentID: String, paragraphIndex: Int, wordIndex: Int) {
        let locator = Annotation.locator(
            segmentID: segmentID,
            paragraphIndex: paragraphIndex,
            wordIndex: wordIndex
        )
        if book.annotations.contains(where: { $0.cfiStart == locator && $0.kind == .highlight }) {
            return
        }
        insertAnnotation(Annotation(
            book: book,
            cfiStart: locator,
            cfiEnd: locator,
            kind: .highlight,
            color: AppSettings.defaultHighlightColor()
        ))
        saveOrReport()
        // No annotationRevision bump here: paint fires mid-drag, and the
        // bump re-identifies the page-curl container, destroying the text
        // view under the user's finger. The row's `onPaintEnded` bumps once
        // when the gesture finishes; live feedback during the drag comes
        // from the text view's transient tint.
    }

    func saveNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            noteAnchor = nil
            noteEditingExisting = nil
            noteText = ""
        }
        if let existing = noteEditingExisting {
            if trimmed.isEmpty {
                modelContext.delete(existing)
            } else {
                existing.note = trimmed
            }
        } else if let anchor = noteAnchor, !trimmed.isEmpty {
            let locator = Annotation.locator(segmentID: anchor.segmentID, paragraphIndex: anchor.paragraphIndex)
            let annotation = Annotation(
                book: book,
                cfiStart: locator,
                cfiEnd: locator,
                kind: .note,
                note: trimmed
            )
            insertAnnotation(annotation)
        }
        saveOrReport()
        annotationRevision &+= 1
    }

    @ViewBuilder
    func noteViewSheet(for annotation: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Note")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Theme.ink)
            Text(annotation.note)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Button("Edit") {
                    noteEditingExisting = annotation
                    noteText = annotation.note
                    viewingNote = nil
                }
                Button(role: .destructive) {
                    modelContext.delete(annotation)
                    saveOrReport()
                    annotationRevision &+= 1
                    viewingNote = nil
                } label: {
                    Text("Delete")
                }
                Spacer()
                Button("Close") {
                    viewingNote = nil
                }
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 200)
        .background(Theme.canvas)
    }

    // MARK: - Layout

    var readerLayout: some View {
        iosReaderLayout
    }

    // MARK: - Sidebar

    var chapterList: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().background(Theme.hairline)
            sidebarTabBar
            Divider().background(Theme.hairline)
            sidebarTabContent()
            Divider().background(Theme.hairline)
            sidebarFooter
        }
        .background(Theme.canvasCool)
    }

    var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    var sidebarTabBar: some View {
        HStack(spacing: 4) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                Button {
                    sidebarTab = tab
                } label: {
                    Text(tab.rawValue.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(sidebarTab == tab ? Theme.ink : Theme.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(sidebarTab == tab ? Theme.accent : Color.clear)
                                .frame(height: 2)
                                .offset(y: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
    }

    /// `onNavigate` fires after a row navigates the reader. The phone drawer
    /// passes a dismiss closure so a USER tap closes the sheet; the iPad /
    /// macOS persistent sidebar passes nil. This is provenance-based on
    /// purpose: the old `.onChange(of: selectedSegmentID)` dismissal also
    /// fired on narration-follow chapter crosses, closing the contents sheet
    /// under the reader's finger.
    @ViewBuilder
    func sidebarTabContent(onNavigate: (() -> Void)? = nil) -> some View {
        switch sidebarTab {
        case .chapters: chaptersTab(onNavigate: onNavigate)
        case .bookmarks: bookmarksTab(onNavigate: onNavigate)
        case .notes: notesTab(onNavigate: onNavigate)
        }
    }

    func chaptersTab(onNavigate: (() -> Void)?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    chapterRow(segment: segment, index: index, onNavigate: onNavigate)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    func chapterRow(segment: TextSegment, index: Int, onNavigate: (() -> Void)? = nil) -> some View {
        let isSelected = selectedSegmentID == segment.id
        return Button {
            selectedSegmentID = segment.id
            onNavigate?()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(romanNumeral(index + 1))
                    .font(.system(size: 11, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 24, alignment: .trailing)
                Text(chapterTitle(segment, index: index))
                    .font(.system(size: 13, design: .serif))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSoft)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if roughSegments.contains(segment.id) {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Rough audio sync in this chapter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.accent.opacity(0.10))
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent)
                        .frame(width: 2.5, height: 16)
                        .padding(.leading, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func bookmarksTab(onNavigate: (() -> Void)?) -> some View {
        annotationListTab(
            kind: .bookmark,
            emptyIcon: "bookmark",
            emptyText: "No bookmarks yet",
            onNavigate: onNavigate
        )
    }

    func notesTab(onNavigate: (() -> Void)?) -> some View {
        annotationListTab(
            kind: .note,
            emptyIcon: "text.bubble",
            emptyText: "No notes yet",
            onNavigate: onNavigate
        )
    }

    func annotationListTab(kind: AnnotationKind, emptyIcon: String, emptyText: String, onNavigate: (() -> Void)? = nil) -> some View {
        let items = sortedAnnotationsForSidebar(kind: kind)
        return Group {
            if items.isEmpty {
                emptySidebarState(icon: emptyIcon, text: emptyText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { annotation in
                            sidebarAnnotationRow(annotation, onNavigate: onNavigate)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    func emptySidebarState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Theme.inkMuted)
            Text(text)
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    func sidebarAnnotationRow(_ annotation: Annotation, onNavigate: (() -> Void)? = nil) -> some View {
        Button {
            // Route through `jump(to:)` so the tap lands on the annotation's
            // paragraph, not page 0 of its chapter (the same fix the
            // all-annotations sheet got).
            jump(to: annotation)
            onNavigate?()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(sidebarAnnotationChapterLabel(annotation))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.inkMuted)
                Text(sidebarAnnotationSnippet(annotation))
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func sortedAnnotationsForSidebar(kind: AnnotationKind) -> [Annotation] {
        let segmentOrder = Dictionary(segments.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return book.annotations
            .filter { $0.kind == kind }
            .sorted { a, b in
                let aLoc = a.paragraphLocation
                let bLoc = b.paragraphLocation
                let aOrder = aLoc.flatMap { segmentOrder[$0.segmentID] } ?? Int.max
                let bOrder = bLoc.flatMap { segmentOrder[$0.segmentID] } ?? Int.max
                if aOrder != bOrder { return aOrder < bOrder }
                return (aLoc?.paragraphIndex ?? 0) < (bLoc?.paragraphIndex ?? 0)
            }
    }

    func sidebarAnnotationChapterLabel(_ annotation: Annotation) -> String {
        guard let loc = annotation.paragraphLocation,
              let idx = segments.firstIndex(where: { $0.id == loc.segmentID }) else {
            return "Unknown"
        }
        return "Chapter \(idx + 1) · ¶\(loc.paragraphIndex + 1)"
    }

    func sidebarAnnotationSnippet(_ annotation: Annotation) -> String {
        if annotation.kind == .note, !annotation.note.isEmpty {
            return annotation.note
        }
        guard let loc = annotation.paragraphLocation,
              let segment = segments.first(where: { $0.id == loc.segmentID }) else {
            return "—"
        }
        let paras = paragraphs(of: segment.text)
        guard loc.paragraphIndex < paras.count else { return "—" }
        return paras[loc.paragraphIndex]
    }

    var sidebarFooter: some View {
        HStack {
            Text(sidebarFooterLeft)
            Spacer()
            Text(sidebarFooterRight)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    var sidebarFooterLeft: String {
        guard !segments.isEmpty else { return "—" }
        guard let segmentIndex = selectedSegmentID
            .flatMap({ id in segments.firstIndex(where: { $0.id == id }) }) else {
            return "chapter — of \(segments.count)"
        }
        return "chapter \(segmentIndex + 1) of \(segments.count)"
    }

    var sidebarFooterRight: String {
        guard !segments.isEmpty,
              let segmentIndex = selectedSegmentID
                .flatMap({ id in segments.firstIndex(where: { $0.id == id }) }) else {
            return ""
        }
        let percent = Int((Double(segmentIndex + 1) / Double(segments.count)) * 100)
        return "\(percent)%"
    }

    func romanNumeral(_ n: Int) -> String {
        let pairs: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var num = n
        var result = ""
        for (value, numeral) in pairs {
            while num >= value {
                result += numeral
                num -= value
            }
        }
        return result
    }

    // MARK: - Page

    @ViewBuilder
    func scrollView(segment: TextSegment) -> some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 18) {
                    chapterHeader(for: segment)
                    ForEach(Array(paragraphs(of: segment.text).enumerated()), id: \.offset) { idx, para in
                        paragraphRow(text: para, segmentID: segment.id, paragraphIndex: idx)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.vertical, 48)
                .id("top")
                .onChange(of: selectedSegmentID) { _, _ in
                    proxy.scrollTo("top", anchor: .top)
                }
                .onChange(of: activeScrollParagraph) { _, p in
                    guard let p else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(p, anchor: .center)
                    }
                }
            }
        }
        // Scroll mode's analogue of the manual page turn: any touch-drag means
        // the user took the wheel, so back narration-follow off briefly instead
        // of re-centering the narrated paragraph mid-scroll. `simultaneous` so
        // it observes the scroll without competing with it.
        .simultaneousGesture(
            DragGesture().onChanged { _ in
                followState.suspendedUntil = Date().addingTimeInterval(4)
            }
        )
    }



    /// One page of the spread: chapter running header, body paragraphs,
    /// page-number footer. No background or border — those sit on the
    /// spread container so the two pages share one continuous frame.
    @ViewBuilder
    func pageSurface(segment: TextSegment, page: PageContent, pageIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            chapterHeader(for: segment)
                .padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(page.paragraphs.enumerated()), id: \.element.id) { idx, para in
                    paragraphRow(
                        text: para.text,
                        segmentID: segment.id,
                        paragraphIndex: para.originalIndex,
                        chunkWordOffset: para.wordOffsetWithinParagraph
                    )
                    .padding(.leading, idx == 0 ? 0 : 16)
                }
            }
            Spacer(minLength: 0)
            Text("\(pageIndex + 1)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: pageColumnMaxWidth, alignment: .leading)
        .padding(.horizontal, pageHorizontalPadding)
        .padding(.top, pageVerticalPadding)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Per-platform column width and gutter for `pageSurface`. iPhone gets a
    /// snug gutter so the body column isn't crushed; iPad and Mac share
    /// the same generous book margin so a reader moving between the two
    /// sees an identical page.
    var pageColumnMaxWidth: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? .infinity : 460
        #else
        return 460
        #endif
    }

    var pageHorizontalPadding: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 24 : 56
        #else
        return 56
        #endif
    }

    var pageVerticalPadding: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 24 : 48
        #else
        return 48
        #endif
    }

    /// Words allowed on a page before `pageBreaks` closes the page. The
    /// values are tuned per device class so a typical paragraph fits
    /// without overflow given the column width and 17pt-on-25pt body
    /// metrics. The 240-word single-mode budget the macOS reader used to
    /// ship was right for a wide window but caused iPhone overflow with
    /// long paragraphs — text would get clipped at the bottom with an
    /// ellipsis and the continuation never appeared on the next page.
    func wordsBudget(useSpread: Bool) -> Int {
        // Tuned downward after empirical iPad / iPhone testing — the
        // previous values let chunks slip past the visible page height
        // because the word-count model under-predicts line count when
        // paragraphs run long. Conservative budgets here mean the splitter
        // always closes a chunk before SwiftUI clips with an ellipsis.
        // macOS shares the iPad single-page budget so a reader moving
        // between the two sees the same page breaks.
        let base: Int
        if useSpread {
            base = 95
        } else {
            #if os(iOS)
            base = horizontalSizeClass == .compact ? 120 : 170
            #else
            base = 170
            #endif
        }
        // The budgets above were tuned at the 17 pt default. Page capacity
        // falls with the inverse square of the body size (fewer words per
        // line AND fewer lines per page) — the spread path has no measured
        // pagination, so it depends on this scaling to avoid clipping at
        // large sizes.
        let scale = pow(17.0 / Double(BodyTextMetrics.bodySize), 2)
        return max(20, Int((Double(base) * scale).rounded()))
    }

    /// Stable integer signature of the current page-surface size, used to key
    /// caches and detect when a re-pagination is needed.
    var pageAreaKey: Int {
        Int(readerPageArea.width.rounded()) &* 100_003 &+ Int(readerPageArea.height.rounded())
    }

    #if os(iOS)
    /// Translate the live page-surface size into a measured-pagination budget,
    /// matching `pageSurface`'s layout exactly: column = page width minus the
    /// horizontal book margin (capped on iPad), text width = column minus the
    /// row's margin/actions chrome (and the indent for non-first rows), and the
    /// paragraph block = page height minus the header, page number, paddings,
    /// and a one-line safety margin that absorbs measurement drift and the
    /// occasional highlight pill. Returns nil before the first layout or when
    /// the surface is too small to paginate sensibly (falls back to the word
    /// budget then).
    func measuredPageGeometry() -> MeasuredPageGeometry? {
        let area = readerPageArea
        guard area.width > 1, area.height > 1 else { return nil }

        let column = min(pageColumnMaxWidth, area.width - 2 * pageHorizontalPadding)
        // ParagraphRow HStack: margin(16) + spacing(8) + text + spacing(8) + actions(22).
        let rowChrome: CGFloat = 16 + 8 + 8 + 22
        let indent: CGFloat = 16   // pageSurface adds this to every non-first row
        let firstWidth = column - rowChrome
        let bodyWidth = column - rowChrome - indent
        guard firstWidth > 40, bodyWidth > 40 else { return nil }

        let lineUnit = BodyTextMetrics.lineUnit
        // chapterHeader (10pt semibold, one line) + its 24pt bottom padding.
        let headerBlock = ceil(UIFont.systemFont(ofSize: 10, weight: .semibold).lineHeight) + 24
        // Bottom-pinned page number (caption2 ≈ 11pt, one line).
        let pageNumber = ceil(UIFont.systemFont(ofSize: 11).lineHeight)
        let available = area.height
            - pageVerticalPadding   // pageSurface top padding
            - 40                    // pageSurface bottom padding
            - headerBlock
            - pageNumber
            - lineUnit              // one-line safety margin
        guard available > 3 * lineUnit else { return nil }

        return MeasuredPageGeometry(
            firstRowWidth: firstWidth,
            bodyRowWidth: bodyWidth,
            availableHeight: available,
            paragraphSpacing: 16
        )
    }
    #endif

    /// The single pagination entry point. Uses measured-height pagination on
    /// the iOS single-page surface once its size is known; otherwise (spread
    /// mode, macOS, or pre-layout) falls back to the word budget. All three
    /// consumers — page building, the read-along word→page map, and the flat
    /// page count — route through here so they always agree, and results are
    /// memoized per chapter + geometry.
    func paginatedPages(for segment: TextSegment) -> [PageContent] {
        // Both keys carry the Aa step: measured pagination depends on it via
        // the metrics, and the word budget only via a lossy rounding — two
        // steps could collide on the same budget.
        let step = BodyTextMetrics.currentStep
        #if os(iOS)
        if !flatBoundariesUseSpread, let geometry = measuredPageGeometry() {
            return paginationCache.pages(forKey: "m|\(segment.id)|\(pageAreaKey)|t\(step)") {
                paginateByMeasuredHeight(
                    paragraphs: paragraphs(of: segment.text),
                    geometry: geometry,
                    lineUnit: BodyTextMetrics.lineUnit,
                    measure: { BodyTextMetrics.measuredHeight($0, width: $1) }
                )
            }
        }
        #endif
        let budget = flatBoundariesBudget > 0 ? flatBoundariesBudget : wordsBudget(useSpread: flatBoundariesUseSpread)
        return paginationCache.pages(forKey: "w|\(segment.id)|\(budget)|\(flatBoundariesUseSpread)|t\(step)") {
            pageBreaks(for: segment.text, wordsPerPage: budget)
        }
    }

    @ViewBuilder
    func chapterHeader(for segment: TextSegment) -> some View {
        Text(displayChapterLabel(for: segment))
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.5)
            .foregroundStyle(Theme.inkMuted)
    }

    @ViewBuilder
    func paragraphRow(text: String, segmentID: String, paragraphIndex: Int, chunkWordOffset: Int = 0) -> some View {
        // Offsets must come from the segment this row RENDERS, not the
        // selected one: the page-curl prefetches the adjacent chapter's
        // page while `selectedSegmentID` still points at the old chapter,
        // and offsets summed over the wrong chapter's paragraphs broke
        // read-along highlighting and tap-to-seek on every chapter's
        // entry page.
        let rowSegment = segments.first(where: { $0.id == segmentID })
        let paragraphTexts = rowSegment.map { paragraphs(of: $0.text) } ?? []
        let paragraphWordOffset = wordOffsetForParagraph(paragraphIndex, paragraphs: paragraphTexts)
        // For split paragraphs the displayed text is a chunk; word indices
        // need to count from the chunk's start, not the paragraph's.
        let wordOffset = paragraphWordOffset + chunkWordOffset

        ParagraphRow(
            text: text,
            paragraphIndex: paragraphIndex,
            wordOffset: wordOffset,
            chunkWordOffset: chunkWordOffset,
            seekEnabled: alignmentMap != nil,
            segmentID: segmentID,
            activeWordTracker: activeWordTracker,
            highlightMode: rowHighlightMode(for: segmentID),
            annotations: annotations(forSegment: segmentID, paragraph: paragraphIndex),
            onPlayFromWord: { localWordIdx in
                seekToWord(segmentID: segmentID, wordOffset: wordOffset, localIndex: localWordIdx)
            },
            onHighlight: { color in
                toggleHighlight(segmentID: segmentID, paragraphIndex: paragraphIndex, color: color)
            },
            onBookmark: {
                toggleBookmark(segmentID: segmentID, paragraphIndex: paragraphIndex)
            },
            onAddNote: {
                noteAnchor = ParagraphAnchor(segmentID: segmentID, paragraphIndex: paragraphIndex)
                noteEditingExisting = nil
                noteText = ""
            },
            onTapNote: { annotation in
                viewingNote = annotation
            },
            onDelete: { annotation in
                modelContext.delete(annotation)
                saveOrReport()
                annotationRevision &+= 1
            },
            // Word-highlight locators are PARAGRAPH-relative. The row hands
            // back chunk-local indices, so add the chunk offset before
            // storing — without it a highlight painted in chunk 2 of a split
            // paragraph persisted under the wrong word and lit up the same
            // ordinal in every chunk.
            onToggleWord: { localWordIdx in
                toggleWordHighlight(
                    segmentID: segmentID,
                    paragraphIndex: paragraphIndex,
                    wordIndex: chunkWordOffset + localWordIdx
                )
            },
            onPaintWord: { localWordIdx in
                paintWordHighlight(
                    segmentID: segmentID,
                    paragraphIndex: paragraphIndex,
                    wordIndex: chunkWordOffset + localWordIdx
                )
            },
            onPaintEnded: {
                // One canonical re-render per completed paint gesture. Doing
                // this per painted word changed the curl container's `.id`
                // mid-touch, tearing down the very text view the finger was
                // dragging in.
                annotationRevision &+= 1
            }
        )
    }

    /// Per-row read-along mode: the user's setting, degraded per chapter.
    /// Rough chapters (matched fraction under the threshold) never claim
    /// word precision — their times are mostly interpolation — but the
    /// sentence underline is coarse enough to stay honest, so word mode
    /// falls back to it there (the fallback the mismatch work deferred to
    /// sentence mode).
    func rowHighlightMode(for segmentID: String) -> HighlightMode {
        switch readAlongMode {
        case .off:      return .none
        case .sentence: return .sentence
        case .word:     return roughSegments.contains(segmentID) ? .sentence : .word
        }
    }

    func seekToWord(segmentID: String, wordOffset: Int, localIndex: Int) {
        guard let map = alignmentMap else {
            attachError = "Alignment map not loaded yet. Run Align first."
            return
        }
        let globalIdx = wordOffset + localIndex

        // Mid-alignment partial map: a word past the frontier has no dense
        // entry, and the sparse fallback would seek to the LAST aligned
        // chapter — maximally confusing. Say what's happening instead.
        if let frontier = partialFrontier,
           !partialCovers(segmentID: segmentID, wordIndex: globalIdx, map: map) {
            showSeekNotice("Not synced yet — aligned through \(frontierLabel(frontier)) so far.")
            return
        }

        // Dense per-word times (the same data the read-along highlight uses)
        // give the tapped word its own start. Falls through to the sparse
        // nearest-anchor path only for pre-dense maps.
        if let start = denseStart(segmentID: segmentID, wordIndex: globalIdx, map: map) {
            engine.seek(to: start)
            do {
                try engine.play()
            } catch {
                attachError = "Play failed after seek: \(error.localizedDescription)"
            }
            return
        }

        let anchor: WordAnchor
        let segWords = map.words.filter { $0.segmentId == segmentID }

        if !segWords.isEmpty {
            // Nearest anchor in the clicked chapter.
            if let preceding = segWords.filter({ $0.wordIndex <= globalIdx })
                                       .max(by: { $0.wordIndex < $1.wordIndex }) {
                anchor = preceding
            } else if let next = segWords.filter({ $0.wordIndex > globalIdx })
                                         .min(by: { $0.wordIndex < $1.wordIndex }) {
                anchor = next
            } else {
                attachError = "No usable alignment anchor near word #\(globalIdx)."
                return
            }
        } else if let fallback = nearestAnchorAcrossSegments(targetSegmentID: segmentID, map: map) {
            // Chapter has no anchors at all — fall back to the closest aligned
            // chapter. Common when greedy alignment got off-track partway through
            // a long audiobook.
            anchor = fallback
        } else {
            attachError = "No alignment anchors anywhere — try re-aligning."
            return
        }

        engine.seek(to: anchor.startSeconds)
        do {
            try engine.play()
        } catch {
            attachError = "Play failed after seek: \(error.localizedDescription)"
        }
    }

    /// Whether a partial map's dense table reaches the given word. Only
    /// meaningful while `partialFrontier` is non-nil — full maps clamp their
    /// tails, so every word is covered by construction.
    private func partialCovers(segmentID: String, wordIndex: Int, map: AlignmentMap) -> Bool {
        guard let seg = map.wordTimes.first(where: { $0.segmentId == segmentID }),
              let lastCovered = seg.wordIndices.last else { return false }
        return wordIndex <= lastCovered
    }

    /// "1h 12m" label for the partial-alignment frontier.
    func frontierLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    func showSeekNotice(_ message: String) {
        seekNotice = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if seekNotice == message { seekNotice = nil }
        }
    }

    /// Narration start time of a specific book word, from the dense
    /// per-word table. `wordIndices` is ascending within a chapter, so
    /// binary-search the largest entry ≤ the requested index (punctuation
    /// tokens are absent from the table; the preceding word is the right
    /// listen-from point for them).
    private func denseStart(segmentID: String, wordIndex: Int, map: AlignmentMap) -> Double? {
        guard let seg = map.wordTimes.first(where: { $0.segmentId == segmentID }),
              !seg.wordIndices.isEmpty, seg.wordIndices.count == seg.starts.count,
              wordIndex >= seg.wordIndices[0] else { return nil }
        var lo = 0, hi = seg.wordIndices.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if seg.wordIndices[mid] <= wordIndex {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return max(0, seg.starts[best])
    }

    func nearestAnchorAcrossSegments(targetSegmentID: String, map: AlignmentMap) -> WordAnchor? {
        guard let targetIndex = segments.firstIndex(where: { $0.id == targetSegmentID }) else {
            return nil
        }
        let coveredSegments = Set(map.words.map { $0.segmentId })

        // Spiral outward: try preceding chapters first (more useful — gives the
        // user the LAST anchor before their click), then following chapters.
        // Single-chapter books make maxRadius 0, and `1...0` traps.
        let maxRadius = max(targetIndex, segments.count - targetIndex - 1)
        guard maxRadius >= 1 else { return nil }
        for offset in 1...maxRadius {
            for direction in [-1, 1] {
                let idx = targetIndex + direction * offset
                guard idx >= 0, idx < segments.count else { continue }
                let candidateID = segments[idx].id
                guard coveredSegments.contains(candidateID) else { continue }

                let anchors = map.words.filter { $0.segmentId == candidateID }
                                       .sorted { $0.wordIndex < $1.wordIndex }
                guard let anchor = direction == -1 ? anchors.last : anchors.first else { continue }
                return anchor
            }
        }
        return nil
    }

    // MARK: - Word seek + active-word tracking

    func wordOffsetForParagraph(_ idx: Int, paragraphs: [String]) -> Int {
        var offset = 0
        for i in 0..<min(idx, paragraphs.count) {
            offset += tokenizeWords(paragraphs[i]).count
        }
        return offset
    }

    /// Lookup tables behind `paragraphIndex(forWordIndex:)` and
    /// `pageIndex(forWordIndex:)`, rebuilt only when the chapter or the flat
    /// pagination budget changes. Both lookups run per narrated-word change
    /// (and the DEBUG HUD's at 30 Hz) — re-tokenizing and re-paginating the
    /// whole chapter each call is exactly the main-thread stall the 10 Hz
    /// tick cap used to paper over.
    private func wordLayout(for segment: TextSegment) -> SegmentWordLayoutCache {
        let budget = flatBoundariesBudget > 0 ? flatBoundariesBudget : wordsBudget(useSpread: flatBoundariesUseSpread)
        // `pageAreaKey` is in the key so measured-mode page starts recompute
        // when the surface resizes (rotation / keyboard), not just on a budget
        // change; the Aa step for the same reason as the pagination cache.
        let key = "\(segment.id)|\(budget)|\(pageAreaKey)|\(segment.text.count)|t\(BodyTextMetrics.currentStep)"
        if wordLayoutCache.key != key {
            let paras = paragraphs(of: segment.text)
            var paragraphStarts: [Int] = []
            paragraphStarts.reserveCapacity(paras.count)
            var cumulative = 0
            for para in paras {
                paragraphStarts.append(cumulative)
                cumulative += tokenizeWords(para).count
            }
            let pageStarts = paginatedPages(for: segment).map { page in
                page.paragraphs.first.map { paragraphStarts[$0.originalIndex] + $0.wordOffsetWithinParagraph } ?? 0
            }
            wordLayoutCache.update(key: key, paragraphStarts: paragraphStarts, pageStarts: pageStarts)
        }
        return wordLayoutCache
    }

    /// Original-paragraph index (within the chapter) holding the chapter-global
    /// word `wordIndex`. Counted with `tokenizeWords` so it matches the offsets
    /// the highlight itself is keyed on.
    func paragraphIndex(forWordIndex wordIndex: Int, in segment: TextSegment) -> Int? {
        wordLayout(for: segment).paragraphIndex(forWord: wordIndex)
    }

    /// The flat-pagination page whose word range contains the chapter-global
    /// `wordIndex`, at the budget the page-curl's flat sequence paginates with.
    /// Word-exact: a long paragraph split across pages resolves to the page
    /// holding the word's own chunk, not the paragraph's first page.
    func pageIndex(forWordIndex wordIndex: Int, in segment: TextSegment) -> Int? {
        wordLayout(for: segment).pageIndex(forWord: wordIndex)
    }

    /// First chapter-global word index on the current page under the active
    /// pagination. Captured before a re-pagination so the reading position can
    /// be remapped onto the new page layout. (Internal so the iOS layout's
    /// page-size observer can reach it; `wordLayout` itself is private.)
    func currentPageFirstWord() -> Int? {
        guard let segment = currentSegment else { return nil }
        return wordLayout(for: segment).startWord(ofPage: currentPageIndex)
    }

    /// Keep the narrated word on screen while audio plays. Paginated: snap the
    /// curl to the page holding the active word. Scroll: center its paragraph.
    /// Gated so it never fights a manual turn, a drag, or a restore.
    func followNarration() {
        #if os(iOS)
        // Only follow when the engine is narrating THIS book — in background
        // mode it may be playing a different one, whose timeline says nothing
        // about this book's pages.
        guard audioIsThisBook else { return }
        guard readAlongMode != .off, engine.state == .playing else { return }
        guard !isRestoringProgress else { return }
        if let until = followState.suspendedUntil, Date() < until { return }
        guard let aw = activeWordTracker.current,
              let segment = currentSegment else { return }

        // Narration crossed into another chapter (`denseWords` is global, so
        // the active word already knows which one). Drive the chapter switch
        // the same way restore does — flag-suppressed so the chapter-change
        // handler doesn't reset the page we're about to set.
        if aw.segmentId != segment.id {
            guard let target = segments.first(where: { $0.id == aw.segmentId }) else { return }
            isRestoringProgress = true
            if paginated, flatTotalPages > 0 {
                let page = pageIndex(forWordIndex: aw.wordIndex, in: target) ?? 0
                followState.drivenPage = page
                selectedSegmentID = target.id
                currentPageIndex = page
            } else {
                selectedSegmentID = target.id
                activeScrollParagraph = paragraphIndex(forWordIndex: aw.wordIndex, in: target)
            }
            return
        }

        if paginated, flatTotalPages > 0 {
            guard let targetPage = pageIndex(forWordIndex: aw.wordIndex, in: segment) else { return }
            // Visibility is judged in the flat-global space the curl paginates
            // in — it pairs spreads as (global/2)*2, so a chapter starting on
            // an odd global page makes chapter-local pairing misjudge what's
            // actually on screen. `flatBoundariesUseSpread` is the mode the
            // flat sequence was actually built with — the curl's reality —
            // not a stale layout-path flag.
            let currentGlobal = flatGlobalIndex(segmentID: segment.id, pageIdx: currentPageIndex)
            let targetGlobal = flatGlobalIndex(segmentID: segment.id, pageIdx: targetPage)
            let left = (currentGlobal / 2) * 2
            let visible: Set<Int> = flatBoundariesUseSpread ? [left, left + 1] : [currentGlobal]
            guard !visible.contains(targetGlobal) else { return }
            followState.drivenPage = targetPage
            currentPageIndex = targetPage
        } else if let paraIdx = paragraphIndex(forWordIndex: aw.wordIndex, in: segment) {
            activeScrollParagraph = paraIdx
        }
        #endif
    }

    func refreshActiveWord() {
        // No highlight unless the engine is narrating THIS book — otherwise
        // `engine.currentTime` belongs to a different book's timeline.
        guard !denseWords.isEmpty, audioIsThisBook else {
            if activeWordTracker.current != nil { activeWordTracker.current = nil }
            return
        }
        // Subtract output latency (scaled by rate) so the highlight matches what
        // is audible, not the latest rendered sample.
        let t = max(0, engine.currentTime - engine.outputLatency * Double(engine.rate))
        // Pre-roll (intro music, narrator credits): nothing is being read yet,
        // so highlight nothing rather than pinning the book's first word.
        guard t >= denseWords[0].start else {
            if activeWordTracker.current != nil { activeWordTracker.current = nil }
            return
        }
        // Past a partial map's transcription frontier: no dense entries exist
        // yet, and the largest-below search would park the highlight on the
        // frontier word indefinitely. Mirror the pre-roll guard.
        if let frontier = partialFrontier, t >= frontier {
            if activeWordTracker.current != nil { activeWordTracker.current = nil }
            return
        }
        let dw = denseWords[denseWordIndex(forTime: t)]
        let changed = dw.wordIndex != activeWordTracker.current?.wordIndex
            || dw.segmentId != activeWordTracker.current?.segmentId
        guard changed else { return }
        activeWordTracker.current = WordAnchor(
            segmentId: dw.segmentId,
            wordIndex: dw.wordIndex,
            startSeconds: dw.start,
            endSeconds: dw.start + 0.25,
            audioIndex: -1,
            confidence: 1
        )
        followNarration()
    }

    /// Chapter-global word range of the sentence containing `word`, via the
    /// memoized word→paragraph tables plus the shared sentence scanner.
    func sentenceBounds(containing word: Int, in segment: TextSegment) -> (start: Int, end: Int)? {
        let layout = wordLayout(for: segment)
        guard let paraIdx = layout.paragraphIndex(forWord: word),
              let paraStart = layout.firstWord(ofParagraph: paraIdx) else { return nil }
        let paras = paragraphs(of: segment.text)
        guard paraIdx < paras.count else { return nil }
        let local = word - paraStart
        guard let s = sentenceWordRanges(in: paras[paraIdx])
            .first(where: { local >= $0.start && local < $0.end }) else { return nil }
        return (paraStart + s.start, paraStart + s.end)
    }

    /// The sentence being narrated right now: chapter + chapter-global word
    /// range, from the same latency-compensated dense-word lookup the
    /// highlight uses — so replay matches what's audible, not the engine's
    /// rendered frontier. nil while unaligned, pre-roll, past a partial
    /// frontier, or when another book is loaded.
    func currentSentenceBounds() -> (segmentID: String, start: Int, end: Int)? {
        guard !denseWords.isEmpty, audioIsThisBook else { return nil }
        let t = max(0, engine.currentTime - engine.outputLatency * Double(engine.rate))
        guard t >= denseWords[0].start else { return nil }
        if let frontier = partialFrontier, t >= frontier { return nil }
        let dw = denseWords[denseWordIndex(forTime: t)]
        guard let segment = segments.first(where: { $0.id == dw.segmentId }),
              let bounds = sentenceBounds(containing: dw.wordIndex, in: segment) else { return nil }
        return (segment.id, bounds.start, bounds.end)
    }

    /// Replay the sentence being narrated (offset 0), or jump to the
    /// previous (-1) / next (+1) one. The seek reuses the tap-to-play path
    /// (dense per-word start, then play), so partial-map frontier handling
    /// and the sparse fallback come along for free.
    func seekToSentence(offset: Int) {
        guard let current = currentSentenceBounds(),
              let segment = segments.first(where: { $0.id == current.segmentID }) else { return }
        let target: Int?
        switch offset {
        case ..<0:
            // The sentence before this one; at the chapter top, replay the
            // first. (Crossing back into the previous chapter is a page
            // flip away — not worth the boundary bookkeeping here.)
            target = current.start > 0
                ? sentenceBounds(containing: current.start - 1, in: segment)?.start
                : current.start
        case 0:
            target = current.start
        default:
            // The word at the exclusive end IS the next sentence's first
            // word (paragraph starts are cumulative, so this holds across
            // paragraph boundaries too); nil past the chapter tail.
            target = sentenceBounds(containing: current.end, in: segment)?.start
        }
        guard let target else { return }
        seekToWord(segmentID: segment.id, wordOffset: target, localIndex: 0)
    }

    /// Narration end of the chapter being read (audio seconds) — the sleep
    /// timer's "End of chapter" target. Computed here because the alignment
    /// map is reader state. Prefers the narrated chapter (the active word
    /// knows it) over the displayed one, and takes the max anchor end rather
    /// than trusting sort order (`anchorsBySegment` sorts by START time).
    /// nil without alignment — there's no data source for unaligned books.
    func currentChapterEndSeconds() -> TimeInterval? {
        guard audioIsThisBook else { return nil }
        guard let segID = activeWordTracker.current?.segmentId ?? currentSegment?.id,
              let anchors = anchorsBySegment[segID], !anchors.isEmpty else { return nil }
        return anchors.map(\.endSeconds).max()
    }

    /// Largest dense-word index whose start time is at or before `t`, 0 if `t`
    /// precedes everything. `denseWords` is time-sorted across all chapters, so
    /// this yields the currently-narrated word AND its chapter directly, with no
    /// assumption that the displayed chapter is the one being read.
    func denseWordIndex(forTime t: TimeInterval) -> Int {
        guard !denseWords.isEmpty else { return 0 }
        var lo = 0, hi = denseWords.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if denseWords[mid].start <= t { best = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return best
    }

    /// Page-break the chapter into chunks that each fit visually on one
    /// page. Two passes:
    ///
    /// 1. For each paragraph, if the running page already has content and
    ///    adding this paragraph would exceed `wordsPerPage`, close the page
    ///    and start a new one.
    /// 2. If a single paragraph itself exceeds `wordsPerPage` (common with
    ///    long expository paragraphs in 19th-century novels), split it at
    ///    sentence boundaries so each chunk fits. Each chunk records its
    ///    word offset within the source paragraph so word-level seek and
    ///    active-word tracking still resolve correctly across the split.
    ///
    /// Without the second pass, an oversized paragraph would be placed on
    /// its own page and SwiftUI would clip the bottom with an ellipsis,
    /// dropping the trailing text from the visible page entirely.
    func pageBreaks(for chapterText: String, wordsPerPage: Int = 120) -> [PageContent] {
        let allParas = paragraphs(of: chapterText)
        var pages: [PageContent] = []
        var current: [PagedParagraph] = []
        var wordCount = 0
        var pageIdx = 0
        var nextChunkID = 0

        func flushPage() {
            guard !current.isEmpty else { return }
            pages.append(PageContent(index: pageIdx, paragraphs: current))
            pageIdx += 1
            current = []
            wordCount = 0
        }

        for (originalIdx, paraText) in allParas.enumerated() {
            let words = paraText.split(separator: " ").map(String.init)
            let count = words.count

            if count <= wordsPerPage {
                if wordCount + count > wordsPerPage {
                    flushPage()
                }
                current.append(PagedParagraph(
                    originalIndex: originalIdx,
                    text: paraText,
                    wordOffsetWithinParagraph: 0,
                    chunkID: nextChunkID
                ))
                nextChunkID += 1
                wordCount += count
            } else {
                // Long paragraph: flush whatever page we're building, then
                // split into sentence-aligned chunks that each fit budget.
                flushPage()
                let chunks = chunkParagraph(words: words, sentenceRanges: sentenceWordRanges(in: paraText), budget: wordsPerPage)
                for chunk in chunks {
                    current.append(PagedParagraph(
                        originalIndex: originalIdx,
                        text: chunk.text,
                        wordOffsetWithinParagraph: chunk.startWord,
                        chunkID: nextChunkID
                    ))
                    nextChunkID += 1
                    wordCount = chunk.wordCount
                    flushPage()
                }
            }
        }
        flushPage()
        if pages.isEmpty {
            pages.append(PageContent(index: 0, paragraphs: []))
        }
        return pages
    }

    private struct ParagraphChunk {
        let startWord: Int
        let wordCount: Int
        let text: String
    }

    /// Split a too-long paragraph's words into chunks under `budget` size,
    /// snapping chunk ends to the nearest sentence boundary so the prose
    /// breaks at a natural pause rather than mid-clause. Falls back to a
    /// hard word-count split if no sentence boundary is reachable.
    private func chunkParagraph(words: [String], sentenceRanges: [(start: Int, end: Int)], budget: Int) -> [ParagraphChunk] {
        guard !words.isEmpty else { return [] }
        // Sentence ends in word-index space. If sentenceRanges is empty
        // (rare — no detected sentences), fall back to budget-sized splits.
        let sentenceEnds: [Int] = sentenceRanges.map { $0.end }
        var chunks: [ParagraphChunk] = []
        var cursor = 0
        while cursor < words.count {
            let hardEnd = min(cursor + budget, words.count)
            // Pick the latest sentence end that lies in (cursor, hardEnd].
            // If none exists in range, fall back to hardEnd (will mid-split).
            let snap = sentenceEnds.last(where: { $0 > cursor && $0 <= hardEnd }) ?? hardEnd
            let chunkWords = words[cursor..<snap]
            chunks.append(ParagraphChunk(
                startWord: cursor,
                wordCount: chunkWords.count,
                text: chunkWords.joined(separator: " ")
            ))
            cursor = snap
        }
        return chunks
    }

    // MARK: - Banners / bars

    var alignmentBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if alignmentStage.progressFraction == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "waveform")
                        .foregroundStyle(Theme.accent)
                        .font(.callout)
                }
                Text(alignmentStage.displayText)
                    .font(.callout)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let fraction = alignmentStage.progressFraction {
                    Text(String(format: "%d%%", Int(fraction * 100)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.inkMuted)
                        .monospacedDigit()
                }
            }
            if let fraction = alignmentStage.progressFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            if let frontier = partialFrontier, frontier > 0 {
                Text("Synced through \(frontierLabel(frontier)) — read-along live in synced chapters")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            if alignment.lowMatchWarning != nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Text("Very few matches so far — check that this audiobook matches the book. Cancel if it's the wrong narration.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.canvasCool)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
    }

    /// Brief post-alignment confirmation. Replaces the running banner so
    /// the user sees a definite outcome rather than the banner just
    /// vanishing.
    func alignmentToastBanner(_ message: String) -> some View {
        noticeBanner(message, icon: "checkmark.circle.fill") {
            alignment.acknowledgeFinished()
        }
    }

    /// Transient "not synced yet" notice — same chrome as the completion
    /// toast, different glyph, local dismissal.
    func seekNoticeBanner(_ message: String) -> some View {
        noticeBanner(message, icon: "hourglass") {
            seekNotice = nil
        }
    }

    private func noticeBanner(_ message: String, icon: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .font(.callout)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.canvasCool)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
        .transition(.opacity)
    }

    var attachAudiobookBar: some View {
        HStack(spacing: 12) {
            if let attachProgress {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.inkMuted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stitching audio files…")
                        .font(.callout)
                        .foregroundStyle(Theme.inkMuted)
                    ProgressView(value: attachProgress)
                        .tint(Theme.accent)
                }
                Button("Cancel") {
                    attachTask?.cancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(Theme.inkMuted)
                Text("No audiobook attached")
                    .font(.callout)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Button {
                    showAudioImporter = true
                } label: {
                    Label("Attach…", systemImage: "plus")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Theme.accent)
                .foregroundStyle(Theme.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 64)
        .background(Theme.canvasDeep)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
    }

    // MARK: - Computed

    var currentSegment: TextSegment? {
        guard let id = selectedSegmentID ?? segments.first?.id else { return nil }
        return segments.first(where: { $0.id == id })
    }

    // MARK: - Loading

    func loadEverything() async {
        await loadSegments()
        // Boundaries are computed immediately after segments land, BEFORE the
        // audio-load suspension point. The old tail-call position ran after
        // `engine.load` resumed, by which time `iosPageContent`'s `.task` had
        // already recomputed with the real spread mode — and the tail call
        // (default `useSpread: false`) clobbered it, paginating iPad/Catalyst
        // landscape spreads at the single-page word budget (clipped pages).
        // In this order, the view-side task always runs after and wins.
        recomputeFlatPageBoundaries()
        await loadAudioIfPresent()
        await loadAlignmentIfPresent()
        restoreProgress()
    }

    /// Walk every chapter and cache its page count at the active word
    /// budget (single-page or spread). The flat sequence of pages is what
    /// the page-curl containers index into, so the user can swipe past
    /// the end of a chapter and land at the next chapter's page 0 with no
    /// gap or reload — the iBooks continuous reading model.
    func recomputeFlatPageBoundaries(useSpread: Bool = false) {
        let budget = wordsBudget(useSpread: useSpread)
        // Page indices don't survive a re-pagination — carry the position
        // across as the current page's first WORD and remap it under the new
        // layout below. `pendingAnchorWord` was captured under the OLD geometry
        // the instant before the surface resized; for spread flips with no
        // prior capture, fall back to reading it now (still the old budget,
        // since the new one isn't applied yet). Keeps the reading position
        // stable through rotation / spread flips and the restore→recompute
        // sequence on open.
        let anchorWord = pendingAnchorWord
            ?? ((budget != flatBoundariesBudget && flatBoundariesBudget > 0 && paginated)
                ? currentPageFirstWord()
                : nil)
        pendingAnchorWord = nil

        // Apply the new layout signature BEFORE paginating so `paginatedPages`
        // (and its cache key) reflect the new spread mode / page geometry.
        flatBoundariesBudget = budget
        flatBoundariesUseSpread = useSpread
        flatBoundariesAreaKey = pageAreaKey

        var result: [(String, Int)] = []
        for segment in segments {
            let pages = paginatedPages(for: segment)
            result.append((segment.id, max(1, pages.count)))
        }
        flatPageBoundaries = result

        if let word = anchorWord, let segment = currentSegment,
           let page = pageIndex(forWordIndex: word, in: segment) {
            currentPageIndex = page
        }
    }

    /// Total flat page count across every chapter at the current budget.
    var flatTotalPages: Int {
        flatPageBoundaries.reduce(0) { $0 + $1.count }
    }

    /// Convert (chapter, pageInChapter) into the flat global page index.
    func flatGlobalIndex(segmentID: String, pageIdx: Int) -> Int {
        var sum = 0
        for (id, count) in flatPageBoundaries {
            if id == segmentID {
                return sum + max(0, min(pageIdx, count - 1))
            }
            sum += count
        }
        return 0
    }

    /// Inverse: flat global index → (chapter, pageInChapter). Returns nil
    /// if the boundaries haven't been computed yet (segments still loading).
    func flatSegmentAndPage(forGlobalIndex global: Int) -> (segmentID: String, pageIdx: Int)? {
        guard !flatPageBoundaries.isEmpty else { return nil }
        var remaining = global
        for (id, count) in flatPageBoundaries {
            if remaining < count {
                return (id, remaining)
            }
            remaining -= count
        }
        // Past the end — clamp to the last page of the last chapter.
        if let last = flatPageBoundaries.last {
            return (last.segmentID, last.count - 1)
        }
        return nil
    }

    func loadSegments() async {
        loadingSegments = true
        defer { loadingSegments = false }
        guard let url = book.resolvedEbookURL else {
            loadError = "Book file is missing. Re-import this title from the library."
            return
        }
        do {
            guard let importer = EBookImporterRegistry.importer(for: url) else {
                loadError = "Unsupported book format."
                return
            }
            let imported = try await importer.importBook(from: url)
            segments = imported.segments
            // Backfill cover for books imported before the filename
            // heuristic in OPFDelegate.result() landed — those `Book`
            // rows have `coverImageData == nil` even though the EPUB on
            // disk contains a usable cover image. Re-parsing on every
            // load is wasteful, so only write when the slot is empty
            // AND the freshly-parsed EPUB produced cover bytes.
            if book.coverImageData == nil, let cover = imported.coverImageData {
                book.coverImageData = downsampledCoverData(cover)
                saveOrReport()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Reading progress

    func restoreProgress() {
        consolidateProgressRowsIfNeeded()
        if let progress = book.progress,
           !progress.currentCFI.isEmpty,
           let segment = segments.first(where: { $0.id == progress.currentCFI }) {
            // Suppress the chapter-change page reset for this one assignment
            // so the saved page index survives. The flag clears on the next
            // selectedSegmentID change handler.
            isRestoringProgress = true
            selectedSegmentID = progress.currentCFI
            // Prefer the word anchor: a raw page index is only meaningful at
            // the budget it was saved under, so restoring it after an
            // orientation / size-class change landed chapters away from the
            // true position. -1 = pre-V2 row or scroll mode; use the index.
            if progress.firstWordIndex >= 0,
               let page = pageIndex(forWordIndex: progress.firstWordIndex, in: segment) {
                currentPageIndex = page
            } else {
                currentPageIndex = max(0, progress.currentPageIndex)
            }
            // Only move the audio playhead if the engine is actually loaded
            // with THIS book — in background mode it may be mid-playback on
            // another book, and seeking it to our saved position would hijack
            // that. A book freshly loaded by `present` starts at 0, so this
            // restores its position; a book already playing keeps its place.
            if progress.currentAudioSeconds > 0, audioIsThisBook, engine.state != .playing {
                // Cross-launch smart rewind: the engine's in-memory pause
                // marker doesn't survive a relaunch, so derive the same
                // contract from `lastReadAt`. This seek also clears the
                // engine marker, so a stale in-session pause can't stack a
                // second rewind on top when play is pressed.
                let awayFor = Date.now.timeIntervalSince(progress.lastReadAt)
                let rewind = awayFor >= AudioEngine.smartRewindAfter
                    ? AudioEngine.smartRewindSeconds : 0
                engine.seek(to: max(0, progress.currentAudioSeconds - rewind))
            }
        } else if selectedSegmentID == nil {
            selectedSegmentID = segments.first?.id
        }
    }

    /// Earlier builds had a SwiftData inverse-relationship lag bug that
    /// caused every `saveProgressIfNeeded` call to insert a NEW
    /// `ReadingProgress` row instead of updating the existing one, because
    /// `book.progress` stayed nil. The store can therefore contain many
    /// rows for the same book, and `book.progress` returns one of them
    /// non-deterministically — usually the oldest, which is what made
    /// "remember my page" appear broken. On every book open, fetch every
    /// `ReadingProgress` for this book, keep the most recently written, and
    /// drop the rest.
    private func consolidateProgressRowsIfNeeded() {
        let bookID = book.id
        let descriptor = FetchDescriptor<ReadingProgress>(
            predicate: #Predicate<ReadingProgress> { $0.book?.id == bookID },
            sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)]
        )
        guard let rows = try? modelContext.fetch(descriptor), rows.count > 1 else {
            return
        }
        let keep = rows.first!
        for extra in rows.dropFirst() {
            modelContext.delete(extra)
        }
        book.progress = keep
        saveOrReport()
    }

    func saveProgressIfNeeded(force: Bool = false) {
        guard let segmentID = selectedSegmentID else { return }
        let interval = lastProgressSaveAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        guard force || interval >= 2.0 else { return }

        let progress: ReadingProgress
        if let existing = book.progress {
            progress = existing
        } else {
            let new = ReadingProgress(
                book: book,
                currentCFI: segmentID,
                currentAudioSeconds: audioIsThisBook ? engine.currentTime : 0,
                currentPageIndex: currentPageIndex,
                lastReadAt: .now
            )
            modelContext.insert(new)
            // Force the inverse — SwiftData doesn't reliably populate
            // `book.progress` from `progress.book = book` until the next
            // change-tracking cycle. Without this the next save call sees
            // `book.progress` still nil and inserts ANOTHER row, and so on.
            book.progress = new
            progress = new
        }

        progress.currentCFI = segmentID
        // Only record the audio playhead when the engine is on this book —
        // in background mode it may be narrating a different one.
        if audioIsThisBook {
            progress.currentAudioSeconds = engine.currentTime
        }
        progress.currentPageIndex = currentPageIndex
        // Budget-independent anchor (see ReadingProgress.firstWordIndex).
        if paginated, let segment = currentSegment,
           let word = wordLayout(for: segment).startWord(ofPage: currentPageIndex) {
            progress.firstWordIndex = word
        } else {
            progress.firstWordIndex = -1
        }
        progress.lastReadAt = .now
        saveOrReport()
        lastProgressSaveAt = .now
    }

    func loadAudioIfPresent() async {
        // The shared engine may already be playing this book (returned to it)
        // or a different one (background mode). The coordinator decides
        // whether to load/switch; it owns now-playing metadata too.
        await audio.present(book: book, backgroundMode: backgroundAudioEnabled)
    }

    /// Background mode, another book playing, user wants THIS book now: switch
    /// the shared engine to it, resume at its saved position, and play.
    func activateThisBookAudio() {
        Task { @MainActor in
            guard await audio.switchTo(book: book) else { return }
            if let secs = book.progress?.currentAudioSeconds, secs > 0 {
                engine.seek(to: secs)
            }
            try? engine.play()
        }
    }

    /// Whether to offer "play this audiobook" instead of live transport: only
    /// in background mode, when this book has audio but the shared engine is
    /// currently loaded with a different book.
    var showSwitchToAudioBar: Bool {
        book.audiobookFileURL != nil && backgroundAudioEnabled && !audioIsThisBook && audio.hasAudio
    }

    /// Message for the audio bar when THIS book's audio is unplayable: the
    /// coordinator recorded a load failure for it, or (legacy path) the
    /// engine itself sits in `.error` while loaded with it. nil = healthy.
    var audioLoadErrorMessage: String? {
        if let message = audio.loadError(for: book) { return message }
        if audioIsThisBook, case .error(let message) = engine.state { return message }
        return nil
    }

    /// Retry from the audio bar's error row. `switchTo` re-runs the failed
    /// load (the failed book never became `loadedBookID`, so it won't no-op)
    /// and clears the recorded failure on success.
    func retryAudioLoad() {
        Task { @MainActor in
            await audio.switchTo(book: book)
        }
    }

    func loadAlignmentIfPresent() async {
        let service = AlignmentService(modelContext: modelContext)
        let map = await service.loadAlignmentMap(for: book)
        await applyAlignmentMap(map)
    }

    /// Swap the reader's alignment map and rebuild the derived indexes off
    /// the main actor — flattening + sorting hundreds of thousands of dense
    /// entries used to run on @MainActor at every book open and repeatedly
    /// per align cycle. The generation guard drops a build that a newer
    /// apply (partial swap, attach reset) superseded while it ran.
    func applyAlignmentMap(_ map: AlignmentMap?) async {
        alignmentApplyGeneration += 1
        let generation = alignmentApplyGeneration
        alignmentMap = map
        let indexes = await AlignmentIndexes.build(from: map)
        guard generation == alignmentApplyGeneration else { return }
        anchorsBySegment = indexes.anchorsBySegment
        denseWords = indexes.denseWords
        roughSegments = indexes.roughSegments
    }

    // MARK: - Alignment

    /// Hand off to the app-level coordinator so the job survives popping
    /// this view off the navigation stack. The completion bookkeeping
    /// (banner, error alert, alignmentMap reload) is driven by the
    /// `.onChange(of: alignment.lastFinishedBookID)` modifier in `body`.
    func runAlignment() {
        alignment.start(book: book, modelContext: modelContext)
    }

    /// Reloads the on-disk alignment map after the coordinator signals
    /// completion. The coordinator runs on a single shared Task, so this
    /// is the only spot we re-read the JSON.
    func reloadAlignmentAfterCompletion() {
        Task { @MainActor in
            let service = AlignmentService(modelContext: modelContext)
            if let map = await service.loadAlignmentMap(for: book) {
                await applyAlignmentMap(map)
            }
        }
    }

    // MARK: - Helpers

    func chapterTitle(_ segment: TextSegment, index: Int) -> String {
        if let title = segment.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title.count > 60 ? String(title.prefix(60)) + "…" : title
        }
        let firstLine = segment.text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Chapter \(index + 1)"
        }
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    func displayChapterLabel(for segment: TextSegment) -> String {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return "" }
        let num = "Chapter \(index + 1)"
        let title = chapterTitle(segment, index: index)
        if title.lowercased().hasPrefix("chapter ") {
            return title
        }
        return "\(num) · \(title)"
    }

    func paragraphs(of text: String) -> [String] {
        // Paragraphs are split on double newlines (the importer maps `</p>` to
        // `\n\n`). Internal whitespace within a paragraph — including the `\n`
        // the importer inserts for `<br>` tags — gets collapsed to single
        // spaces so prose flows naturally. EPUBs (especially older novels)
        // litter `<br>` inside paragraphs for typographic preservation; left
        // as `\n`, SwiftUI's `Text` honors each as a hard line break and the
        // page surface fills 3-4× faster than the word count predicts,
        // causing visible overflow / ellipsis truncation at the bottom.
        return text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
    }

    var audioContentTypes: [UTType] {
        // `.audio` is the public umbrella but Apple registers `.m4b` under
        // `com.apple.iTunes.audiobook` (a sibling of public.audio, NOT a
        // child), so audiobook files are greyed out / hidden in the Files
        // picker when only `.audio` is allowed. We additionally accept the
        // audiobook UTI, the protected-mpeg-4-audio UTI, and any UTI the
        // system happens to map `.m4b` / `.m4a` to so the user can see
        // their library file regardless of its specific registration.
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if let audiobook = UTType("com.apple.iTunes.audiobook") {
            types.append(audiobook)
        }
        if let protected = UTType("com.apple.protected-mpeg-4-audio") {
            types.append(protected)
        }
        for ext in ["m4b", "m4a", "aac"] {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }

    func handleAudioPicked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls) where urls.count > 1:
            // Resolve the stitch order up front (track tags, natural-sort
            // fallback) so the confirm alert shows exactly what will play.
            Task { @MainActor in
                pendingAudioParts = await ImportService.resolvedPartOrder(urls)
            }
        case .success(let urls):
            attachAudio(urls)
        case .failure(let error):
            attachError = error.localizedDescription
        }
    }

    func attachAudio(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        attachTask = Task { @MainActor in
            defer {
                attachProgress = nil
                attachTask = nil
            }
            do {
                if urls.count > 1 { attachProgress = 0 }
                let service = ImportService(modelContext: modelContext)
                try await service.attachAudiobook(urls, to: book) { fraction in
                    Task { @MainActor in attachProgress = fraction }
                }
                // Drop the in-memory alignment too — `attachAudiobook`
                // already deleted the on-disk JSON and nulled the
                // book.alignmentMapURL, but the reader holds a
                // separate cached copy that the page-curl reads for
                // play-from-here. Without this the UI keeps "Re-align"
                // available against stale anchors until the next book
                // open.
                await applyAlignmentMap(nil)
                // The audiobook file changed on disk; force the shared
                // engine to drop and reload it (a plain present() would
                // no-op since the bookID is unchanged).
                audio.unload(ifBookID: book.id)
                await audio.switchTo(book: book)
            } catch is CancellationError {
                // User cancelled the merge — nothing changed on disk.
            } catch {
                attachError = error.localizedDescription
            }
        }
    }
}

// MARK: - Reader data types

enum SidebarTab: String, CaseIterable {
    case chapters
    case bookmarks
    case notes
}

private struct AudioTimeWatcher: View {
    let engine: AudioEngine
    let onTick: () -> Void

    var body: some View {
        Color.clear.onChange(of: engine.currentTime) { _, _ in onTick() }
    }
}

/// Holds the currently-narrated word for aligned audio. Class so
/// `@Observable` invalidates only views that read `current` (visible
/// `ParagraphRow`s) — `ReaderView.body` doesn't touch it, so the rest of
/// the reader stays stable across word-level updates during playback.
@Observable
final class ActiveWordTracker {
    var current: WordAnchor?
}

/// One book word with its narration start time. The read-along highlight
/// binary-searches a time-sorted array of these against `engine.currentTime`.
struct DenseWord: Sendable {
    let start: Double
    let segmentId: String
    let wordIndex: Int
}

/// Derived lookup structures for one alignment map, built off the main
/// actor by `ReaderView.applyAlignmentMap` — the flatten + sort touches
/// every dense entry (hundreds of thousands on a long audiobook).
struct AlignmentIndexes: Sendable {
    /// Anchors grouped by segment, start-time sorted. The audio tick hits
    /// this lookup ~10×/sec; pre-sorting avoids re-sorting per tick.
    var anchorsBySegment: [String: [WordAnchor]] = [:]
    /// Every book word with its narration start time, flattened across all
    /// chapters and time-sorted for the read-along binary search.
    var denseWords: [DenseWord] = []
    /// Chapters under the rough-match threshold.
    var roughSegments: Set<String> = []

    /// Runs on the cooperative pool (nonisolated async), never the
    /// caller's actor.
    nonisolated static func build(from map: AlignmentMap?) async -> AlignmentIndexes {
        guard let map else { return AlignmentIndexes() }
        var indexes = AlignmentIndexes()
        indexes.roughSegments = map.roughSegmentIDs()

        var byStart: [String: [WordAnchor]] = [:]
        for anchor in map.words {
            byStart[anchor.segmentId, default: []].append(anchor)
        }
        for k in byStart.keys {
            byStart[k]?.sort { $0.startSeconds < $1.startSeconds }
        }
        indexes.anchorsBySegment = byStart

        // Stored per-segment in reading order, so the concatenation is
        // already time-ordered; sort defensively.
        var dense: [DenseWord] = []
        for swt in map.wordTimes {
            let count = min(swt.wordIndices.count, swt.starts.count)
            for i in 0..<count {
                dense.append(DenseWord(start: swt.starts[i], segmentId: swt.segmentId, wordIndex: swt.wordIndices[i]))
            }
        }
        dense.sort { $0.start < $1.start }
        indexes.denseWords = dense
        return indexes
    }
}

/// Whitespace tokenizer every word-indexing consumer shares — pagination,
/// seek offsets, read-along lookups, and `ParagraphRow`'s active-word bounds
/// all count words with this exact split so their indices line up.
func tokenizeWords(_ text: String) -> [String] {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
}

/// Sentence boundaries of `text` in word-index space (`end` exclusive),
/// word-counted exactly like `tokenizeWords`. Shared by paragraph chunking,
/// `ParagraphRow`'s sentence underline, and the sentence seek/replay path —
/// all sentence consumers derive from this, never from `SentenceAnchor`
/// (anchored-sentences-only with raw seconds reproduced the documented
/// "flips too soon" failure).
func sentenceWordRanges(in text: String) -> [(start: Int, end: Int)] {
    var sentenceCharRanges: [(Int, Int)] = []
    text.enumerateSubstrings(
        in: text.startIndex..<text.endIndex,
        options: .bySentences
    ) { _, range, _, _ in
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        sentenceCharRanges.append((start, end))
    }

    var wordCharSpans: [(Int, Int)] = []
    var inWord = false
    var wordStart = 0
    var idx = 0
    for ch in text {
        if ch.isWhitespace || ch.isNewline {
            if inWord {
                wordCharSpans.append((wordStart, idx))
                inWord = false
            }
        } else {
            if !inWord { wordStart = idx; inWord = true }
        }
        idx += 1
    }
    if inWord { wordCharSpans.append((wordStart, idx)) }

    var ranges: [(start: Int, end: Int)] = []
    for (sStart, sEnd) in sentenceCharRanges {
        var first: Int?
        var last: Int?
        for (i, span) in wordCharSpans.enumerated() {
            let center = (span.0 + span.1) / 2
            if center >= sStart && center < sEnd {
                if first == nil { first = i }
                last = i
            }
        }
        if let f = first, let l = last {
            ranges.append((f, l + 1))
        }
    }
    return ranges
}

/// Narration-follow bookkeeping. Plain class (never invalidates SwiftUI):
/// `suspendedUntil` is written from the scroll view's drag observer at
/// touch-move rate, and nothing in `body` reads either field — they only
/// gate `followNarration()`, which runs from audio-tick handlers.
final class FollowState {
    /// Follow won't drive the page/scroll position before this instant.
    var suspendedUntil: Date?
    /// The page the last follow-driven turn targeted; consumed by the
    /// `currentPageIndex` onChange so manual turns stay distinguishable.
    var drivenPage: Int?
}

/// Word→paragraph and word→page lookup tables for one (chapter, budget),
/// memoized by `ReaderView.wordLayout(for:)`. Deliberately a plain class —
/// not `@Observable`, never invalidates SwiftUI — because it's a derived
/// cache: it must be refreshable mid-body (the DEBUG HUD reads it during
/// view evaluation, where `@State` writes are illegal) and consultable per
/// narrated-word change without re-rendering the reader.
final class SegmentWordLayoutCache {
    private(set) var key: String = ""
    /// `paragraphStarts[p]` = chapter-global index of paragraph `p`'s first word.
    private var paragraphStarts: [Int] = []
    /// `pageStarts[g]` = chapter-global index of page `g`'s first word, at the
    /// budget the flat page-curl sequence paginates with.
    private var pageStarts: [Int] = []

    func update(key: String, paragraphStarts: [Int], pageStarts: [Int]) {
        self.key = key
        self.paragraphStarts = paragraphStarts
        self.pageStarts = pageStarts
    }

    func paragraphIndex(forWord word: Int) -> Int? {
        containerIndex(of: word, in: paragraphStarts)
    }

    func pageIndex(forWord word: Int) -> Int? {
        containerIndex(of: word, in: pageStarts)
    }

    /// Chapter-global index of the paragraph's first word, for jumping to a
    /// paragraph by way of the word→page table.
    func firstWord(ofParagraph p: Int) -> Int? {
        paragraphStarts.indices.contains(p) ? paragraphStarts[p] : nil
    }

    /// Chapter-global index of the page's first word — the budget-independent
    /// anchor persisted with reading progress.
    func startWord(ofPage p: Int) -> Int? {
        pageStarts.indices.contains(p) ? pageStarts[p] : nil
    }

    /// Largest index whose start word is ≤ `word` — `starts` is ascending, so
    /// that's the paragraph/page containing the word. Words before the first
    /// start clamp to 0, words past the last start to the final entry.
    private func containerIndex(of word: Int, in starts: [Int]) -> Int? {
        guard !starts.isEmpty else { return nil }
        var lo = 0, hi = starts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= word {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}

struct ParagraphAnchor: Identifiable, Equatable {
    let segmentID: String
    let paragraphIndex: Int
    var id: String { "\(segmentID)#p\(paragraphIndex)" }
}

struct PageContent: Identifiable {
    let index: Int
    let paragraphs: [PagedParagraph]
    var id: Int { index }
}

struct PagedParagraph: Identifiable {
    let originalIndex: Int
    let text: String
    /// Word offset of this chunk inside its source paragraph. 0 for whole
    /// paragraphs; non-zero when a long paragraph was split across pages
    /// at sentence boundaries to avoid clipping.
    let wordOffsetWithinParagraph: Int
    /// Distinct id per chunk so SwiftUI's ForEach doesn't collapse two
    /// chunks of the same source paragraph into a single row.
    let chunkID: Int
    var id: Int { chunkID }

    init(originalIndex: Int, text: String, wordOffsetWithinParagraph: Int = 0, chunkID: Int? = nil) {
        self.originalIndex = originalIndex
        self.text = text
        self.wordOffsetWithinParagraph = wordOffsetWithinParagraph
        self.chunkID = chunkID ?? originalIndex
    }
}
