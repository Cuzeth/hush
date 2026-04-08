import SwiftUI
import SwiftData
import AudioToolbox

@MainActor
@Observable
final class PlayerViewModel {
    var isPlaying = false
    var currentPreset: Preset?
    var activeSources: [SoundSource] = []
    var showMixer = false
    var showTimer = false
    var showSettings = false
    var showHeadphoneWarning = false

    var showBinauralRouteWarning = false

    let timerState = TimerState()
    private var timerTask: Task<Void, Never>?
    private let engine = AudioEngine.shared
    private static let lastSessionKey = "lastSessionSources"
    private static let timerEndDateKey = "timerEndDate"
    private static let timerDurationKey = "timerDuration"
    private static let timerPlayChimeKey = "timerPlayChimeOnEnd"

    init() {
        engine.onBinauralHeadphonesDisconnected = { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.showBinauralRouteWarning = true
        }

        timerState.playChimeOnEnd = UserDefaults.standard.object(forKey: Self.timerPlayChimeKey) as? Bool ?? true
        restorePersistedTimerIfNeeded()
    }

    // MARK: - Preset Loading

    func loadPreset(_ preset: Preset) {
        stop()
        currentPreset = preset
        activeSources = preset.sources
        applyCurrentSources()
        play()
    }

    func randomMix() {
        stop()
        let allTypes = SoundType.allCases.filter { $0 != .binauralBeats }
        let count = Int.random(in: 2...3)
        let selected = allTypes.shuffled().prefix(count)
        activeSources = selected.map { type in
            SoundSource(type: type, volume: Float.random(in: 0.3...0.8))
        }
        currentPreset = nil
        applyCurrentSources()
        play()
    }

    // MARK: - Source Management

    func addSource(_ type: SoundType) {
        guard activeSources.count < AudioConstants.maxSimultaneousSources else { return }
        let source = SoundSource(type: type, volume: 0.5)
        activeSources.append(source)

        if type == .binauralBeats && !AudioEngine.headphonesConnected {
            showHeadphoneWarning = true
        }

        if isPlaying {
            engine.addSource(id: source.id, type: source.type, volume: source.volume,
                           binauralRange: source.binauralRange,
                           binauralFrequency: source.binauralFrequency)
        }
    }

    func removeSource(_ source: SoundSource) {
        engine.removeSource(id: source.id)
        activeSources.removeAll { $0.id == source.id }
    }

    func updateVolume(for source: SoundSource, volume: Float) {
        guard let idx = activeSources.firstIndex(where: { $0.id == source.id }) else { return }
        activeSources[idx].volume = volume
        engine.setVolume(volume, for: source.id)
    }

    func updateBinaural(for source: SoundSource, range: BinauralRange?, frequency: Float?) {
        guard let idx = activeSources.firstIndex(where: { $0.id == source.id }) else { return }
        if let range { activeSources[idx].binauralRange = range }
        if let freq = frequency { activeSources[idx].binauralFrequency = freq }
        engine.updateBinauralParameters(for: source.id, range: range, frequency: frequency)
    }

    // MARK: - Playback

    func play() {
        if activeSources.isEmpty { return }
        applyCurrentSources()
        engine.start()
        isPlaying = true
        applyTimerFadeIfNeeded()

        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
    }

    func stop() {
        engine.stop()
        isPlaying = false
        stopTimer()

        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }

    func togglePlayback() {
        if isPlaying { stop() } else { play() }
    }

    private func applyCurrentSources() {
        engine.removeAllSources()
        for source in activeSources where source.isActive {
            engine.addSource(id: source.id, type: source.type, volume: source.volume,
                           binauralRange: source.binauralRange,
                           binauralFrequency: source.binauralFrequency)
        }
    }

    // MARK: - Timer

    func startTimer(duration: TimeInterval) {
        timerState.start(duration: duration)
        persistTimerPreferences()
        persistTimerState()
        startTimerUpdates()
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerState.clear()
        clearPersistedTimerState()
        engine.setMasterVolume(1.0)
    }

    private func timerExpired() {
        clearPersistedTimerState()
        stop()

        if timerState.playChimeOnEnd {
            playChime()
        }
    }

    private func playChime() {
        // System notification sound as a gentle chime
        AudioServicesPlaySystemSound(1007) // kSystemSoundID_Notification
    }

    // MARK: - Preset Persistence

    func saveCurrentAsPreset(name: String, context: ModelContext) {
        let saved = SavedPreset(name: name, icon: "star.fill", sources: activeSources)
        context.insert(saved)
    }

    // MARK: - Last Session

    func saveLastSession() {
        guard let data = try? JSONEncoder().encode(activeSources) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastSessionKey)
    }

    func restoreLastSession() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.lastSessionKey),
              let sources = try? JSONDecoder().decode([SoundSource].self, from: data),
              !sources.isEmpty else { return false }
        activeSources = sources
        currentPreset = nil
        return true
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            refreshTimerState()
            if timerState.isRunning {
                startTimerUpdates()
            }
        case .inactive, .background:
            saveLastSession()
            persistTimerState()
        @unknown default:
            break
        }
    }

    func persistTimerPreferences() {
        UserDefaults.standard.set(timerState.playChimeOnEnd, forKey: Self.timerPlayChimeKey)
    }

    private func startTimerUpdates() {
        timerTask?.cancel()
        refreshTimerState()
        guard timerState.isRunning else { return }

        timerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self.refreshTimerState()
                if !self.timerState.isRunning { break }
            }
        }
    }

    private func refreshTimerState() {
        guard timerState.endDate != nil else { return }

        if timerState.syncRemaining() {
            timerExpired()
            return
        }

        persistTimerState()
        applyTimerFadeIfNeeded()
    }

    private func applyTimerFadeIfNeeded() {
        if timerState.isFadingOut {
            engine.applyTimerFade(timerState.fadeMultiplier)
        } else if isPlaying {
            engine.setMasterVolume(1.0)
        }
    }

    private func restorePersistedTimerIfNeeded() {
        let defaults = UserDefaults.standard
        guard let endDate = defaults.object(forKey: Self.timerEndDateKey) as? Date else { return }

        let storedDuration = defaults.double(forKey: Self.timerDurationKey)
        timerState.selectedDuration = storedDuration > 0 ? storedDuration : TimerDuration.twentyFive.seconds
        timerState.endDate = endDate

        if timerState.syncRemaining() {
            clearPersistedTimerState()
            return
        }

        startTimerUpdates()
    }

    private func persistTimerState() {
        persistTimerPreferences()

        let defaults = UserDefaults.standard
        if let endDate = timerState.endDate {
            defaults.set(endDate, forKey: Self.timerEndDateKey)
            defaults.set(timerState.selectedDuration, forKey: Self.timerDurationKey)
        } else {
            defaults.removeObject(forKey: Self.timerEndDateKey)
            defaults.removeObject(forKey: Self.timerDurationKey)
        }
    }

    private func clearPersistedTimerState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.timerEndDateKey)
        defaults.removeObject(forKey: Self.timerDurationKey)
    }
}
