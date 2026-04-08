import AVFoundation
import MediaPlayer

// Central audio engine managing all sound generation and playback.
// Generated sounds use AVAudioSourceNode (render callback).
// Sample-based sounds use AVAudioPlayerNode with pre-baked loop buffers.
// Singleton — accessed from PlayerViewModel.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    private struct SourceConfiguration: Sendable {
        var type: SoundType
        var volume: Float
        var binauralRange: BinauralRange?
        var binauralFrequency: Float?
    }

    private static let fadeDurationKey = "fadeDuration"
    private static let binauralCarrierKey = "binauralCarrier"

    private var engine = AVAudioEngine()
    private var mixerNode = AVAudioMixerNode()

    // Generated sound sources (noise, binaural) — render callbacks
    private var sourceNodes: [UUID: AVAudioSourceNode] = [:]
    private var generators: [UUID: any SoundGenerator] = [:]

    // Sample-based sources — AVAudioPlayerNode with pre-baked loop buffers
    private var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var samplePlayers: [UUID: SampleLoopPlayer] = [:]
    private var sourceConfigurations: [UUID: SourceConfiguration] = [:]

    // Fade state — applied via mixerNode.outputVolume (never in render callbacks)
    private var fadeTarget: Float = 1.0
    private var fadeStep: Float = 0
    private var isFading = false
    private var fadeCompletion: (() -> Void)?

    // Actual hardware sample rate, queried from engine output node at setup
    private(set) var actualSampleRate: Double = 44100

    // Audio format: stereo, 32-bit float, interleaved, at actual hardware rate
    private var format: AVAudioFormat!

    private(set) var isPlaying = false
    private var isInterrupted = false
    private var isRebuildingGraph = false
    private var shouldResumeAfterInterruption = false
    private var remoteCommandsConfigured = false

    // Notification observers
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var mediaServicesResetObserver: Any?
    private var engineConfigurationObserver: Any?

    // Callback for route-change events the UI needs to handle
    var onBinauralHeadphonesDisconnected: (() -> Void)?

    private init() {
        configureAudioSession()
        configureEngineGraph()
        setupSessionObservers()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session

    private static var sessionCategoryConfigured = false

    private static func configureAudioSessionCategoryIfNeeded() {
        guard !sessionCategoryConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            let preferredRate = session.sampleRate > 0 ? session.sampleRate : 48_000
            try session.setPreferredIOBufferDuration(
                Double(AudioConstants.preferredIOBufferFrameCount) / preferredRate
            )
            sessionCategoryConfigured = true
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }

    func configureAudioSession() {
        Self.configureAudioSessionCategoryIfNeeded()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session activation failed: \(error)")
        }
    }

    private func configureEngineGraph() {
        engine.isAutoShutdownEnabled = true
        engine.attach(mixerNode)

        let hwFormat = engine.outputNode.inputFormat(forBus: 0)
        actualSampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : AudioConstants.sampleRate

        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: actualSampleRate,
            channels: 2,
            interleaved: false
        )!

        engine.connect(mixerNode, to: engine.outputNode, format: nil)
        registerEngineConfigurationObserver()
    }

    private func resetEngineGraph() {
        if let observer = engineConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigurationObserver = nil
        }

        engine = AVAudioEngine()
        mixerNode = AVAudioMixerNode()
        configureEngineGraph()
    }

    private var configuredFadeDuration: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.fadeDurationKey)
        return stored > 0 ? stored : AudioConstants.defaultFadeDuration
    }

    private var configuredBinauralCarrier: Float {
        let stored = UserDefaults.standard.double(forKey: Self.binauralCarrierKey)
        return stored > 0 ? Float(stored) : AudioConstants.defaultBinauralCarrier
    }

    // MARK: - Session Observers

    private func setupSessionObservers() {
        let session = AVAudioSession.sharedInstance()

        // Interruption handling (phone calls, Siri, other apps taking audio)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // Route change handling (headphones unplugged, Bluetooth disconnect)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
        }
    }

    private func registerEngineConfigurationObserver() {
        if let observer = engineConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            isInterrupted = true
            shouldResumeAfterInterruption = isPlaying
            isFading = false
            pauseAllPlayerNodes()
            engine.pause()

        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = shouldResumeAfterInterruption && options.contains(.shouldResume)

            configureAudioSession()
            isInterrupted = false
            shouldResumeAfterInterruption = false

            if shouldResume {
                rebuildAudioGraph(shouldResumePlayback: true)
            } else {
                isPlaying = false
                clearNowPlaying()
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let lostStereoRoute = previousRoute?.outputs.contains(where: Self.supportsBinauralPlayback) ?? false

            if lostStereoRoute,
               generators.values.contains(where: { $0 is BinauralBeatGenerator }),
               isPlaying,
               !Self.headphonesConnected {
                pauseAllPlayerNodes()
                engine.pause()
                isPlaying = false
                clearNowPlaying()
                onBinauralHeadphonesDisconnected?()
            }
        }
    }

    private func handleEngineConfigurationChange() {
        rebuildAudioGraph(shouldResumePlayback: isPlaying && !isInterrupted)
    }

    private func handleMediaServicesReset() {
        Self.sessionCategoryConfigured = false
        configureAudioSession()
        rebuildAudioGraph(shouldResumePlayback: isPlaying || shouldResumeAfterInterruption)
    }

    deinit {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = mediaServicesResetObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = engineConfigurationObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Source Management

    func addSource(id: UUID, type: SoundType, volume: Float,
                   binauralRange: BinauralRange? = nil,
                   binauralFrequency: Float? = nil) {
        let config = SourceConfiguration(
            type: type,
            volume: volume,
            binauralRange: binauralRange,
            binauralFrequency: binauralFrequency
        )

        sourceConfigurations[id] = config
        removeAttachedSource(id: id)
        attachSource(id: id, config: config)
    }

    private func attachSource(id: UUID, config: SourceConfiguration) {
        if config.type.isGenerated {
            addGeneratedSource(id: id, config: config)
        } else {
            addSampleSource(id: id, config: config)
        }
    }

    private func addGeneratedSource(id: UUID, config: SourceConfiguration) {
        let generator = makeGenerator(
            for: config.type,
            binauralRange: config.binauralRange,
            binauralFrequency: config.binauralFrequency
        )
        generator.volume = config.volume
        generators[id] = generator

        let gen = generator
        let fmt = format!

        let sourceNode = AVAudioSourceNode(format: fmt) { (isSilence, _, frameCount, outputData) -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)

            // Non-interleaved stereo: abl has 2 buffers (one per channel).
            guard abl.count >= 2,
                  let ch0 = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let ch1 = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                if let buf = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                    gen.generateMono(into: buf, frameCount: frames)
                } else {
                    isSilence.pointee = true
                }
                return noErr
            }

            // generateStereo writes left/right independently.
            // For most generators the default copies mono to both channels.
            // BinauralBeatGenerator overrides to produce different L/R content.
            gen.generateStereo(left: ch0, right: ch1, frameCount: frames)
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: mixerNode, format: format)
        sourceNodes[id] = sourceNode
    }

    private func addSampleSource(id: UUID, config: SourceConfiguration) {
        let player = SampleLoopPlayer(
            fileName: config.type.sampleFileName,
            sampleRate: actualSampleRate
        )
        player.volume = config.volume
        samplePlayers[id] = player

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        // Connect with the engine format. AVAudioPlayerNode handles format conversion.
        engine.connect(playerNode, to: mixerNode, format: format)
        playerNode.volume = config.volume

        if let buffer = player.loopBuffer {
            playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
        }

        playerNodes[id] = playerNode

        // If the engine is already running, start playback immediately
        if isPlaying {
            playerNode.play()
        }
    }

    func removeSource(id: UUID) {
        sourceConfigurations.removeValue(forKey: id)
        removeAttachedSource(id: id)
    }

    private func removeAttachedSource(id: UUID) {
        // Generated source
        if let node = sourceNodes.removeValue(forKey: id) {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        generators.removeValue(forKey: id)

        // Sample source
        if let node = playerNodes.removeValue(forKey: id) {
            node.stop()
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        samplePlayers.removeValue(forKey: id)
    }

    func removeAllSources() {
        sourceConfigurations.removeAll()
        removeAllAttachedSources()
    }

    private func removeAllAttachedSources() {
        let allIDs = Array(Set(Array(sourceNodes.keys) + Array(playerNodes.keys)))
        for id in allIDs { removeAttachedSource(id: id) }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        if var config = sourceConfigurations[id] {
            config.volume = volume
            sourceConfigurations[id] = config
        }
        // Generated sources: atomic store read by the render callback
        generators[id]?.volume = volume
        // Sample sources: AVAudioPlayerNode.volume is thread-safe
        playerNodes[id]?.volume = volume
    }

    func updateBinauralParameters(for id: UUID, range: BinauralRange?, frequency: Float?) {
        if var config = sourceConfigurations[id] {
            if let range { config.binauralRange = range }
            if let frequency { config.binauralFrequency = frequency }
            sourceConfigurations[id] = config
        }

        guard let gen = generators[id] as? BinauralBeatGenerator else { return }
        if let range { gen.setRange(range) }
        if let freq = frequency { gen.beatFrequency = freq }
    }

    func setDefaultBinauralCarrier(_ frequency: Float) {
        for generator in generators.values {
            guard let binaural = generator as? BinauralBeatGenerator else { continue }
            binaural.carrierFrequency = frequency
        }
    }

    // MARK: - Playback Control

    func start() {
        guard !isPlaying else { return }
        configureAudioSession()

        do {
            try engine.start()
            isPlaying = true
            startAllPlayerNodes()
            fadeIn()
            updateNowPlaying()
        } catch {
            print("Engine start failed: \(error)")
        }
    }

    func stop() {
        guard isPlaying else { return }
        fadeOut { [weak self] in
            guard let self else { return }
            self.pauseAllPlayerNodes()
            self.engine.stop()
            self.isPlaying = false
            self.clearNowPlaying()
        }
    }

    func togglePlayback() {
        if isPlaying { stop() } else { start() }
    }

    // MARK: - Player Node Lifecycle

    private func startAllPlayerNodes() {
        for (id, node) in playerNodes {
            // Re-schedule buffer if needed (after engine restart)
            if let buffer = samplePlayers[id]?.loopBuffer {
                node.stop()
                node.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            node.play()
        }
    }

    private func pauseAllPlayerNodes() {
        for (_, node) in playerNodes {
            node.pause()
        }
    }

    // MARK: - Fading (via mixerNode.outputVolume — never touches render callbacks)

    func setMasterVolume(_ vol: Float) {
        mixerNode.outputVolume = max(0, min(1, vol))
    }

    private func fadeIn(duration: TimeInterval? = nil) {
        let duration = duration ?? configuredFadeDuration
        mixerNode.outputVolume = 0
        fadeTarget = 1.0
        let steps = Int(duration * 60) // 60 fps timer ticks
        fadeStep = 1.0 / Float(max(steps, 1))
        isFading = true
        fadeCompletion = nil
        performFade()
    }

    private func fadeOut(duration: TimeInterval? = nil, completion: @escaping () -> Void) {
        let duration = duration ?? configuredFadeDuration
        fadeTarget = 0
        let steps = Int(duration * 60)
        fadeStep = -mixerNode.outputVolume / Float(max(steps, 1))
        isFading = true
        fadeCompletion = completion
        performFade()
    }

    private func performFade() {
        guard isFading else { return }
        let interval = 1.0 / 60.0

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.isFading else { return }

            var vol = self.mixerNode.outputVolume + self.fadeStep

            if (self.fadeStep > 0 && vol >= self.fadeTarget) ||
               (self.fadeStep < 0 && vol <= self.fadeTarget) {
                vol = self.fadeTarget
                self.isFading = false
                self.mixerNode.outputVolume = vol
                self.fadeCompletion?()
                self.fadeCompletion = nil
            } else {
                self.mixerNode.outputVolume = vol
                self.performFade()
            }
        }
    }

    // Apply timer fade multiplier (called from PlayerViewModel timer tick)
    func applyTimerFade(_ multiplier: Float) {
        mixerNode.outputVolume = max(0, min(1, multiplier))
    }

    // MARK: - Generator Factory

    private func makeGenerator(for type: SoundType,
                                binauralRange: BinauralRange?,
                                binauralFrequency: Float?) -> any SoundGenerator {
        switch type {
        case .whiteNoise:
            return WhiteNoiseGenerator(sampleRate: actualSampleRate)
        case .pinkNoise:
            return PinkNoiseGenerator(sampleRate: actualSampleRate)
        case .brownNoise:
            return BrownNoiseGenerator(sampleRate: actualSampleRate)
        case .grayNoise:
            return GrayNoiseGenerator(sampleRate: actualSampleRate)
        case .binauralBeats:
            let gen = BinauralBeatGenerator(sampleRate: actualSampleRate)
            gen.carrierFrequency = configuredBinauralCarrier
            if let range = binauralRange { gen.setRange(range) }
            if let freq = binauralFrequency { gen.beatFrequency = freq }
            return gen
        default:
            fatalError("Use addSampleSource for non-generated types")
        }
    }

    // MARK: - Now Playing / Control Center

    private func setupRemoteCommandCenter() {
        guard !remoteCommandsConfigured else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.start()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayback()
            return .success
        }

        remoteCommandsConfigured = true
    }

    private func updateNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = "Hush"
        info[MPMediaItemPropertyArtist] = "Focus Sounds"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Headphone Detection

    private func rebuildAudioGraph(shouldResumePlayback: Bool) {
        guard !isRebuildingGraph else { return }
        isRebuildingGraph = true

        let configs = sourceConfigurations
        let targetVolume = mixerNode.outputVolume

        isFading = false
        pauseAllPlayerNodes()
        engine.stop()

        sourceNodes.removeAll()
        generators.removeAll()
        playerNodes.removeAll()
        samplePlayers.removeAll()

        configureAudioSession()
        resetEngineGraph()

        for (id, config) in configs {
            attachSource(id: id, config: config)
        }

        mixerNode.outputVolume = targetVolume

        if shouldResumePlayback && !configs.isEmpty {
            do {
                try engine.start()
                isPlaying = true
                startAllPlayerNodes()
                if targetVolume <= 0 {
                    fadeIn()
                }
                updateNowPlaying()
            } catch {
                isPlaying = false
                clearNowPlaying()
                print("Audio graph rebuild failed to restart playback: \(error)")
            }
        } else {
            isPlaying = false
            clearNowPlaying()
        }

        isRebuildingGraph = false
    }

    private static func supportsBinauralPlayback(_ output: AVAudioSessionPortDescription) -> Bool {
        supportsBinauralPlayback(output.portType)
    }

    private static func supportsBinauralPlayback(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .headphones, .bluetoothA2DP, .bluetoothLE:
            return true
        default:
            return false
        }
    }

    static var headphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains(where: supportsBinauralPlayback)
    }
}
