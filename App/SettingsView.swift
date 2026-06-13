import SwiftUI
import InkAndEchoCore

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// Persisted user preferences, backed by `@AppStorage`. Read these via
/// the property wrappers in any view; writes go straight to `UserDefaults`
/// and propagate through SwiftUI automatically.
enum AppSettings {
    static let themeKey = "inkandecho.theme"
    static let animationsEnabledKey = "inkandecho.animationsEnabled"
    /// Color applied when the user taps / drags to highlight a word.
    static let defaultHighlightColorKey = "inkandecho.defaultHighlightColor"
    /// Tint each word as the audiobook narrates it (read-along).
    static let wordHighlightingKey = "inkandecho.wordHighlighting"
    /// Keep the current audiobook playing when you open a different book,
    /// instead of switching the shared engine to the new one.
    static let backgroundAudioKey = "inkandecho.backgroundAudio"

    static func defaultHighlightColor() -> AnnotationColor {
        let raw = UserDefaults.standard.string(forKey: defaultHighlightColorKey) ?? AnnotationColor.amber.rawValue
        return AnnotationColor(rawValue: raw) ?? .amber
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.themeKey) private var themeRaw: String = ThemeChoice.system.rawValue
    @AppStorage(AppSettings.animationsEnabledKey) private var animationsEnabled: Bool = true
    @AppStorage(AppSettings.defaultHighlightColorKey) private var defaultHighlightColorRaw: String = AnnotationColor.amber.rawValue
    @AppStorage(AppSettings.wordHighlightingKey) private var wordHighlightingEnabled: Bool = false
    @AppStorage(AppSettings.backgroundAudioKey) private var backgroundAudioEnabled: Bool = false

    private var theme: Binding<ThemeChoice> {
        Binding(
            get: { ThemeChoice(rawValue: themeRaw) ?? .system },
            set: { themeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Page-turn animations", isOn: $animationsEnabled)
                Text("Turn off if you prefer instant page changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Highlights") {
                highlightColorRow
                Text("Used when you tap or drag-paint a word.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Read-along") {
                Toggle("Highlight the spoken word", isOn: $wordHighlightingEnabled)
                Text("Tints each word as the audiobook narrates it. Needs an aligned audiobook.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                Toggle("Keep playing across books", isOn: $backgroundAudioEnabled)
                Text("Audiobooks keep playing when you leave a book. On: opening another book leaves the current one playing in the background. Off: opening another audiobook switches to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 460, height: 220)
        #endif
    }

    private var highlightColorRow: some View {
        HStack(spacing: 14) {
            Text("Default color")
            Spacer()
            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button {
                    defaultHighlightColorRaw = color.rawValue
                } label: {
                    Circle()
                        .fill(color.swatch)
                        .overlay(
                            Circle().stroke(
                                color.rawValue == defaultHighlightColorRaw ? Theme.ink : Theme.hairline,
                                lineWidth: color.rawValue == defaultHighlightColorRaw ? 2 : 1
                            )
                        )
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue.capitalized)
            }
        }
    }

    // The old "Restart now" prompt (with `exit(0)`) is gone: the claim that
    // iOS can't refresh an open app's theme was stale — `InkAndEchoApp`'s
    // `applyTheme` pushes `overrideUserInterfaceStyle` to every window with
    // a cross-dissolve, live, the moment the picker changes. Programmatic
    // termination is also an App Review flag.
}

#if os(iOS)
/// iOS-specific Settings surface. Same form fields as the macOS Settings
/// scene, but rendered without the fixed frame so it sits naturally inside
/// a `NavigationStack` form sheet pushed from the reader / library.
struct IOSSettingsView: View {
    var body: some View {
        SettingsView()
    }
}
#endif
