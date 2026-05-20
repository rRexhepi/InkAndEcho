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

    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

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
        .background(Theme.canvasCool)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            playPause(size: compact ? 44 : 52)
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
            sleepPill
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

    private func skipButton(seconds: TimeInterval, symbol: String) -> some View {
        Button {
            let target = max(0, min(engine.duration, engine.currentTime + seconds))
            engine.seek(to: target)
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

    private var sleepPill: some View {
        // Sleep timer is a placeholder — UI affordance only for now.
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 11, weight: .semibold))
            Text("Sleep · off")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.inkSoft)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.canvasDeep.opacity(0.5))
        .clipShape(Capsule())
    }

    private func formatRate(_ rate: Float) -> String {
        rate == floor(rate) ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }
}

/// Isolated so the 10 Hz `engine.currentTime` ticks only invalidate this
/// view, not the whole audio bar (rate menu / play button stay stable).
private struct ScrubberRow: View {
    let engine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(engine.currentTime, max(engine.duration, 0.001)) },
                    set: { engine.seek(to: $0) }
                ),
                in: 0...max(engine.duration, 0.001)
            )
            .tint(Theme.accent)
            .disabled(engine.duration <= 0)
            HStack {
                Text(formatTime(engine.currentTime))
                Spacer()
                Text(formatTime(engine.duration))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.inkMuted)
            .monospacedDigit()
        }
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
