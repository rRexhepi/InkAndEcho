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

    private var theme: ThemeChoice {
        ThemeChoice(rawValue: themeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup("Ink and Echo") {
            MigrationGate {
                LibraryView()
                    .environment(alignment as AlignmentCoordinator?)
            }
            .onAppear { applyTheme(theme) }
            .onChange(of: themeRaw) { _, newRaw in
                let newChoice = ThemeChoice(rawValue: newRaw) ?? .system
                applyTheme(newChoice)
            }
        }
        .modelContainer(for: [Book.self, Annotation.self, ReadingProgress.self])
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
