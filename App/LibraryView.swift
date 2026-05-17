import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PalimpsestCore

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @State private var selectedBook: Book?
    @State private var showingImporter = false
    @State private var importing = false
    @State private var importError: String?
    @State private var showSettings = false
    @AppStorage("palimpsest.lastOpenedBookID") private var lastOpenedBookID: String = ""
    @AppStorage("palimpsest.hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

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
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
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
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func deleteBook(_ book: Book) {
        if selectedBook == book {
            selectedBook = nil
            lastOpenedBookID = ""
        }
        let service = ImportService(modelContext: modelContext)
        try? service.deleteBook(book)
    }

    private func restoreLastBookIfNeeded() {
        guard selectedBook == nil,
              !lastOpenedBookID.isEmpty,
              let uuid = UUID(uuidString: lastOpenedBookID),
              let match = books.first(where: { $0.id == uuid }) else { return }
        selectedBook = match
    }
}

private struct BookCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
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
        let hue = Double(abs(book.title.hashValue) % 360)
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
                Text("Add an ebook and its audiobook. Palimpsest will transcribe the audio on this device and align it to the text. No upload, no account.")
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
