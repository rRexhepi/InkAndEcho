import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import InkAndEchoCore

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AlignmentCoordinator.self) private var alignment
    @Environment(AudioCoordinator.self) private var audio
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @State private var selectedBook: Book?
    @State private var showingImporter = false
    @State private var importing = false
    @State private var importError: String?
    @State private var showSettings = false
    @State private var showSourceGuide = false
    @AppStorage("inkandecho.lastOpenedBookID") private var lastOpenedBookID: String = ""
    @AppStorage("inkandecho.hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        rootLayout
            .background(Theme.canvas)
            .onAppear {
                restoreLastBookIfNeeded()
            }
            .onChange(of: selectedBook) { _, newValue in
                if let book = newValue {
                    lastOpenedBookID = book.id.uuidString
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: importContentTypes
            ) { result in
                handleImportPicker(result)
            }
            // "Open in Ink and Echo" from Files / Mail / Safari. The app
            // declares CFBundleDocumentTypes for these formats; without this
            // handler the system launches the app and the URL silently
            // vanishes.
            .onOpenURL { url in
                handleOpenURL(url)
            }
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
                // The DRM churn moment: a failed import is where users
                // discover their store purchase isn't a file. Point at
                // sources that are.
                Button("Where to find books") {
                    importError = nil
                    showSourceGuide = true
                }
            } message: {
                Text(importError ?? "")
            }
            .sheet(isPresented: $showSourceGuide) {
                SourceGuideView()
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { _ in }
            )) {
                OnboardingView(onFinish: {
                    hasCompletedOnboarding = true
                    showingImporter = true
                })
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    IOSSettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
    }

    private var rootLayout: some View {
        NavigationStack {
            iosLibraryGrid
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(item: $selectedBook) { book in
                    ReaderView(book: book)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingImporter = true
                        } label: {
                            if importing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .disabled(importing)
                        .tint(Theme.accent)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 16))
                        }
                        .tint(Theme.inkSoft)
                    }
                }
        }
        .tint(Theme.accent)
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var iosLibraryGrid: some View {
        grid.safeAreaInset(edge: .bottom, spacing: 0) {
            // Now-playing bar: the shared engine keeps playing in the library;
            // this is the way back to the playing book. Hidden when nothing
            // is loaded. A pushed reader covers it (inset is on the root).
            if audio.hasAudio {
                LibraryMiniPlayer(
                    title: audio.loadedTitle,
                    author: audio.loadedAuthor,
                    coverData: audio.loadedCoverData,
                    engine: audio.engine,
                    onOpen: {
                        if let id = audio.loadedBookID {
                            selectedBook = books.first(where: { $0.id == id })
                        }
                    }
                )
            }
        }
    }

    private var grid: some View {
        Group {
            if books.isEmpty {
                LibraryEmptyState(onImport: { showingImporter = true })
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 28) {
                        ForEach(books) { book in
                            Button {
                                selectedBook = book
                            } label: {
                                BookCard(book: book)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteBook(book)
                                } label: {
                                    Label("Remove from Library", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }
            }
        }
        .background(Theme.canvas)
    }

    private var gridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: count)
    }

    /// AZW3 / KF8 deliberately omitted — the in-tree MOBI parser throws on KF8.
    private var importContentTypes: [UTType] {
        var types: [UTType] = [.epub, .pdf]
        if let mobi = UTType(filenameExtension: "mobi") { types.append(mobi) }
        if let prc = UTType(filenameExtension: "prc") { types.append(prc) }
        if let azw = UTType(filenameExtension: "azw") { types.append(azw) }
        return types
    }

    private func handleImportPicker(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            importBook(at: url)
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// Shared by the file picker and "Open in…" URLs.
    private func importBook(at url: URL) {
        Task { @MainActor in
            importing = true
            defer { importing = false }
            do {
                let service = ImportService(modelContext: modelContext)
                let book = try await service.importBook(from: url)
                selectedBook = book
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func handleOpenURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let audioExtensions: Set<String> = ["m4b", "m4a", "mp3"]
        if audioExtensions.contains(ext) {
            // Audiobooks attach to a book, they aren't books — there's no
            // sensible standalone import. Tell the user where the flow lives.
            importError = "Audiobooks attach from inside a book: open the book, then tap “Attach audiobook”."
        } else {
            importBook(at: url)
        }
    }

    private func deleteBook(_ book: Book) {
        if selectedBook == book {
            selectedBook = nil
            lastOpenedBookID = ""
        }
        // A WhisperKit job for a deleted book would otherwise grind on for
        // up to half an hour, then fail into a global error alert — while
        // blocking the single alignment slot the whole time.
        if alignment.isRunning(for: book.id) {
            alignment.cancel()
        }
        // If the shared engine is playing this book, stop it — its file is
        // about to be deleted out from under the player.
        audio.unload(ifBookID: book.id)
        let service = ImportService(modelContext: modelContext)
        do {
            try service.deleteBook(book)
        } catch {
            importError = "Couldn't remove the book: \(error.localizedDescription)"
        }
    }

    private func restoreLastBookIfNeeded() {
        guard selectedBook == nil,
              !lastOpenedBookID.isEmpty,
              let uuid = UUID(uuidString: lastOpenedBookID),
              let match = books.first(where: { $0.id == uuid }) else { return }
        selectedBook = match
    }
}

/// Now-playing bar pinned to the bottom of the library. Tapping the bar opens
/// the playing book; the trailing button toggles play/pause. Scoped as its
/// own view so reading `engine.state` re-renders only this strip, not the
/// whole grid. No live scrubber here, so it doesn't subscribe to the 30 Hz
/// `currentTime` tick.
private struct LibraryMiniPlayer: View {
    let title: String
    let author: String
    let coverData: Data?
    var engine: AudioEngine
    let onOpen: () -> Void

    private var isPlaying: Bool { engine.state == .playing }

    var body: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(author)
                    .font(.system(size: 11, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                if isPlaying { engine.pause() } else { try? engine.play() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    @ViewBuilder
    private var cover: some View {
        if let coverData, let image = Image(platformData: coverData) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.canvasDeep)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "headphones")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkMuted)
                )
        }
    }
}

private struct BookCard: View {
    let book: Book
    @Environment(AlignmentCoordinator.self) private var alignment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
                .overlay(alignment: .bottomLeading) {
                    if alignment.isRunning(for: book.id) {
                        aligningBadge
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 14, design: .serif))
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(book.author)
                    .font(.system(size: 11, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                if book.audiobookFileURL == nil {
                    Text("NO AUDIO")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Pill overlaid on the cover when the app-level alignment coordinator
    /// has a job in flight for this book. Tapping the row still navigates
    /// into the reader where the running banner shows live progress.
    private var aligningBadge: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).tint(Theme.onAccent)
            Text("Aligning…")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.accent.opacity(0.92))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var cover: some View {
        if let data = book.coverImageData, let image = Image(platformData: data) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
        } else {
            generatedCover
        }
    }

    private var generatedCover: some View {
        // Stable FNV-1a, not `hashValue`: String hashing is seeded per
        // process, so placeholder cover colors reshuffled every launch (and
        // `abs(Int.min)` traps, however unlikely).
        let digest = book.title.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        let hue = Double(digest % 360)
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        Color(hue: hue / 360, saturation: 0.35, brightness: 0.45),
                        Color(hue: hue / 360, saturation: 0.45, brightness: 0.30),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title)
                        .font(.system(size: 14, design: .serif))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(3)
                    Spacer()
                    Text(book.author)
                        .font(.system(size: 9, design: .serif))
                        .italic()
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                }
                .padding(14)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .aspectRatio(2.0/3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}

/// Empty-library state for iOS, modeled on `Screens.html`. Ghost shelf of
/// dashed silhouettes, headline, supporting prose, and a saddle-accent
/// "Import a book" CTA.
private struct LibraryEmptyState: View {
    let onImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ghostShelf
                    .padding(.top, 60)
                Text("Your library is quiet.")
                    .font(.system(size: 24, design: .serif))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                Text("Add an ebook and its audiobook. Ink and Echo will transcribe the audio on this device and align it to the text. No upload, no account.")
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button(action: onImport) {
                    Text("Import a book")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Text(".epub + .m4b")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.top, 4)
                Text("about 30 min to align a typical novel")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                Spacer(minLength: 60)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var ghostShelf: some View {
        HStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.canvasCool)
                    )
                    .frame(width: 70, height: 96)
                    .opacity(0.45 + Double(i) * 0.05)
            }
        }
    }
}
