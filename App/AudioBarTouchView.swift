#if os(iOS)
import SwiftUI
import InkAndEchoCore

/// Touch-friendly audio bar used by the iOS reader. Big circular play
/// button, mono-digit time stamps, accent scrubber, and a row of pills
/// for rate / sleep / re-align. The compact variant collapses the bottom
/// pill row so it can sit above the home indicator on iPhone; tapping the
/// row expands into a sheet (handled by the parent).
struct AudioBarTouchView: View {
    let engine: AudioEngine
    var compact: Bool = false
    var onAlign: (() -> Void)? = nil
    var alignmentExists: Bool = false
    var onRequestExpand: (() -> Void)? = nil
    /// Narration end of the current chapter (audio seconds), for the sleep
    /// menu's "End of chapter". A closure so it's read fresh when the menu
    /// opens; nil hides the option (no alignment, no data source).
    var chapterEndTime: (() -> TimeInterval?)? = nil
    /// Why this book's audio failed to load (nil = healthy). When set, the
    /// transport is replaced by the message plus Retry — the old behavior
    /// was a dead or disabled play button with no explanation.
    var loadError: String? = nil
    var onRetry: (() -> Void)? = nil

    /// Sleep timer state lives on the app-level coordinator so it survives
    /// popping the reader and fires from the lock screen.
    @Environment(AudioCoordinator.self) private var audio

    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let sleepMinutes = [15, 30, 45, 60]

    /// Value-change triggers for `.sensoryFeedback`. Local counters (not
    /// `engine.rate`/`currentTime`) so only the bar the user actually tapped
    /// buzzes — the expanded sheet overlays the compact bar, and both watch
    /// the same engine.
    @State private var skipTapCount = 0
    @State private var rateTapCount = 0

    var body: some View {
        VStack(spacing: 0) {
            if compact, onRequestExpand != nil {
                Capsule()
                    .fill(Theme.hairlineStrong.opacity(0.55))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { onRequestExpand?() }
            }
            if let loadError {
                errorRow(loadError)
                    .padding(.horizontal, 16)
                    .padding(.top, compact ? 6 : 12)
                    .padding(.bottom, compact ? 14 : 16)
            } else {
                transportRow
                    .padding(.horizontal, 16)
                    .padding(.top, compact ? 6 : 12)
                    .padding(.bottom, compact ? 14 : 12)
                if !compact {
                    pillRow
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .background(Theme.canvasCool)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
        .sensoryFeedback(.impact(weight: .light), trigger: skipTapCount)
        .sensoryFeedback(.selection, trigger: rateTapCount)
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            playPause(size: compact ? 44 : 52)
            if compact {
                // Inline skips: the compact bar had no way to jump ±15 s
                // without expanding the sheet. Tight spacing (buttons keep
                // their 44 pt targets) leaves ~180 pt of scrubber at 375 pt.
                HStack(spacing: 2) {
                    skipButton(seconds: -15, symbol: "gobackward.15")
                    skipButton(seconds: 15, symbol: "goforward.15")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !compact {
                    HStack(spacing: 8) {
                        skipButton(seconds: -15, symbol: "gobackward.15")
                        skipButton(seconds: 15, symbol: "goforward.15")
                        Spacer(minLength: 0)
                    }
                }
                ScrubberRow(engine: engine)
            }
        }
    }

    private var pillRow: some View {
        HStack(spacing: 8) {
            rateMenu
            sleepMenu
            if let onAlign {
                Button {
                    onAlign()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 12, weight: .semibold))
                        Text(alignmentExists ? "Re-align" : "Align")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func playPause(size: CGFloat) -> some View {
        Button {
            if engine.state == .playing {
                engine.pause()
            } else {
                try? engine.play()
            }
        } label: {
            Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: size, height: size)
                .background(Theme.accent)
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(engine.state == .idle || engine.state == .loading)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent)
                        .foregroundStyle(Theme.onAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func skipButton(seconds: TimeInterval, symbol: String) -> some View {
        Button {
            let target = max(0, min(engine.duration, engine.currentTime + seconds))
            engine.seek(to: target)
            skipTapCount += 1
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(engine.duration <= 0)
    }

    private var rateMenu: some View {
        Menu {
            ForEach(rates, id: \.self) { rate in
                Button {
                    engine.setRate(rate)
                    UserDefaults.standard.set(Double(rate), forKey: AppSettings.playbackRateKey)
                    rateTapCount += 1
                } label: {
                    HStack {
                        Text(formatRate(rate))
                        if abs(engine.rate - rate) < 0.001 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(formatRate(engine.rate))
                .font(.system(size: 13, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.canvasDeep.opacity(0.5))
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
    }

    private var sleepMenu: some View {
        Menu {
            Button {
                audio.cancelSleepTimer()
            } label: {
                HStack {
                    Text("Off")
                    if audio.sleepTarget == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            ForEach(sleepMinutes, id: \.self) { minutes in
                Button("\(minutes) min") {
                    audio.setSleepTimer(minutes: minutes)
                }
            }
            // Only when aligned AND the chapter end is still ahead — arming
            // a target the playhead already passed would fire within a tick.
            if let end = chapterEndTime?(), end > engine.currentTime + 1 {
                Button("End of chapter") {
                    audio.setSleepTimer(untilAudioTime: end)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 11, weight: .semibold))
                Text(sleepLabel)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(audio.sleepTarget == nil ? Theme.inkSoft : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.canvasDeep.opacity(0.5))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
    }

    private var sleepLabel: String {
        guard let left = audio.sleepRemainingSeconds else { return "Sleep · off" }
        let total = max(0, Int(left))
        // Ceil to whole minutes so a fresh "15 min" pick reads 15m, not 14m.
        return total >= 60 ? "Sleep · \((total + 59) / 60)m" : "Sleep · \(total)s"
    }

    private func formatRate(_ rate: Float) -> String {
        // `%g`, not `%.2g`: two significant digits truncated 1.25 to "1.2×"
        // in the pill and menu while actually playing 1.25×.
        rate == floor(rate) ? "\(Int(rate))×" : String(format: "%g×", rate)
    }
}

/// Reads `engine.currentTime` off a 3 Hz timer into local `@State` instead
/// of directly in body, so the audio bar doesn't re-render at the engine's
/// 10 Hz tick rate (CoreAnimation fought with ScrollView scrolling and
/// PVC gesture handling during playback).
private struct ScrubberRow: View {
    let engine: AudioEngine
    @State private var displayTime: TimeInterval = 0
    @State private var displayDuration: TimeInterval = 0.001
    @State private var isScrubbing = false

    private static let tickInterval: TimeInterval = 1.0 / 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Seek ONLY on release. SwiftUI fires the value setter for every
            // thumb movement, and each `engine.seek` is a full
            // stop + reschedule + play — dozens per second of drag stuttered
            // like a machine gun and spammed stop-fired completion handlers.
            Slider(
                value: Binding(
                    get: { min(displayTime, displayDuration) },
                    set: { displayTime = $0 }
                ),
                in: 0...displayDuration,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        engine.seek(to: displayTime)
                    }
                }
            )
            .tint(Theme.accent)
            .disabled(displayDuration <= 0.001)
            HStack {
                Text(formatTime(displayTime))
                Spacer()
                Text(formatTime(displayDuration))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.inkMuted)
            .monospacedDigit()
        }
        .onAppear { syncFromEngine() }
        .onReceive(Timer.publish(every: Self.tickInterval, on: .main, in: .common).autoconnect()) { _ in
            syncFromEngine()
        }
    }

    private func syncFromEngine() {
        // Don't fight the user's thumb mid-drag.
        guard !isScrubbing else { return }
        displayTime = engine.currentTime
        displayDuration = max(engine.duration, 0.001)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
#endif
