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

    @State var engine = AudioEngine()
    @State var showAudioImporter = false
    @State var attachError: String?

    @State var alignmentMap: AlignmentMap?
    /// Alignment progress + completion banner are sourced from the
    /// app-level `AlignmentCoordinator`. Going `back` while alignment is
    /// running pops this view but the coordinator keeps the job alive.
    @Environment(AlignmentCoordinator.self) var alignment

    var alignmentRunning: Bool { alignment.isRunning(for: book.id) }
    var alignmentStage: AlignmentStage { alignment.stage ?? .aligning }
    var alignmentToast: String? { alignmentRunning ? nil : alignment.toast }
    var alignmentError: String? { alignment.error }

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
    @AppStorage(AppSettings.animationsEnabledKey) var animationsEnabled: Bool = true
    @State var currentPageIndex: Int = 0
    @State var lastTurnedForward: Bool = true
    @State var sidebarTab: SidebarTab = .chapters
    @State var useSpreadMode: Bool = true
    @FocusState var pageFocused: Bool

    @State var measuredPageSize: CGSize = .zero
    @State var isAnimatingTransition: Bool = false
    @State var transitionProgress: Double = 0
    @State var transitionDirection: DogEarPageTurn.Direction = .forward

    #if os(iOS)
    @State var iosSidebarVisible: Bool = false
    @State var iosShowChapterSheet: Bool = false
    @State var iosShowAudioSheet: Bool = false
    @State var iosShowSettings: Bool = false
    /// Confirmation surfaced when the back button is tapped while
    /// alignment is running — the job will continue in the background
    /// either way, but the prompt is the only place the user learns that.
    @State var iosShowLeaveAlignmentConfirm: Bool = false
    @State var iosDragProgress: Double = 0
    @State var iosDragDirection: DogEarPageTurn.Direction = .forward
    @State var iosDragActive: Bool = false
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

    @State var lastProgressSaveAt: Date?

    /// Pre-filtered + pre-sorted anchors per segment. Built once when the
    /// alignment map loads (or changes) and looked up by segment ID in
    /// O(1). The previous code re-filtered the *entire* `map.words` list
    /// (10s of thousands of entries on a long audiobook) every audio tick
    /// — 10 Hz × O(N) blocked the main thread enough to freeze playback.
    @State var anchorsBySegment: [String: [WordAnchor]] = [:]
    @State var anchorsBySegmentAudioIdx: [String: [WordAnchor]] = [:]
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

    var body: some View {
        readerLayout
            .background(Theme.canvas)
            .navigationTitle(book.title)
        .background {
            // Engine ticks `currentTime` at 10 Hz; isolating the read
            // here keeps it out of `ReaderView.body`, which would
            // otherwise become a dependent of `currentTime` and re-eval
            // the entire reader (breaking SwiftUI Menu state + gestures
            // during playback).
            AudioTimeWatcher(engine: engine) {
                saveProgressIfNeeded()
            }
        }
        .onChange(of: selectedSegmentID) { _, _ in
            saveProgressIfNeeded(force: true)
        }
        .onChange(of: currentPageIndex) { _, _ in
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
        .onDisappear {
            saveProgressIfNeeded(force: true)
        }
        .task(id: book.id) {
            await loadEverything()
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: audioContentTypes
        ) { result in
            handleAudioPicked(result)
        }
        .alert("Audio attach failed", isPresented: Binding(
            get: { attachError != nil },
            set: { if !$0 { attachError = nil } }
        )) {
            Button("OK", role: .cancel) { attachError = nil }
        } message: {
            Text(attachError ?? "")
        }
        .alert("Alignment failed", isPresented: Binding(
            get: { alignmentError != nil },
            set: { if !$0 { alignment.dismissError() } }
        )) {
            Button("OK", role: .cancel) { alignment.dismissError() }
        } message: {
            Text(alignmentError ?? "")
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
                    if let loc = annotation.paragraphLocation {
                        selectedSegmentID = loc.segmentID
                    }
                    showAnnotationsSheet = false
                },
                onDismiss: { showAnnotationsSheet = false }
            )
        }
    }

    // MARK: - Annotation helpers

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
        try? modelContext.save()
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
        try? modelContext.save()
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
        try? modelContext.save()
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
        try? modelContext.save()
        annotationRevision &+= 1
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
        try? modelContext.save()
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
                    try? modelContext.save()
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

    var mainColumn: some View {
        VStack(spacing: 0) {
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if alignmentRunning {
                alignmentBanner
            } else if let toast = alignmentToast {
                alignmentToastBanner(toast)
            }
            if book.audiobookFileURL != nil {
                AudioBarView(
                    engine: engine,
                    onAlign: { runAlignment() },
                    alignmentEnabled: !alignmentRunning,
                    alignmentExists: alignmentMap != nil
                )
            } else {
                attachAudiobookBar
            }
        }
    }

    // MARK: - Sidebar

    var chapterList: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().background(Theme.hairline)
            sidebarTabBar
            Divider().background(Theme.hairline)
            sidebarTabContent
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

    @ViewBuilder
    var sidebarTabContent: some View {
        switch sidebarTab {
        case .chapters: chaptersTab
        case .bookmarks: bookmarksTab
        case .notes: notesTab
        }
    }

    var chaptersTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    chapterRow(segment: segment, index: index)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    func chapterRow(segment: TextSegment, index: Int) -> some View {
        let isSelected = selectedSegmentID == segment.id
        return Button {
            selectedSegmentID = segment.id
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

    var bookmarksTab: some View {
        annotationListTab(
            kind: .bookmark,
            emptyIcon: "bookmark",
            emptyText: "No bookmarks yet"
        )
    }

    var notesTab: some View {
        annotationListTab(
            kind: .note,
            emptyIcon: "text.bubble",
            emptyText: "No notes yet"
        )
    }

    func annotationListTab(kind: AnnotationKind, emptyIcon: String, emptyText: String) -> some View {
        let items = sortedAnnotationsForSidebar(kind: kind)
        return Group {
            if items.isEmpty {
                emptySidebarState(icon: emptyIcon, text: emptyText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { annotation in
                            sidebarAnnotationRow(annotation)
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

    func sidebarAnnotationRow(_ annotation: Annotation) -> some View {
        Button {
            if let loc = annotation.paragraphLocation {
                selectedSegmentID = loc.segmentID
            }
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
        let segmentOrder = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
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

    var pageContent: some View {
        Group {
            if loadingSegments {
                ProgressView().padding(.top, 80)
            } else if let loadError {
                Text(loadError).font(.callout).foregroundStyle(.red).padding()
            } else if !segments.isEmpty, paginated, flatTotalPages > 0 {
                if let segment = currentSegment {
                    paginatedView(segment: segment)
                }
            } else if let segment = currentSegment {
                scrollView(segment: segment)
            } else {
                Text("Empty chapter").foregroundStyle(Theme.inkMuted).padding()
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.canvas)
        .onChange(of: selectedSegmentID) { _, _ in
            if isRestoringProgress {
                isRestoringProgress = false
            } else {
                currentPageIndex = 0
            }
        }
    }

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
            }
        }
    }

    /// Threshold below which the reader collapses from two-page spread to a
    /// single page. Below this each half would be too narrow to read the
    /// 16pt serif body comfortably.
    static let spreadModeMinWidth: CGFloat = 720

    func paginatedView(segment: TextSegment) -> some View {
        return GeometryReader { geo in
            let useSpread = geo.size.width >= Self.spreadModeMinWidth
            let wordsPerPage = wordsBudget(useSpread: useSpread)
            let pages = pageBreaks(for: segment.text, wordsPerPage: wordsPerPage)
            let halfWidth = max(0, (geo.size.width - 1) / 2)
            let safeIndex = pages.isEmpty ? 0 : max(0, min(currentPageIndex, pages.count - 1))
            let displayLeft = useSpread
                ? normalizedLeftIndex(safeIndex, pageCount: pages.count)
                : safeIndex

            ZStack(alignment: .topLeading) {
                if useSpread {
                    HStack(spacing: 0) {
                        spreadHalf(
                            pages: pages,
                            pageIndex: displayLeft,
                            side: .left,
                            segment: segment,
                            halfWidth: halfWidth,
                            height: geo.size.height
                        )
                        spineSeparator(height: geo.size.height)
                        spreadHalf(
                            pages: pages,
                            pageIndex: displayLeft + 1,
                            side: .right,
                            segment: segment,
                            halfWidth: halfWidth,
                            height: geo.size.height
                        )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Group {
                        if pages.indices.contains(safeIndex) {
                            pageSurface(segment: segment, page: pages[safeIndex], pageIndex: safeIndex)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // Dog-ear sits at the top of the ZStack so its flap can
                // extend past any sibling layer (spine in spread mode,
                // neighbouring page) without being covered.
                if let activeProgress = activeDogEarProgress {
                    DogEarPageTurn(
                        progress: activeProgress.progress,
                        direction: activeProgress.direction,
                        colorScheme: colorScheme
                    )
                    .frame(
                        width: useSpread ? halfWidth : geo.size.width,
                        height: geo.size.height
                    )
                    .offset(
                        x: useSpread && activeProgress.direction == .forward ? halfWidth + 1 : 0,
                        y: 0
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Theme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
            .onAppear {
                measuredPageSize = useSpread
                    ? CGSize(width: halfWidth, height: geo.size.height)
                    : CGSize(width: geo.size.width, height: geo.size.height)
                useSpreadMode = useSpread
            }
            .onChange(of: geo.size) { _, _ in
                measuredPageSize = useSpread
                    ? CGSize(width: halfWidth, height: geo.size.height)
                    : CGSize(width: geo.size.width, height: geo.size.height)
                useSpreadMode = useSpread
            }
        }
        .padding(.horizontal, paginatedHorizontalPadding)
        .padding(.vertical, paginatedVerticalPadding)
        .background(Theme.canvasCool)
        .focusable()
        .focused($pageFocused)
        .onAppear { pageFocused = true }
        .onKeyPress(.leftArrow) {
            advancePage(by: -1, segment: segment)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            advancePage(by: 1, segment: segment)
            return .handled
        }
        .onKeyPress(.space) {
            advancePage(by: 1, segment: segment)
            return .handled
        }
        #if os(iOS)
        .gesture(pageTurnDragGesture(for: segment))
        #endif
    }

    /// Reader page padding. iOS gets less canvas-cool gutter so the page
    /// itself can dominate the screen; macOS keeps the windowed feel.
    var paginatedHorizontalPadding: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 0 : 16
        #else
        return 32
        #endif
    }

    var paginatedVerticalPadding: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 0 : 16
        #else
        return 24
        #endif
    }

    #if os(iOS)
    /// Drives the dog-ear curl from a horizontal drag. Drag left to peel
    /// from the top-right (advance forward), drag right to peel from the
    /// top-left (go back). Releasing past the commit threshold animates
    /// the rest of the turn; releasing short cancels by easing back to 0.
    func pageTurnDragGesture(for segment: TextSegment) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !isAnimatingTransition else { return }
                let width = max(measuredPageSize.width, 1)
                let dx = value.translation.width
                let direction: DogEarPageTurn.Direction = dx < 0 ? .forward : .backward
                if !iosDragActive {
                    iosDragActive = true
                    iosDragDirection = direction
                } else if direction != iosDragDirection {
                    // Switched directions mid-drag — re-anchor so the curl
                    // reflects the new intent without snapping.
                    iosDragDirection = direction
                }
                let normalized = min(1.0, abs(dx) / (width * 0.6))
                iosDragProgress = Double(normalized)
            }
            .onEnded { value in
                guard iosDragActive else { return }
                let commit = iosDragProgress > 0.4
                let direction = iosDragDirection
                iosDragActive = false
                if commit {
                    // Reset progress immediately and let `turnPage` drive
                    // its own commit animation.
                    iosDragProgress = 0
                    advancePage(by: direction == .forward ? 1 : -1, segment: segment)
                } else {
                    withAnimation(.easeOut(duration: 0.22)) {
                        iosDragProgress = 0
                    }
                }
            }
    }
    #endif

    /// Advance forward (`direction = +1`) or backward (`-1`) by one page or
    /// one spread depending on `useSpreadMode`. Recomputes pages with the
    /// mode's word budget so a forward press always moves to the next
    /// "screen worth" of text. When the reader is on the last page of the
    /// current chapter, a forward swipe / arrow-key crosses into the next
    /// chapter (page 0); a backward swipe at page 0 jumps to the last page
    /// of the previous chapter — no detour through the chapter list.
    func advancePage(by direction: Int, segment: TextSegment) {
        let wordsPerPage = wordsBudget(useSpread: useSpreadMode)
        let pages = pageBreaks(for: segment.text, wordsPerPage: wordsPerPage)
        let step = useSpreadMode ? 2 : 1
        let target = currentPageIndex + direction * step

        if direction > 0 {
            let lastValidLeft = useSpreadMode
                ? normalizedLeftIndex(max(0, pages.count - 1), pageCount: pages.count)
                : max(0, pages.count - 1)
            if target > lastValidLeft {
                crossToAdjacentChapter(forward: true, from: segment)
                return
            }
        } else if direction < 0 {
            if target < 0 {
                crossToAdjacentChapter(forward: false, from: segment)
                return
            }
        }

        turnPage(
            to: target,
            totalPages: pages.count,
            useSpread: useSpreadMode,
            pages: pages,
            segment: segment
        )
    }

    /// Jump to the adjacent chapter and land on the right edge of its page
    /// range so the read order is preserved. Forward → next chapter, page 0.
    /// Backward → previous chapter, last page (or last spread-left in spread
    /// mode). Does nothing at the spine ends. Suppresses the chapter-change
    /// page-reset via `isRestoringProgress` so the landing page index sticks.
    private func crossToAdjacentChapter(forward: Bool, from segment: TextSegment) {
        guard let idx = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        let nextIdx = forward ? idx + 1 : idx - 1
        guard nextIdx >= 0, nextIdx < segments.count else { return }
        let newSegment = segments[nextIdx]

        let landingPage: Int
        if forward {
            landingPage = 0
        } else {
            let newPages = pageBreaks(
                for: newSegment.text,
                wordsPerPage: wordsBudget(useSpread: useSpreadMode)
            )
            if useSpreadMode {
                landingPage = normalizedLeftIndex(max(0, newPages.count - 1), pageCount: newPages.count)
            } else {
                landingPage = max(0, newPages.count - 1)
            }
        }

        lastTurnedForward = forward
        isRestoringProgress = true
        selectedSegmentID = newSegment.id
        currentPageIndex = landingPage
    }

    /// Renders one half of the spread: just the live `pageSurface`. The
    /// dog-ear page-turn overlay is mounted at the spread level (see
    /// `paginatedView`) so it can extend past the spine without being
    /// covered by sibling layers.
    @ViewBuilder
    func spreadHalf(
        pages: [PageContent],
        pageIndex: Int,
        side: PageSide,
        segment: TextSegment,
        halfWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        Group {
            if pages.indices.contains(pageIndex) {
                pageSurface(segment: segment, page: pages[pageIndex], pageIndex: pageIndex)
            } else {
                Color.clear
            }
        }
        .frame(width: halfWidth, height: height)
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
        if useSpread {
            return 95
        }
        #if os(iOS)
        return horizontalSizeClass == .compact ? 120 : 170
        #else
        return 170
        #endif
    }

    enum PageSide {
        case left
        case right
    }

    /// Spine between the two pages of a spread. A 1pt hairline plus a soft
    /// highlight on its left and a feathered shadow on its right gives the
    /// spread a paper-indent feel rather than a flat divider.
    func spineSeparator(height: CGFloat) -> some View {
        let highlight = Color.white.opacity(0.5)
        let shadow = Color(red: 31/255, green: 26/255, blue: 20/255).opacity(0.12)
        return ZStack(alignment: .center) {
            // Feathered shadow on the right of the spine.
            LinearGradient(
                stops: [
                    .init(color: shadow, location: 0.0),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 4)
            .offset(x: 2.5)
            // Highlight on the left of the spine.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: highlight, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 2)
            .offset(x: -1.5)
            // The spine itself.
            Rectangle()
                .fill(Theme.hairlineStrong.opacity(0.45))
                .frame(width: 1)
        }
        .frame(width: 1, height: height)
        .allowsHitTesting(false)
    }

    /// Round any saved/restored `currentPageIndex` down to an even number so
    /// the displayed spread always begins on a left page. If `pageCount` is
    /// 0, returns 0.
    func normalizedLeftIndex(_ raw: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let bounded = max(0, min(raw, pageCount - 1))
        return bounded - (bounded % 2)
    }

    func turnPage(to newIndex: Int, totalPages: Int, useSpread: Bool = true, pages: [PageContent] = [], segment: TextSegment? = nil) {
        let oldLeft: Int
        let newLeft: Int
        if useSpread {
            oldLeft = normalizedLeftIndex(currentPageIndex, pageCount: totalPages)
            newLeft = normalizedLeftIndex(newIndex, pageCount: totalPages)
        } else {
            guard totalPages > 0 else { return }
            oldLeft = max(0, min(currentPageIndex, totalPages - 1))
            newLeft = max(0, min(newIndex, totalPages - 1))
        }
        guard newLeft != oldLeft else { return }
        lastTurnedForward = newLeft > oldLeft

        if animationsEnabled,
           !isAnimatingTransition,
           measuredPageSize.width > 100, measuredPageSize.height > 100 {
            transitionDirection = lastTurnedForward ? .forward : .backward
            transitionProgress = 0
            isAnimatingTransition = true

            Task { @MainActor in
                let totalDuration: TimeInterval = 0.7
                let frameInterval: TimeInterval = 1.0 / 60.0
                let start = Date()
                while true {
                    let elapsed = Date().timeIntervalSince(start)
                    let raw = min(1.0, elapsed / totalDuration)
                    let eased = raw < 0.5
                        ? 4 * raw * raw * raw
                        : 1 - pow(-2 * raw + 2, 3) / 2
                    transitionProgress = eased
                    if raw >= 1.0 { break }
                    try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
                }
                currentPageIndex = newLeft
                isAnimatingTransition = false
            }
            return
        }

        currentPageIndex = newLeft
    }

    /// What the dog-ear overlay should currently render. The reader can be
    /// running its built-in 0.7s commit animation OR (on iPhone) tracking a
    /// finger drag from the page corner. Returns `nil` when neither is live.
    var activeDogEarProgress: (progress: Double, direction: DogEarPageTurn.Direction)? {
        if isAnimatingTransition {
            return (transitionProgress, transitionDirection)
        }
        #if os(iOS)
        if iosDragActive {
            return (iosDragProgress, iosDragDirection)
        }
        #endif
        return nil
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
        let paragraphTexts = currentSegment.map { paragraphs(of: $0.text) } ?? []
        let paragraphWordOffset = wordOffsetForParagraph(paragraphIndex, paragraphs: paragraphTexts)
        // For split paragraphs the displayed text is a chunk; word indices
        // need to count from the chunk's start, not the paragraph's.
        let wordOffset = paragraphWordOffset + chunkWordOffset

        ParagraphRow(
            text: text,
            paragraphIndex: paragraphIndex,
            wordOffset: wordOffset,
            seekEnabled: alignmentMap != nil,
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
                try? modelContext.save()
                annotationRevision &+= 1
            },
            onToggleWord: { localWordIdx in
                toggleWordHighlight(
                    segmentID: segmentID,
                    paragraphIndex: paragraphIndex,
                    wordIndex: localWordIdx
                )
            },
            onPaintWord: { localWordIdx in
                paintWordHighlight(
                    segmentID: segmentID,
                    paragraphIndex: paragraphIndex,
                    wordIndex: localWordIdx
                )
            }
        )
    }

    func seekToWord(segmentID: String, wordOffset: Int, localIndex: Int) {
        guard let map = alignmentMap else {
            attachError = "Alignment map not loaded yet. Run Align first."
            return
        }
        let globalIdx = wordOffset + localIndex

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

    func nearestAnchorAcrossSegments(targetSegmentID: String, map: AlignmentMap) -> WordAnchor? {
        guard let targetIndex = segments.firstIndex(where: { $0.id == targetSegmentID }) else {
            return nil
        }
        let coveredSegments = Set(map.words.map { $0.segmentId })

        // Spiral outward: try preceding chapters first (more useful — gives the
        // user the LAST anchor before their click), then following chapters.
        let maxRadius = max(targetIndex, segments.count - targetIndex - 1)
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

    func tokenizeWords(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
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
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .font(.callout)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                alignment.acknowledgeFinished()
            } label: {
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

    // MARK: - Loading

    func loadEverything() async {
        await loadSegments()
        await loadAudioIfPresent()
        loadAlignmentIfPresent()
        restoreProgress()
        recomputeFlatPageBoundaries()
    }

    /// Walk every chapter and cache its page count at the active word
    /// budget (single-page or spread). The flat sequence of pages is what
    /// the page-curl containers index into, so the user can swipe past
    /// the end of a chapter and land at the next chapter's page 0 with no
    /// gap or reload — the iBooks continuous reading model.
    func recomputeFlatPageBoundaries(useSpread: Bool = false) {
        let budget = wordsBudget(useSpread: useSpread)
        var result: [(String, Int)] = []
        for segment in segments {
            let pages = pageBreaks(for: segment.text, wordsPerPage: budget)
            result.append((segment.id, max(1, pages.count)))
        }
        flatPageBoundaries = result
        flatBoundariesBudget = budget
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
                book.coverImageData = cover
                try? modelContext.save()
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
           segments.contains(where: { $0.id == progress.currentCFI }) {
            // Suppress the chapter-change page reset for this one assignment
            // so the saved page index survives. The flag clears on the next
            // selectedSegmentID change handler.
            isRestoringProgress = true
            selectedSegmentID = progress.currentCFI
            currentPageIndex = max(0, progress.currentPageIndex)
            if progress.currentAudioSeconds > 0 {
                engine.seek(to: progress.currentAudioSeconds)
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
        try? modelContext.save()
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
                currentAudioSeconds: engine.currentTime,
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
        progress.currentAudioSeconds = engine.currentTime
        progress.currentPageIndex = currentPageIndex
        progress.lastReadAt = .now
        try? modelContext.save()
        lastProgressSaveAt = .now
    }

    func loadAudioIfPresent() async {
        guard let url = book.resolvedAudiobookURL else { return }
        do {
            try await engine.load(url: url)
        } catch {
            attachError = "Failed to load audio: \(error.localizedDescription)"
        }
    }

    func loadAlignmentIfPresent() {
        let service = AlignmentService(modelContext: modelContext)
        alignmentMap = service.loadAlignmentMap(for: book)
        rebuildAnchorIndex()
    }

    /// Group `alignmentMap.words` by segment ID once. The audio tick
    /// callback hits this lookup ~10×/sec on a large alignment map; the
    /// pre-sorted variants avoid re-sorting on every tick too. Builds
    /// both an audioIndex-sorted and a startSeconds-sorted view since
    /// `refreshActiveWord` picks between them based on whether the map
    /// has audioWordStarts populated.
    func rebuildAnchorIndex() {
        guard let map = alignmentMap else {
            anchorsBySegment = [:]
            anchorsBySegmentAudioIdx = [:]
            return
        }
        var byStart: [String: [WordAnchor]] = [:]
        var byAudio: [String: [WordAnchor]] = [:]
        for anchor in map.words {
            byStart[anchor.segmentId, default: []].append(anchor)
            if anchor.audioIndex >= 0 {
                byAudio[anchor.segmentId, default: []].append(anchor)
            }
        }
        for k in byStart.keys {
            byStart[k]?.sort { $0.startSeconds < $1.startSeconds }
        }
        for k in byAudio.keys {
            byAudio[k]?.sort { $0.audioIndex < $1.audioIndex }
        }
        anchorsBySegment = byStart
        anchorsBySegmentAudioIdx = byAudio
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
        let service = AlignmentService(modelContext: modelContext)
        if let map = service.loadAlignmentMap(for: book) {
            alignmentMap = map
            rebuildAnchorIndex()
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

    func handleAudioPicked(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task { @MainActor in
                do {
                    let service = ImportService(modelContext: modelContext)
                    try await service.attachAudiobook(url, to: book)
                    // Drop the in-memory alignment too — `attachAudiobook`
                    // already deleted the on-disk JSON and nulled the
                    // book.alignmentMapURL, but the reader holds a
                    // separate cached copy that the page-curl reads for
                    // play-from-here. Without this the UI keeps "Re-align"
                    // available against stale anchors until the next book
                    // open.
                    alignmentMap = nil
                    rebuildAnchorIndex()
                    if let stored = book.resolvedAudiobookURL {
                        try await engine.load(url: stored)
                    }
                } catch {
                    attachError = error.localizedDescription
                }
            }
        case .failure(let error):
            attachError = error.localizedDescription
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
