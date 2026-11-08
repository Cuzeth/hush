@preconcurrency import AVFoundation
import Foundation
import Observation

// MARK: - State machine

/// What the Add Sound picker is auditioning. Pure: every transition is a
/// value-in, value-out function so the rules (switch, toggle off, stale
/// timers) are testable without audio.
enum SoundPreviewState: Equatable {
    case idle
    case previewing(id: String)

    var previewingID: String? {
        if case .previewing(let id) = self { return id }
        return nil
    }

    enum Event: Equatable {
        /// Long-press or the Preview accessibility action on a card.
        case toggle(id: String)
        /// The time limit for that preview ran out.
        case timeLimitReached(id: String)
        /// The file couldn't be opened or played.
        case playbackFailed(id: String)
        /// A sound was added, or the picker went away.
        case stop
    }

    enum Effect: Equatable {
        case startPlayback(id: String)
        case stopPlayback
    }

    func handling(_ event: Event) -> (state: SoundPreviewState, effects: [Effect]) {
        switch (self, event) {
        case (.idle, .toggle(let id)):
            return (.previewing(id: id), [.startPlayback(id: id)])
        case (.previewing(let current), .toggle(let id)):
            // Same card again stops it; another card takes over.
            return current == id
                ? (.idle, [.stopPlayback])
                : (.previewing(id: id), [.stopPlayback, .startPlayback(id: id)])
        case (.previewing(let current), .timeLimitReached(let id)),
             (.previewing(let current), .playbackFailed(let id)):
            // A stale event for an earlier preview must not end this one.
            return current == id ? (.idle, [.stopPlayback]) : (self, [])
        case (.previewing, .stop):
            return (.idle, [.stopPlayback])
        case (.idle, _):
            return (.idle, [])
        }
    }
}

// MARK: - Playback

/// One audible preview. A protocol so tests can swap in a fake and never
/// touch audio hardware.
protocol SoundPreviewPlayback: AnyObject {
    /// Plays from the start, fading in to `volume`. False if it couldn't start.
    func play(volume: Float, fadeIn: TimeInterval) -> Bool
    /// Fades out, then stops. Keeps itself alive until it's silent.
    func stop(fadeOut: TimeInterval)
}

/// AVAudioPlayer-backed preview. Deliberately separate from `AudioEngine`:
/// it never touches the engine graph and never deactivates the shared
/// AVAudioSession, so it plays over a running mix and leaves the mix alone
/// when it ends. Files are bundled or already inside the app container, so
/// no security scope is needed (unlike ImportSoundSheet's pre-import file).
final class AudioFilePreviewPlayback: SoundPreviewPlayback {
    private let player: AVAudioPlayer

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        // Loops are what the mix plays; a short import shouldn't go silent
        // before the time limit.
        player.numberOfLoops = -1
    }

    func play(volume: Float, fadeIn: TimeInterval) -> Bool {
        player.volume = 0
        player.currentTime = 0
        guard player.prepareToPlay(), player.play() else { return false }
        player.setVolume(volume, fadeDuration: fadeIn)
        return true
    }

    func stop(fadeOut: TimeInterval) {
        guard player.isPlaying else { return }
        player.setVolume(0, fadeDuration: fadeOut)
        // The task holds the player through the fade even after the
        // preview controller (or the whole picker) has let go of it.
        let player = player
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(fadeOut))
            player.stop()
        }
    }
}

// MARK: - Controller

/// Drives the picker's long-press previews: about 6 s from the start of the
/// file with short fades, one at a time.
@Observable
final class SoundPreviewPlayer {
    typealias MakePlayback = @MainActor (URL) throws -> any SoundPreviewPlayback
    /// Runs `action` after a delay; the returned closure cancels it.
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    static let duration: TimeInterval = 6
    static let fadeDuration: TimeInterval = 0.3
    /// The level a new layer joins the mix at, so the preview sounds like
    /// what tapping the card will add.
    static let volume: Float = AudioConstants.defaultSourceVolume

    enum ToggleResult: Equatable {
        case started
        case stopped
        /// No file to play (missing import, broken bundle) or it wouldn't open.
        case unavailable
    }

    private(set) var state: SoundPreviewState = .idle
    var previewingID: String? { state.previewingID }

    @ObservationIgnored private let makePlayback: MakePlayback
    @ObservationIgnored private let schedule: Schedule
    @ObservationIgnored private var playback: (any SoundPreviewPlayback)?
    @ObservationIgnored private var cancelTimer: (() -> Void)?
    /// Bumped per preview so a timer that outlives its preview (fired after
    /// cancel, or a scheduler that ignores cancel) can't end a newer preview
    /// of the same sound.
    @ObservationIgnored private var generation = 0

    init(
        makePlayback: @escaping MakePlayback = { try AudioFilePreviewPlayback(url: $0) },
        schedule: @escaping Schedule = SoundPreviewPlayer.scheduleOnMain
    ) {
        self.makePlayback = makePlayback
        self.schedule = schedule
    }

    /// Starts this asset's preview, switches to it, or stops it if it's the
    /// one already playing. Resolves the file the way the engine does.
    @discardableResult
    func toggle(_ asset: SoundAsset) -> ToggleResult {
        toggle(id: asset.id, url: asset.resolvedURL)
    }

    /// `url` is only evaluated when a preview actually starts.
    @discardableResult
    func toggle(id: String, url: @autoclosure () -> URL?) -> ToggleResult {
        let wasPreviewingThis = previewingID == id
        send(.toggle(id: id), url: url)
        if wasPreviewingThis { return .stopped }
        return previewingID == id ? .started : .unavailable
    }

    /// Ends whatever is playing (sound added, picker dismissed).
    func stop() {
        send(.stop)
    }

    // MARK: Internals

    private func send(_ event: SoundPreviewState.Event, url: () -> URL? = { nil }) {
        let (next, effects) = state.handling(event)
        state = next
        for effect in effects {
            switch effect {
            case .stopPlayback:
                stopPlayback()
            case .startPlayback(let id):
                if !startPlayback(id: id, url: url()) {
                    send(.playbackFailed(id: id))
                }
            }
        }
    }

    private func startPlayback(id: String, url: URL?) -> Bool {
        guard let url, let player = try? makePlayback(url),
              player.play(volume: Self.volume, fadeIn: Self.fadeDuration) else { return false }
        playback = player
        generation += 1
        let token = generation
        // Begin the fade-out early so the preview is silent at `duration`.
        cancelTimer = schedule(Self.duration - Self.fadeDuration) { [weak self] in
            guard let self, self.generation == token else { return }
            self.send(.timeLimitReached(id: id))
        }
        return true
    }

    private func stopPlayback() {
        cancelTimer?()
        cancelTimer = nil
        generation += 1
        playback?.stop(fadeOut: Self.fadeDuration)
        playback = nil
    }

    nonisolated static func scheduleOnMain(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}
