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

    private let container: ModelContainer = Self.makeContainer()

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
            .onAppear { applyTheme(theme) }
            .onChange(of: themeRaw) { _, newRaw in
                let newChoice = ThemeChoice(rawValue: newRaw) ?? .system
                applyTheme(newChoice)
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
            backUpDefaultStore()
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
    private static func backUpDefaultStore() {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let stamp = Int(Date.now.timeIntervalSince1970)
        for suffix in ["", "-shm", "-wal"] {
            let src = support.appendingPathComponent("default.store\(suffix)")
            let dst = support.appendingPathComponent("default.store.backup-\(stamp)\(suffix)")
            try? fm.moveItem(at: src, to: dst)
        }
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
