import SwiftUI
import SwiftData
import UIKit
import InkAndEchoCore

@main
struct InkAndEchoApp: App {
    @AppStorage(AppSettings.themeKey) private var themeRaw: String = ThemeChoice.system.rawValue
    /// One alignment job per app session. Outlives any single `ReaderView`
    /// so backing out of a book mid-alignment doesn't cancel the work or
    /// hide its progress.
    @State private var alignment = AlignmentCoordinator()
    /// The single shared audio engine, owned for the whole session so
    /// playback survives leaving a reader. Injected via environment; every
    /// `ReaderView` and the library mini-player read this one instance.
    @State private var audio = AudioCoordinator()
    /// Drives the one-time "library was reset" notice. Set in `onAppear`
    /// from the static below, which `makeContainer()` fills only on the
    /// launch where recovery actually happened.
    @State private var showStoreRecoveryNotice = false

    private let container: ModelContainer = Self.makeContainer()

    /// Where `makeContainer()` parked the unopenable store this launch, if it
    /// had to. Static because recovery runs before any view exists.
    private static var storeRecoveryBackupURL: URL?

    private var theme: ThemeChoice {
        ThemeChoice(rawValue: themeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup("Ink and Echo") {
            MigrationGate {
                LibraryView()
                    .environment(alignment as AlignmentCoordinator?)
                    .environment(audio)
            }
            .onAppear {
                applyTheme(theme)
                showStoreRecoveryNotice = Self.storeRecoveryBackupURL != nil
            }
            .onChange(of: themeRaw) { _, newRaw in
                let newChoice = ThemeChoice(rawValue: newRaw) ?? .system
                applyTheme(newChoice)
            }
            .sheet(isPresented: $showStoreRecoveryNotice) {
                if let url = Self.storeRecoveryBackupURL {
                    StoreRecoveryNotice(backupURL: url)
                }
            }
        }
        .modelContainer(container)
    }

    /// The only place a ModelContainer is constructed. Versioned (V1 = as
    /// shipped in build 11, V2 = current) with a lightweight migration plan,
    /// and a recovery path: the `.modelContainer(for:)` modifier fatalErrors
    /// on any container failure, which turns one bad migration into a
    /// permanent crash loop where delete-and-reinstall is the only way out.
    /// Here a failed open moves the store aside (kept as a timestamped
    /// backup, never silently destroyed) and starts fresh.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: InkAndEchoSchemaV2.self)
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: InkAndEchoMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema)]
            )
        } catch {
            print("InkAndEcho: store open failed (\(error)); backing up store and starting fresh.")
            storeRecoveryBackupURL = backUpDefaultStore()
            do {
                return try ModelContainer(
                    for: schema,
                    migrationPlan: InkAndEchoMigrationPlan.self,
                    configurations: [ModelConfiguration(schema: schema)]
                )
            } catch {
                fatalError("InkAndEcho: unrecoverable SwiftData failure: \(error)")
            }
        }
    }

    /// Move `default.store` (+ -shm/-wal sidecars) to timestamped backups so
    /// a fresh store can be created without destroying the user's data.
    /// Returns the main store's backup URL for the recovery notice's
    /// ShareLink — Application Support is unreachable on iOS, so the share
    /// sheet is the user's only path to the file.
    private static func backUpDefaultStore() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let stamp = Int(Date.now.timeIntervalSince1970)
        var backupURL: URL?
        for suffix in ["", "-shm", "-wal"] {
            let src = support.appendingPathComponent("default.store\(suffix)")
            let dst = support.appendingPathComponent("default.store.backup-\(stamp)\(suffix)")
            if (try? fm.moveItem(at: src, to: dst)) != nil, suffix.isEmpty {
                backupURL = dst
            }
        }
        return backupURL
    }
}

/// One-time notice after `makeContainer()` reset an unopenable store. The
/// old behavior was silent: annotations and positions vanished with no
/// acknowledgment that a backup even exists.
private struct StoreRecoveryNotice: View {
    let backupURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.top, 32)
            Text("Your library was reset")
                .font(.system(.title3, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.ink)
            Text("The library database couldn't be opened, so a fresh one was created. Book and audio files are untouched, but annotations and reading positions from the old database live in a backup file — save it somewhere safe if you want to attempt recovery.")
                .font(.system(.callout, design: .serif))
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            ShareLink(item: backupURL) {
                Label("Save backup file…", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .clipShape(Capsule())
            }
            .padding(.top, 6)
            Button("Continue") { dismiss() }
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkMuted)
                .padding(.bottom, 28)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.canvas)
        .presentationDetents([.medium])
    }
}

/// Push the chosen theme down to every UIWindow's
/// `overrideUserInterfaceStyle`. SwiftUI's `.preferredColorScheme` modifier
/// is unreliable mid-session: changes to `@AppStorage` re-evaluate the
/// modifier, but UIKit caches the appearance trait and the surface only
/// flips on next scene presentation. Walking the windows directly forces
/// every presented sheet, navigation stack, and reader chrome to update on
/// the same runloop turn the theme picker fires. Works the same way under
/// Mac Catalyst — Catalyst's NSWindow wraps a UIWindow that responds to
/// `overrideUserInterfaceStyle` exactly like iOS.
@MainActor
fileprivate func applyTheme(_ choice: ThemeChoice) {
    let style: UIUserInterfaceStyle
    switch choice {
    case .system: style = .unspecified
    case .light:  style = .light
    case .dark:   style = .dark
    }
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
            UIView.transition(
                with: window,
                duration: 0.25,
                options: .transitionCrossDissolve,
                animations: { window.overrideUserInterfaceStyle = style },
                completion: nil
            )
        }
    }
}
