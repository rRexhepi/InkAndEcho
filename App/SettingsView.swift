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

/// Read-along granularity while an aligned audiobook narrates. Raw value
/// persists under `AppSettings.readAlongModeKey`; readers of the key default
/// through `AppSettings.initialReadAlongModeRaw()`, which migrates the old
/// build-14 bool (true → `.word`) without a write.
enum ReadAlongMode: String, CaseIterable, Identifiable {
    case off
    case word
    case sentence

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:      return "Off"
        case .word:     return "Word"
        case .sentence: return "Sentence"
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
    /// Legacy read-along bool (build ≤ 14) — superseded by `readAlongModeKey`,
    /// kept only as the migration source in `initialReadAlongModeRaw()`.
    static let wordHighlightingKey = "inkandecho.wordHighlighting"
    /// Read-along mode: `ReadAlongMode` raw value (off / word / sentence).
    static let readAlongModeKey = "inkandecho.readAlongMode"

    /// Default for every `readAlongModeKey` @AppStorage declaration: an
    /// unset key falls back to the old bool (true → word), so upgrading
    /// users keep their setting with no write-migration.
    static func initialReadAlongModeRaw() -> String {
        UserDefaults.standard.bool(forKey: wordHighlightingKey)
            ? ReadAlongMode.word.rawValue
            : ReadAlongMode.off.rawValue
    }
    /// Keep the current audiobook playing when you open a different book,
    /// instead of switching the shared engine to the new one.
    static let backgroundAudioKey = "inkandecho.backgroundAudio"
    /// Last playback rate the user picked. A preference, not book state —
    /// re-applied by `AudioCoordinator.load` so a relaunch (fresh engine at
    /// 1×) resumes at the listener's speed. Same key on the Flutter build.
    static let playbackRateKey = "inkandecho.playbackRate"
    /// Aa ladder step for the reading body (index into
    /// `BodyTextMetrics.bodySizes`). Unset = `BodyTextMetrics.defaultStep`,
    /// which snaps Dynamic Type's scaled 17 to the ladder.
    static let typographyStepKey = "inkandecho.typographyStep"

    static func defaultHighlightColor() -> AnnotationColor {
        let raw = UserDefaults.standard.string(forKey: defaultHighlightColorKey) ?? AnnotationColor.amber.rawValue
        return AnnotationColor(rawValue: raw) ?? .amber
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.themeKey) private var themeRaw: String = ThemeChoice.system.rawValue
    @AppStorage(AppSettings.animationsEnabledKey) private var animationsEnabled: Bool = true
    @AppStorage(AppSettings.defaultHighlightColorKey) private var defaultHighlightColorRaw: String = AnnotationColor.amber.rawValue
    @AppStorage(AppSettings.readAlongModeKey) private var readAlongModeRaw: String = AppSettings.initialReadAlongModeRaw()
    @AppStorage(AppSettings.backgroundAudioKey) private var backgroundAudioEnabled: Bool = false

    private var theme: Binding<ThemeChoice> {
        Binding(
            get: { ThemeChoice(rawValue: themeRaw) ?? .system },
            set: { themeRaw = $0.rawValue }
        )
    }

    private var readAlongMode: Binding<ReadAlongMode> {
        Binding(
            get: { ReadAlongMode(rawValue: readAlongModeRaw) ?? .off },
            set: { readAlongModeRaw = $0.rawValue }
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

                HStack {
                    Text("Text size")
                    Spacer()
                    TypographyStepper()
                }
                Text("Reading body size. Pages re-paginate and keep your place.")
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
                Picker("Follow the narration", selection: readAlongMode) {
                    ForEach(ReadAlongMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Word tints each spoken word; Sentence underlines the sentence being read. Needs an aligned audiobook.")
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

/// Shared Aa control: the reader-chrome popover and the Settings row render
/// this same stepper, so the two surfaces can never drift. Writes the step
/// index; `ReaderView` observes the key and re-paginates with a word-anchor
/// remap so the reading position survives the size change.
struct TypographyStepper: View {
    @AppStorage(AppSettings.typographyStepKey) private var step: Int = BodyTextMetrics.defaultStep

    private var clampedStep: Int {
        min(max(0, step), BodyTextMetrics.bodySizes.count - 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            stepButton(delta: -1, glyphSize: 14, label: "Smaller text")
            Text("\(Int(BodyTextMetrics.bodySizes[clampedStep])) pt")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .monospacedDigit()
                .frame(minWidth: 42)
            stepButton(delta: +1, glyphSize: 21, label: "Larger text")
        }
    }

    private func stepButton(delta: Int, glyphSize: CGFloat, label: String) -> some View {
        let target = clampedStep + delta
        return Button {
            step = target
        } label: {
            Text("A")
                .font(.system(size: glyphSize, design: .serif))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 36)
                .background(Theme.canvasDeep.opacity(0.5))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!BodyTextMetrics.bodySizes.indices.contains(target))
        .accessibilityLabel(label)
    }
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
