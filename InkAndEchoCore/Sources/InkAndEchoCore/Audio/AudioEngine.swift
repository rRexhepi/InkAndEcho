import Foundation
import AVFoundation
import Observation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

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

    // `var`, not `let`: a media-services reset (mediaserverd crash) leaves the
    // whole graph dead and the only recovery is to discard and recreate every
    // audio object. `rebuildAudioGraph()` reassigns these.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    /// Kept so the file can be reopened after a media-services reset (the old
    /// `AVAudioFile` belongs to the dead media server).
    private var audioURL: URL?

    private var seekOffsetSeconds: TimeInterval = 0
    private var baselineSampleTime: AVAudioFramePosition = 0

    /// Invalidated in `deinit` (legal: deinit has exclusive access to stored
    /// properties, and SwiftUI deallocates the engine on the main thread).
    /// Without that hook, popping the reader mid-playback strands a
    /// repeating 30 Hz timer in the main run loop for the rest of the
    /// process.
    private var displayTimer: Timer?
    /// Unregistered in `deinit`, or NotificationCenter keeps the observer
    /// blocks alive forever.
    private var notificationTokens: [NSObjectProtocol] = []
    /// Remote-command registrations, removed in `deinit`. Without removal,
    /// each reader session would stack another (weak-self, so inert but
    /// accumulating) handler on the shared command center.
    private var commandTokens: [(MPRemoteCommand, Any)] = []
    /// Static metadata (title / artist / artwork) for the lock screen;
    /// playback fields are merged in by `updateNowPlayingPlayback`.
    private var nowPlayingBase: [String: Any] = [:]

    public init() {
        buildGraph()
        Self.configureAudioSessionIfNeeded()
        registerSystemObservers()
        configureRemoteCommands()
    }

    /// Wire the current `engine`/`player`/`timePitch` together. Called from
    /// `init` and after `rebuildAudioGraph()` replaces the nodes, so the
    /// rebuilt graph matches the original exactly — including restoring the
    /// user's playback `rate` (a fresh `AVAudioUnitTimePitch` defaults to 1×).
    private func buildGraph() {
        engine.attach(player)
        engine.attach(timePitch)
        // Max overlap: cleaner time-stretch at 1.5×/2× narration. CPU
        // cost is negligible on every iOS device that ships this app.
        timePitch.overlap = 32
        timePitch.rate = rate
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }

    /// Discard the dead graph and stand up a fresh one. Only the audio
    /// objects are recreated here; the caller restores file scheduling and
    /// playback state.
    private func rebuildAudioGraph() {
        engine.stop()          // best-effort; the graph is already dead
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        timePitch = AVAudioUnitTimePitch()
        buildGraph()
    }

    deinit {
        // The engine lives in SwiftUI `@State`, which releases on the main
        // thread, so assuming isolation here is sound — and it's the only
        // way deinit (nonisolated) may touch the isolated stored properties.
        MainActor.assumeIsolated {
            displayTimer?.invalidate()
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            for (command, token) in commandTokens {
                command.removeTarget(token)
            }
        }
    }

    /// Without `.playback` category iOS defaults to `.soloAmbient`, which
    /// honors the silent switch and refuses to route to the output device
    /// for an AVAudioEngine — the engine "plays" but no sound emerges.
    /// `.spokenAudio` mode is the correct profile for audiobooks: ducks
    /// other audio appropriately and pairs with `UIBackgroundModes=audio`
    /// for lock-screen playback.
    ///
    /// Category only — activation waits for `play()`. Activating a
    /// `.playback` session interrupts whatever the user is already
    /// listening to, and the reader constructs an engine for every book,
    /// audiobook or not; opening a text-only book must not silence Music.
    private static var didConfigureSession = false
    private static func configureAudioSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            // Falling through is fine — playback will still attempt with
            // whatever the system default is.
            print("AudioEngine: AVAudioSession setup failed: \(error)")
        }
        #endif
    }

    private static var didActivateSession = false
    private static func activateSessionIfNeeded() {
        guard !didActivateSession else { return }
        didActivateSession = true
        #if os(iOS) || targetEnvironment(macCatalyst)
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("AudioEngine: AVAudioSession activation failed: \(error)")
        }
        #endif
    }

    /// A phone call / Siri stops AVAudioEngine out from under us, and pulling
    /// headphones keeps playing on the loudspeaker. Without these observers
    /// the state stays `.playing` with no audio — pause button, frozen time,
    /// silence — until the user toggles play twice.
    private func registerSystemObservers() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        // Raw UInts are extracted in the (nonisolated) observer closure so
        // only Sendable values cross into the MainActor hop — the userInfo
        // dictionary itself isn't Sendable.
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        })
        // mediaserverd crashed and restarted: every audio object is invalid.
        // Object is nil (system-wide notification, not session-scoped).
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        })
        #endif
    }

    #if os(iOS) || targetEnvironment(macCatalyst)
    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let raw = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if options.contains(.shouldResume), state == .paused {
                try? play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let raw = reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones unplugged / AirPods out of ears: pause rather than
        // blasting the loudspeaker — the platform convention.
        if reason == .oldDeviceUnavailable, state == .playing {
            pause()
        }
    }

    /// mediaserverd restarted — the engine, player, time-pitch unit, audio
    /// session, and the open `AVAudioFile` are all dead. Rebuild the entire
    /// graph and resume from the current position. Cannot be exercised in the
    /// simulator; on device it's Settings ▸ Developer ▸ Reset Media Services,
    /// or a real mediaserverd crash.
    private func handleMediaServicesReset() {
        let wasPlaying = (state == .playing)
        let resumeAt = currentTime
        stopDisplayTimer()
        rebuildAudioGraph()

        // The shared session went down with the media server: re-arm the
        // one-shot configure/activate guards and re-apply the category.
        // `play()` reactivates if we resume.
        Self.didConfigureSession = false
        Self.didActivateSession = false
        Self.configureAudioSessionIfNeeded()

        // The old file handle belonged to the dead media server; reopen.
        if let url = audioURL {
            audioFile = try? AVAudioFile(forReading: url)
        }
        guard audioFile != nil else {
            // Reopen failed: drop to a clean unloaded state AND clear the
            // lock-screen tile. `nowPlayingInfo` is only ever written, never
            // cleared, so leaving it would keep a controllable-looking but
            // dead tile pointing at the old book.
            currentTime = 0
            duration = 0
            state = .idle
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        // Re-queue from where playback was and restore transport state.
        _ = scheduleSegment(at: resumeAt)
        // `play()` sets `state = .playing` only AFTER `try engine.start()`,
        // which is likely to throw while mediaserverd is still settling right
        // after the reset. A bare `try?` there would swallow the failure and
        // strand a zombie `.playing` (timer already stopped, silence, pause
        // button shown) — the exact failure this whole path exists to kill.
        // Catch it and fall back to a coherent `.paused`. And if the reset
        // landed in the final 50 ms, skip the resume entirely: `play()`'s
        // EOF-rearm would `seek(to: 0)` and replay the whole book from the
        // start instead of ending paused at EOF.
        let atEOF = duration > 0 && resumeAt >= duration - 0.05
        if wasPlaying && !atEOF {
            do {
                try play()
            } catch {
                state = .paused
                updateNowPlayingPlayback()
            }
        } else {
            currentTime = atEOF ? duration : currentTime
            state = .paused
            updateNowPlayingPlayback()
        }
    }
    #endif

    // MARK: - Now Playing / remote commands

    /// Lock-screen + Control Center + AirPods-stem transport. Without these,
    /// `UIBackgroundModes=audio` kept playing in the background with no way
    /// to control it short of reopening the app.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        commandTokens.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in try? self?.play() }
            return .success
        }))
        commandTokens.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }))
        commandTokens.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .playing { self.pause() } else { try? self.play() }
            }
            return .success
        }))
        center.skipForwardCommand.preferredIntervals = [15]
        commandTokens.append((center.skipForwardCommand, center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seek(to: min(self.duration, self.currentTime + 15))
            }
            return .success
        }))
        center.skipBackwardCommand.preferredIntervals = [15]
        commandTokens.append((center.skipBackwardCommand, center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seek(to: max(0, self.currentTime - 15))
            }
            return .success
        }))
        commandTokens.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in self?.seek(to: position) }
            return .success
        }))
    }

    /// Set once per loaded book (title / author / cover); playback fields are
    /// layered on by `updateNowPlayingPlayback` whenever state changes.
    public func setNowPlayingMetadata(title: String, artist: String, artworkData: Data?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        #if canImport(UIKit)
        if let artworkData, let image = UIImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        #endif
        nowPlayingBase = info
        updateNowPlayingPlayback()
    }

    /// Called on every play/pause/seek/rate/load/EOF transition — NOT per
    /// display tick; the system extrapolates elapsed time from the rate.
    private func updateNowPlayingPlayback() {
        guard !nowPlayingBase.isEmpty else { return }
        var info = nowPlayingBase
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? Double(rate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func load(url: URL) async throws {
        state = .loading
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            audioURL = url
            duration = Double(file.length) / file.processingFormat.sampleRate
            currentTime = 0
            seekOffsetSeconds = 0
            baselineSampleTime = 0
            scheduleFromStart()
            state = .ready
            updateNowPlayingPlayback()
        } catch {
            audioFile = nil
            audioURL = nil
            state = .error("Failed to load audio: \(error.localizedDescription)")
            throw error
        }
    }

    public func play() throws {
        guard audioFile != nil else { throw AudioEngineError.notLoaded }
        Self.activateSessionIfNeeded()
        // After EOF (natural end, or a seek that landed at the end) the
        // player node has an empty queue but still reports `isPlaying`, so
        // the plain `player.play()` below would resume into silence with the
        // time pinned at `duration`. Rearm from the start instead — the
        // audiobook "play again" behavior.
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
        state = .playing
        startDisplayTimer()
        updateNowPlayingPlayback()
    }

    public func pause() {
        guard state == .playing else { return }
        snapshotPosition()
        player.pause()
        state = .paused
        stopDisplayTimer()
        updateNowPlayingPlayback()
    }

    public func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let wasPlaying = (state == .playing)
        player.stop()
        let scheduled = scheduleSegment(at: time)
        guard scheduled else {
            // `time` landed at/past EOF — no frames to play. Keep the clamped
            // position (scheduleSegment set it) and drop to paused.
            state = wasPlaying ? .paused : state
            stopDisplayTimer()
            return
        }
        if wasPlaying {
            try? play()
        } else {
            updateNowPlayingPlayback()
        }
    }

    /// Clamp `time`, set the position bookkeeping, and queue the rest of the
    /// file on `player` (no stop, no start — the caller owns transport).
    /// Returns false when there are no frames to schedule (at/past EOF).
    /// Shared by `seek` and the media-services-reset rebuild.
    @discardableResult
    private func scheduleSegment(at time: TimeInterval) -> Bool {
        guard let file = audioFile else { return false }
        let clamped = max(0, min(time, duration))
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(clamped * sampleRate)
        let frameCount = AVAudioFrameCount(max(0, file.length - startFrame))
        seekOffsetSeconds = clamped
        baselineSampleTime = 0
        currentTime = clamped
        guard frameCount > 0 else { return false }
        // `.dataPlayedBack`: fire when the audio is actually audible-complete,
        // not when the last buffer is merely consumed from the queue (the
        // handler-only variant), which lands early by the output buffer length
        // and made EOF detection racy against the 50 ms guard.
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }
        return true
    }

    public func setRate(_ newRate: Float) {
        let clamped = max(Self.minRate, min(newRate, Self.maxRate))
        guard clamped != rate else { return }
        snapshotPosition()
        rate = clamped
        timePitch.rate = clamped
        updateNowPlayingPlayback()
    }

    private func scheduleFromStart() {
        guard let file = audioFile else { return }
        player.stop()
        baselineSampleTime = 0
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }
    }

    private func snapshotPosition() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return }
        // `playerTime.sampleTime` advances at the rate the engine pulls
        // from the player — already source-rate, so `elapsed` is in
        // source seconds. Don't multiply by the playback rate (it's the
        // same `rate` time-pitch is using to pull faster); doing so
        // double-counts and makes the scrubber climb at ~rate² wall-clock.
        let elapsed = Double(playerTime.sampleTime - baselineSampleTime) / playerTime.sampleRate
        seekOffsetSeconds = min(duration, seekOffsetSeconds + elapsed)
        baselineSampleTime = playerTime.sampleTime
    }

    private func handlePlaybackEnded() {
        // This fires both at genuine EOF and whenever `player.stop()` flushes
        // the queue (every seek). Distinguish by position — but recompute it
        // first: the cached `currentTime` is up to one display tick stale,
        // which at 2× is ~67 ms of source time, more than the old 50 ms
        // window. A genuine EOF rejected here never retries, leaving a
        // zombie `.playing` state pinned at the end of the file.
        tickCurrentTime()
        guard currentTime >= duration - 0.25 else { return }
        currentTime = duration
        state = .paused
        stopDisplayTimer()
        updateNowPlayingPlayback()
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        // 30 Hz. Fine enough that read-along word highlighting doesn't skip
        // short words at normal or 2x narration. The historical 10 Hz cap was
        // there because the old active-word recompute scanned the whole
        // alignment map (tens of thousands of anchors) every tick; the current
        // lookup is O(log n) over pre-sorted per-segment anchors, so 30 Hz
        // stays cheap on the main thread.
        //
        // `.common` mode, not the scheduledTimer default: `.default`-mode
        // timers don't fire while the run loop is tracking a touch, so the
        // highlight would freeze mid-scroll / mid-curl-drag and jump on
        // release. Cheap ticks make running through gestures affordable.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCurrentTime() }
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        currentTime = min(duration, seekOffsetSeconds + elapsed)
    }
}

public enum AudioEngineError: Error, Sendable {
    case notLoaded
}
