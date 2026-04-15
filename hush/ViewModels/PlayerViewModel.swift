import SwiftUI
import SwiftData
import AudioToolbox
@preconcurrency import UserNotifications

enum PlayerWarning: Identifiable, Equatable {
    case headphonesRecommended
    case beatSafety
    case binauralRouteDisconnect
    case missingUserSounds(count: Int)

    var id: String {
        switch self {
        case .headphonesRecommended: return "headphones"
        case .beatSafety: return "beatSafety"
        case .binauralRouteDisconnect: return "routeDisconnect"
        case .missingUserSounds: return "missingUserSounds"
        }
    }

    var icon: String {
        switch self {
        case .headphonesRecommended: return "headphones"
        case .beatSafety: return "exclamationmark.triangle.fill"
        case .binauralRouteDisconnect: return "ear.trianglebadge.exclamationmark"
        case .missingUserSounds: return "questionmark.folder"
        }
    }

    var title: String {
        switch self {
        case .headphonesRecommended: return "Headphones recommended"
        case .beatSafety: return "A note on entrainment"
        case .binauralRouteDisconnect: return "Headphones disconnected"
        case .missingUserSounds: return "Some imported sounds are missing"
        }
    }

    var message: String {
        switch self {
        case .headphonesRecommended:
            return "Binaural beats need headphones — each ear has to hear its own frequency."
        case .beatSafety:
            return "Beats and tones can feel strange. Stop if you feel dizzy, and check with a doctor first if you have epilepsy."
        case .binauralRouteDisconnect:
            return "Playback paused. Reconnect headphones and press play to resume."
        case .missingUserSounds(let count):
            let noun = count == 1 ? "sound" : "sounds"
            return "\(count) imported \(noun) couldn't be found. Open Settings → Imported Sounds to relink or remove."
        }
    }

    var accent: Color {
        switch self {
        case .beatSafety: return HushPalette.danger
        default: return HushPalette.accentSoft
        }
    }
}

@MainActor
@Observable
final class PlayerViewModel {
    var isPlaying = false
    var currentPreset: Preset?
    var activeSources: [SoundSource] = []
    var showMixer = false
    var showTimer = false
    var showSettings = false
    var activeWarning: PlayerWarning?
    var errorMessage: String?
    /// One-shot data persistence failure surfaced by HushApp's ModelContainer
    /// fallback. Distinct from `errorMessage` so the alert can be titled
    /// correctly ("Storage Error" vs "Audio Error").
    var storageFailureMessage: String?

    let timerState = TimerState()
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let engine = AudioEngine.shared
    @ObservationIgnored private weak var userSoundLibrary: UserSoundLibrary?
    @ObservationIgnored private var knownMissingAssetIDs: Set<String> = []
    /// Tracks whether the user has actively dismissed the missing-imports
    /// banner this session. Prevents `dismissWarning` → `refreshMissing…`
    /// from immediately re-popping the same banner. A *new* missing asset
    /// (recordMissingAsset with inserted=true) clears this so the user
    /// learns about it.
    @ObservationIgnored private var missingBannerDismissedThisSession = false
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
            self.showWarning(.binauralRouteDisconnect)
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

        engine.onError = { [weak self] message in
            self?.errorMessage = message
        }

        engine.onSampleAssetMissing = { [weak self] assetID in
            self?.recordMissingAsset(assetID)
        }

        timerState.playChimeOnEnd = UserDefaults.standard.object(forKey: Self.timerPlayChimeKey) as? Bool ?? true
        restorePersistedTimerIfNeeded()
    }

    /// Connect the user sound library. Idempotent — safe to call on every
    /// `onAppear`. We intentionally don't pre-seed the missing banner from
    /// `library.isMissing`; the banner reflects sources the user is *trying
    /// to play* (engine-reported), not the library snapshot. Settings →
    /// Imported Sounds shows library-level missing directly.
    func bindUserSoundLibrary(_ library: UserSoundLibrary) {
        userSoundLibrary = library
    }

    /// Records a missing asset ID and surfaces the banner if appropriate.
    /// Internal so tests can drive the chain without spinning up the engine.
    func recordMissingAsset(_ assetID: String) {
        let (inserted, _) = knownMissingAssetIDs.insert(assetID)
        guard inserted else { return }
        // A new missing asset undoes any earlier "I dismissed it" — the user
        // hasn't seen this one yet.
        missingBannerDismissedThisSession = false
        refreshMissingWarningIfNeeded()
    }

    private func refreshMissingWarningIfNeeded() {
        let count = knownMissingAssetIDs.count
        guard count > 0 else { return }
        // Respect explicit dismissals — without this, dismissWarning would
        // immediately re-pop the banner via this same method and the banner
        // would be undismissable.
        if missingBannerDismissedThisSession { return }
        // Don't trample a more critical active warning (safety, route change).
        // The missing-sounds banner is informational; surface only when the
        // banner slot is free.
        if activeWarning == nil {
            showWarning(.missingUserSounds(count: count))
        } else if case .missingUserSounds = activeWarning {
            // Update the count if the banner is already showing this kind.
            showWarning(.missingUserSounds(count: count))
        }
    }

    /// Clears the missing banner if it's currently showing, without going
    /// through `dismissWarning` (which would set the per-session dismissed
    /// flag — wrong when the system is clearing the banner because the
    /// underlying problem is gone).
    private func clearMissingBannerIfShown() {
        guard case .missingUserSounds = activeWarning else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            activeWarning = nil
        }
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
        let sources = pickRandomMixSources()
        withAnimation(.easeInOut(duration: 0.35)) {
            activeSources = sources
            currentPreset = nil
        }
        applyCurrentSources()
        play()
    }

    /// Source-selection logic for `randomMix`, factored out so tests can
    /// verify the bundled-only pool without spinning up the audio engine.
    func pickRandomMixSources() -> [SoundSource] {
        let count = Int.random(in: 2...4)

        // Mix of generated and sample assets — bundled only. User imports
        // shouldn't land in Surprise Me; their content (length, fit for
        // ambient layering) is unverified and missing imports would silently
        // shrink the resulting mix.
        let generatedTypes: [SoundType] = [.whiteNoise, .pinkNoise, .brownNoise, .grayNoise]
        let assets = SoundAssetRegistry.bundled

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
        return sources
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
        if type == .speechMasking {
            source.maskingStrength = 0.5
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            activeSources.append(source)
        }

        if type == .binauralBeats && !AudioEngine.headphonesConnected {
            showWarning(.headphonesRecommended)
        }

        if [SoundType.binauralBeats, .isochronicTones, .monauralBeats].contains(type) {
            showBeatSafetyAlertIfNeeded()
        }

        if isPlaying {
            engine.addSource(id: source.id, type: source.type, volume: source.volume,
                           binauralRange: source.binauralRange,
                           binauralFrequency: source.binauralFrequency,
                           toneFrequency: source.toneFrequency,
                           assetID: source.assetID,
                           maskingStrength: source.maskingStrength)
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
        // If the user just removed the last source pointing at a missing
        // import, the banner count needs to drop with it.
        if let assetID = source.assetID,
           knownMissingAssetIDs.contains(assetID),
           !activeSources.contains(where: { $0.assetID == assetID }) {
            knownMissingAssetIDs.remove(assetID)
            if knownMissingAssetIDs.isEmpty {
                // Don't go through dismissWarning here — this is a system
                // clear ("the problem went away"), not a user dismiss.
                clearMissingBannerIfShown()
            } else {
                refreshMissingWarningIfNeeded()
            }
        }
    }

    /// Re-attach an existing source after its backing file changed.
    ///
    /// **Safe only for missing-asset sources.** The engine returns early in
    /// `addSource` when an asset has no resolved URL, so no player node ever
    /// gets attached. That means `engine.removeSource(id:)` is synchronous
    /// (no fade), and the immediate `engine.addSource` doesn't race a
    /// fade-out completion that would otherwise tear down the new node by id.
    /// Calling this on a source with an active player would be unsafe;
    /// the assertion guards future misuse.
    ///
    /// Used by the "Missing — tap to relink" affordance in MixerView.
    func relinkSource(_ source: SoundSource) {
        guard activeSources.contains(where: { $0.id == source.id }) else { return }
        if let assetID = source.assetID {
            assert(knownMissingAssetIDs.contains(assetID),
                   "relinkSource is only safe for missing-asset sources")
        }
        engine.removeSource(id: source.id)
        if isPlaying {
            engine.addSource(id: source.id, type: source.type, volume: source.volume,
                             binauralRange: source.binauralRange,
                             binauralFrequency: source.binauralFrequency,
                             toneFrequency: source.toneFrequency,
                             assetID: source.assetID,
                             maskingStrength: source.maskingStrength)
        }
        // The asset is no longer missing (caller just relinked it). Drop it
        // from the tracking set so the banner reflects reality.
        if let assetID = source.assetID {
            knownMissingAssetIDs.remove(assetID)
            if knownMissingAssetIDs.isEmpty {
                clearMissingBannerIfShown()
            } else {
                refreshMissingWarningIfNeeded()
            }
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

    func updateMaskingStrength(for source: SoundSource, strength: Float) {
        guard let idx = activeSources.firstIndex(where: { $0.id == source.id }) else { return }
        activeSources[idx].maskingStrength = strength
        engine.updateMaskingStrength(for: source.id, strength: strength)
    }

    private func showBeatSafetyAlertIfNeeded() {
        // Mark "seen" only after the user dismisses the banner — otherwise
        // a higher-priority warning replacing it before they can read it
        // would burn the single-shot.
        guard !UserDefaults.standard.bool(forKey: "hasSeenBeatSafetyWarning") else { return }
        showWarning(.beatSafety)
    }

    /// Surface a warning as a banner. If a banner is already shown, replaces it
    /// with the new one (the most recent cause is always the most relevant).
    func showWarning(_ warning: PlayerWarning) {
        withAnimation(.easeInOut(duration: 0.3)) {
            activeWarning = warning
        }
    }

    func dismissWarning() {
        let dismissed = activeWarning
        withAnimation(.easeInOut(duration: 0.3)) {
            activeWarning = nil
        }
        // Once-ever beat-safety bookkeeping: only count the warning as "seen"
        // when the user actually dismisses it, so a higher-priority warning
        // replacing it doesn't burn the single-shot.
        if case .beatSafety = dismissed {
            UserDefaults.standard.set(true, forKey: "hasSeenBeatSafetyWarning")
        }
        if case .missingUserSounds = dismissed {
            // User explicitly closed the missing banner — don't immediately
            // resurface it via refreshMissingWarningIfNeeded. A *new* missing
            // asset (recordMissingAsset, inserted=true) clears this flag.
            missingBannerDismissedThisSession = true
            return
        }
        // A higher-priority warning got dismissed — bring back the
        // missing-imports banner if there's something to surface.
        refreshMissingWarningIfNeeded()
    }

    // MARK: - Playback

    func play() {
        if activeSources.isEmpty { return }
        applyCurrentSources()
        engine.currentPresetName = currentPreset?.name ?? "Custom Mix"
        engine.currentPresetIcon = currentPreset?.icon
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
                           assetID: source.assetID,
                           maskingStrength: source.maskingStrength)
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

    // NOTE: Called only from startTimer() with the full fresh duration.
    // Do NOT call this when restoring a timer — the notification would be late.
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

    func setMixWithOtherAudio(_ mix: Bool) {
        engine.reconfigureAudioSession(mixWithOthers: mix)
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
