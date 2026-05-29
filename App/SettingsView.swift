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

    /// Theme value as the sheet was first opened. Used on iOS to detect
    /// "user changed the theme" so we can show the restart prompt — iOS
    /// doesn't reliably refresh the entire app's color scheme without a
    /// relaunch, even with `UIWindow.overrideUserInterfaceStyle`.
    @State private var themeAtOpen: String?

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

                #if os(iOS)
                if let opened = themeAtOpen, opened != themeRaw {
                    restartPrompt
                }
                #endif

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
        }
        .formStyle(.grouped)
        .onAppear {
            if themeAtOpen == nil { themeAtOpen = themeRaw }
        }
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

    #if os(iOS)
    /// Inline notice that appears the moment the user picks a different
    /// theme than the one in effect when Settings opened. Tapping the
    /// "Restart now" button calls `exit(0)` to terminate; iOS relaunches
    /// the app on next icon tap with the new theme baked in. Honest about
    /// the limitation rather than pretending the swap is instant.
    private var restartPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restart Ink and Echo to apply.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("iOS doesn't refresh the theme of an open app. Tap the button to close it now, then reopen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                exit(0)
            } label: {
                Text("Restart now")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
    #endif
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
