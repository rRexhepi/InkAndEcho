import Foundation
import AVFoundation
import Observation

/// Pitch-preserving audiobook player. Wraps AVAudioEngine + AVAudioUnitTimePitch
/// so playback rate (0.5x – 2.0x) time-stretches without changing pitch.
///
/// Time tracking note: `currentTime` is the *source position* in the audio file
/// (not wall-clock since play). At rate=2.0, currentTime advances at 2x wall-clock.
/// Baseline is reset on seek and on rate change so the calculation stays correct
/// across user actions.
@MainActor
@Observable
public final class AudioEngine {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case playing
        case paused
        case error(String)
    }

    public static let minRate: Float = 0.5
    public static let maxRate: Float = 2.0

    public private(set) var state: State = .idle
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var rate: Float = 1.0

    /// Wall-clock latency between the engine rendering a sample and the user
    /// actually hearing it through the output device. Includes the TimePitch
    /// unit's intrinsic processing delay (which dominates at higher rates) plus
    /// the output device buffer. UI consumers should subtract
    /// `outputLatency × rate` from `currentTime` when projecting onto
    /// audio-word timestamps so highlighting matches what's audible.
    public var outputLatency: TimeInterval {
        timePitch.latency + engine.outputNode.presentationLatency
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?

    private var seekOffsetSeconds: TimeInterval = 0
    private var baselineSampleTime: AVAudioFramePosition = 0
    private var baselineRate: Float = 1.0

    private var displayTimer: Timer?

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        // Max overlap: cleaner time-stretch at 1.5×/2× narration. CPU
        // cost is negligible on every iOS device that ships this app.
        timePitch.overlap = 32
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        Self.configureAudioSessionIfNeeded()
    }

    /// Without `.playback` category iOS defaults to `.soloAmbient`, which
    /// honors the silent switch and refuses to route to the output device
    /// for an AVAudioEngine — the engine "plays" but no sound emerges.
    /// `.spokenAudio` mode is the correct profile for audiobooks: ducks
    /// other audio appropriately and pairs with `UIBackgroundModes=audio`
    /// for lock-screen playback.
    private static var didConfigureSession = false
    private static func configureAudioSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Falling through is fine — playback will still attempt with
            // whatever the system default is.
            print("AudioEngine: AVAudioSession setup failed: \(error)")
        }
        #endif
    }

    public func load(url: URL) async throws {
        state = .loading
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            duration = Double(file.length) / file.processingFormat.sampleRate
            currentTime = 0
            seekOffsetSeconds = 0
            baselineSampleTime = 0
            baselineRate = rate
            scheduleFromStart()
            state = .ready
        } catch {
            audioFile = nil
            state = .error("Failed to load audio: \(error.localizedDescription)")
            throw error
        }
    }

    public func play() throws {
        guard audioFile != nil else { throw AudioEngineError.notLoaded }
        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
        state = .playing
        startDisplayTimer()
    }

    public func pause() {
        guard state == .playing else { return }
        snapshotPosition()
        player.pause()
        state = .paused
        stopDisplayTimer()
    }

    public func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }
        let clamped = max(0, min(time, duration))
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(clamped * sampleRate)
        let frameCount = AVAudioFrameCount(max(0, file.length - startFrame))

        let wasPlaying = (state == .playing)
        player.stop()
        seekOffsetSeconds = clamped
        baselineSampleTime = 0
        baselineRate = rate
        currentTime = clamped

        guard frameCount > 0 else {
            state = wasPlaying ? .paused : state
            stopDisplayTimer()
            return
        }

        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil) { [weak self] in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }

        if wasPlaying {
            try? play()
        }
    }

    public func setRate(_ newRate: Float) {
        let clamped = max(Self.minRate, min(newRate, Self.maxRate))
        guard clamped != rate else { return }
        snapshotPosition()
        rate = clamped
        timePitch.rate = clamped
        baselineRate = clamped
    }

    private func scheduleFromStart() {
        guard let file = audioFile else { return }
        player.stop()
        baselineSampleTime = 0
        player.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }
    }

    private func snapshotPosition() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return }
        let elapsed = Double(playerTime.sampleTime - baselineSampleTime) / playerTime.sampleRate
        seekOffsetSeconds = min(duration, seekOffsetSeconds + elapsed * Double(baselineRate))
        baselineSampleTime = playerTime.sampleTime
    }

    private func handlePlaybackEnded() {
        guard currentTime >= duration - 0.05 else { return }
        currentTime = duration
        state = .paused
        stopDisplayTimer()
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        // 10 Hz. The audio bar / scrubber doesn't need finer than this
        // perceptually, and every tick fires SwiftUI body invalidation +
        // `onChange(of: currentTime)` consumers. At 60 Hz, the
        // active-word recomputation on a large alignment map (10s of
        // thousands of anchors) blocks the main thread enough to freeze
        // the reader while audio is playing.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCurrentTime() }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tickCurrentTime() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return }
        let elapsed = Double(playerTime.sampleTime - baselineSampleTime) / playerTime.sampleRate
        currentTime = min(duration, seekOffsetSeconds + elapsed * Double(baselineRate))
    }
}

public enum AudioEngineError: Error, Sendable {
    case notLoaded
}
