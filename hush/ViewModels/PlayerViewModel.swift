import SwiftUI
import SwiftData
import AudioToolbox
@preconcurrency import UserNotifications

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
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let engine = AudioEngine.shared
    @ObservationIgnored private static let lastSessionKey = "lastSessionSources"
    @ObservationIgnored private static let timerEndDateKey = "timerEndDate"
    @ObservationIgnored private static let timerDurationKey = "timerDuration"
    @ObservationIgnored private static let timerPlayChimeKey = "timerPlayChimeOnEnd"

    init() {
        engine.onBinauralHeadphonesDisconnected = { [weak self] in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                self.isPlaying = false
            }
            self.showBinauralRouteWarning = true
        }

        engine.onPlaybackStateChanged = { [weak self] playing in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                self.isPlaying = playing
            }
        }

        engine.onNextPreset = { [weak self] in
            self?.cyclePreset(forward: true)
        }

        engine.onPreviousPreset = { [weak self] in
            self?.cyclePreset(forward: false)
        }

        timerState.playChimeOnEnd = UserDefaults.standard.object(forKey: Self.timerPlayChimeKey) as? Bool ?? true
        restorePersistedTimerIfNeeded()
    }

    // MARK: - Preset Loading

    func loadPreset(_ preset: Preset) {
        stop()
        withAnimation(.easeInOut(duration: 0.35)) {
            currentPreset = preset
            activeSources = preset.sources
        }
        // play() calls applyCurrentSources() internally — don't double-apply
        play()
    }

    func randomMix() {
        stop()
        let count = Int.random(in: 2...4)

        // Mix of generated and sample assets
        let generatedTypes: [SoundType] = [.whiteNoise, .pinkNoise, .brownNoise, .grayNoise]
        let assets = SoundAssetRegistry.all

        var sources: [SoundSource] = []
        // Always include one noise generator
        if let noise = generatedTypes.randomElement() {
            sources.append(SoundSource(type: noise, volume: Float.random(in: 0.3...0.6)))
        }
        // Fill the rest with random assets
        let remainingCount = count - sources.count
        let selectedAssets = assets.shuffled().prefix(remainingCount)
        for asset in selectedAssets {
            sources.append(SoundSource(asset: asset, volume: Float.random(in: 0.3...0.7)))
        }

        withAnimation(.easeInOut(duration: 0.35)) {
            activeSources = sources
            currentPreset = nil
        }
        applyCurrentSources()
        play()
    }

    func cyclePreset(forward: Bool) {
        let hidden = Self.hiddenBuiltInIDs
        let presets = Preset.builtIn.filter { !hidden.contains($0.id) }
        guard !presets.isEmpty else { return }

        let currentIdx = currentPreset.flatMap { cp in
            presets.firstIndex(where: { $0.id == cp.id })
        }
        let nextIdx: Int
        if let idx = currentIdx {
            nextIdx = forward
                ? (idx + 1) % presets.count
                : (idx - 1 + presets.count) % presets.count
        } else {
            nextIdx = forward ? 0 : presets.count - 1
        }
        loadPreset(presets[nextIdx])
    }

    func handlePresetDeleted(_ preset: Preset) {
        if currentPreset?.id == preset.id {
            withAnimation(.easeInOut(duration: 0.35)) {
                currentPreset = nil
            }
        }
    }

    private static var hiddenBuiltInIDs: Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: "hiddenBuiltInPresets") else { return [] }
        return (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }

    // MARK: - Source Management

    func addSource(_ type: SoundType, assetID: String? = nil) {
        guard activeSources.count < AudioConstants.maxSimultaneousSources else { return }

        var source = SoundSource(type: type, volume: 0.5, assetID: assetID)
        if type == .pureTone || type == .drone {
            source.toneFrequency = TonePreset.hz432.frequency
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            activeSources.append(source)
        }

        if type == .binauralBeats && !AudioEngine.headphonesConnected {
            showHeadphoneWarning = true
        }

        if isPlaying {
            engine.addSource(id: source.id, type: source.type, volume: source.volume,
                           binauralRange: source.binauralRange,
                           binauralFrequency: source.binauralFrequency,
                           toneFrequency: source.toneFrequency,
                           assetID: source.assetID)
        }
    }

    func addAsset(_ asset: SoundAsset) {
        guard activeSources.count < AudioConstants.maxSimultaneousSources else { return }

        let source = SoundSource(asset: asset, volume: 1.0)

        withAnimation(.easeInOut(duration: 0.3)) {
            activeSources.append(source)
        }

        if isPlaying {
            engine.addSource(id: source.id, type: .sampleAsset, volume: source.volume,
                           assetID: source.assetID)
        }
    }

    func removeSource(_ source: SoundSource) {
        engine.removeSource(id: source.id)
        withAnimation(.easeInOut(duration: 0.3)) {
            activeSources.removeAll { $0.id == source.id }
        }
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

    func updateToneFrequency(for source: SoundSource, frequency: Float) {
        guard let idx = activeSources.firstIndex(where: { $0.id == source.id }) else { return }
        activeSources[idx].toneFrequency = frequency
        engine.updateToneFrequency(for: source.id, frequency: frequency)
    }

    // MARK: - Playback

    func play() {
        if activeSources.isEmpty { return }
        applyCurrentSources()
        engine.currentPresetName = currentPreset?.name ?? "Custom Mix"
        engine.start()
        withAnimation(.easeInOut(duration: 0.35)) {
            isPlaying = true
        }
        applyTimerFadeIfNeeded()
    }

    func stop() {
        engine.stop()
        withAnimation(.easeInOut(duration: 0.35)) {
            isPlaying = false
        }
    }

    func togglePlayback() {
        if isPlaying { stop() } else { play() }
    }

    private func applyCurrentSources() {
        engine.removeAllSources()
        for source in activeSources where source.isActive {
            engine.addSource(id: source.id, type: source.type, volume: source.volume,
                           binauralRange: source.binauralRange,
                           binauralFrequency: source.binauralFrequency,
                           toneFrequency: source.toneFrequency,
                           assetID: source.assetID)
        }
    }

    // MARK: - Timer

    func startTimer(duration: TimeInterval) {
        timerState.start(duration: duration)
        if !isPlaying && !activeSources.isEmpty {
            play()
        }
        persistTimerPreferences()
        persistTimerState()
        startTimerUpdates()
        scheduleTimerNotification(duration: duration)
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerState.clear()
        clearPersistedTimerState()
        engine.setMasterVolume(1.0)
        cancelTimerNotification()
    }

    private func timerExpired() {
        clearPersistedTimerState()
        cancelTimerNotification()
        stop()

        if timerState.playChimeOnEnd {
            playChime()
        }
    }

    private func playChime() {
        AudioServicesPlaySystemSound(1007)
    }

    // MARK: - Timer Notification (fires when app is backgrounded)

    private static let timerNotificationID = "hush.timer.expired"

    private func scheduleTimerNotification(duration: TimeInterval) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    postTimerNotification(duration: duration)
                }
            case .authorized, .provisional, .ephemeral:
                postTimerNotification(duration: duration)
            default:
                break
            }
        }
    }

    private func postTimerNotification(duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Focus session complete"
        content.body = "Your Hush timer has finished. Nice work."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, duration), repeats: false)
        let request = UNNotificationRequest(identifier: Self.timerNotificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelTimerNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.timerNotificationID])
    }

    // MARK: - Preset Persistence

    func saveCurrentAsPreset(name: String, icon: String, context: ModelContext) {
        let saved = SavedPreset(name: name, icon: icon, sources: activeSources)
        context.insert(saved)
    }

    // MARK: - Engine Passthrough

    var actualSampleRate: Double { engine.actualSampleRate }
    var headphonesConnected: Bool { AudioEngine.headphonesConnected }

    func setBinauralCarrier(_ frequency: Float) {
        engine.setDefaultBinauralCarrier(frequency)
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
