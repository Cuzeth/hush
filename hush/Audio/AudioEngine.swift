import AVFoundation
import MediaPlayer
import os.log

private let logger = Logger(subsystem: "dev.abdeen.hush", category: "AudioEngine")

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
        var toneFrequency: Float?
        var assetID: String?
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

    // Lazy-load buffer cache: keyed by asset ID, evicted at 200MB
    private let bufferCache = NSCache<NSString, AVAudioPCMBuffer>()

    // Fade state — applied via mixerNode.outputVolume (never in render callbacks)
    private var fadeTarget: Float = 1.0
    private var fadeStep: Float = 0
    private var isFading = false
    private var fadeCompletion: (() -> Void)?

    // Per-source fade timers
    private var sourceFadeTimers: [UUID: Timer] = [:]

    // Actual hardware sample rate, queried from engine output node at setup
    private(set) var actualSampleRate: Double = 44100

    // Audio format: stereo, 32-bit float, interleaved, at actual hardware rate
    private var format: AVAudioFormat!

    private(set) var isPlaying = false
    private var isInterrupted = false
    private var isRebuildingGraph = false
    private var shouldResumeAfterInterruption = false
    private var remoteCommandsConfigured = false

    // Background loading queue
    private let loadingQueue = DispatchQueue(label: "net.hush.audio.loading", qos: .userInitiated)

    // Notification observers
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var mediaServicesResetObserver: Any?
    private var engineConfigurationObserver: Any?

    // Callbacks for events the UI needs to handle
    var onBinauralHeadphonesDisconnected: (() -> Void)?
    var onPlaybackStateChanged: ((Bool) -> Void)?
    var onNextPreset: (() -> Void)?
    var onPreviousPreset: (() -> Void)?
    var onError: ((String) -> Void)?

    // Displayed in Now Playing / lock screen
    var currentPresetName: String = "Hush"

    private init() {
        // 200MB cache limit
        bufferCache.totalCostLimit = 200 * 1024 * 1024
        bufferCache.name = "net.hush.audio.bufferCache"

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
            logger.error("Audio session configuration failed: \(error.localizedDescription)")
        }
    }

    func configureAudioSession() {
        Self.configureAudioSessionCategoryIfNeeded()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Audio session activation failed: \(error.localizedDescription)")
        }
    }

    private func configureEngineGraph() {
        engine.isAutoShutdownEnabled = false
        engine.attach(mixerNode)

        let hwFormat = engine.outputNode.inputFormat(forBus: 0)
        actualSampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : AudioConstants.sampleRate

        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: actualSampleRate,
            channels: 2,
            interleaved: false
        ) else {
            assertionFailure("Failed to create audio format at \(actualSampleRate) Hz")
            return
        }
        format = fmt

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

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

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
                onPlaybackStateChanged?(false)
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

    // MARK: - Thread Safety

    private func assertMainThread(_ fn: String = #function) {
        dispatchPrecondition(condition: .onQueue(.main))
    }

    func addSource(id: UUID, type: SoundType, volume: Float,
                   binauralRange: BinauralRange? = nil,
                   binauralFrequency: Float? = nil,
                   toneFrequency: Float? = nil,
                   assetID: String? = nil) {
        assertMainThread()
        let config = SourceConfiguration(
            type: type,
            volume: volume,
            binauralRange: binauralRange,
            binauralFrequency: binauralFrequency,
            toneFrequency: toneFrequency,
            assetID: assetID
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
            binauralFrequency: config.binauralFrequency,
            toneFrequency: config.toneFrequency
        )
        generator.volume = config.volume
        generators[id] = generator

        // Capture an unretained reference to avoid ARC retain/release on the
        // real-time audio thread. The generator is kept alive by the `generators`
        // dictionary. We go through AnyObject because Unmanaged requires a
        // concrete class type, not an existential (any SoundGenerator).
        let unmanagedGen = Unmanaged<AnyObject>.passUnretained(generator as AnyObject)
        guard let fmt = format else {
            assertionFailure("Audio format not initialized")
            return
        }

        let sourceNode = AVAudioSourceNode(format: fmt) { (isSilence, _, frameCount, outputData) -> OSStatus in
            let gen = unmanagedGen.takeUnretainedValue() as! any SoundGenerator
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)

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

            gen.generateStereo(left: ch0, right: ch1, frameCount: frames)
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: mixerNode, format: format)
        sourceNodes[id] = sourceNode

        logger.info("Playing generated: \(config.type.rawValue)")
    }

    private func addSampleSource(id: UUID, config: SourceConfiguration) {
        // Resolve the asset
        let resolvedAssetID = config.assetID ?? config.type.defaultAssetID
        guard let assetID = resolvedAssetID,
              let asset = SoundAssetRegistry.asset(withID: assetID) else {
            // Legacy fallback: try loading by sample file name
            if let fileName = config.type.sampleFileName {
                addLegacySampleSource(id: id, config: config, fileName: fileName)
            }
            return
        }

        // Check buffer cache first
        let cacheKey = assetID as NSString
        if let cachedBuffer = bufferCache.object(forKey: cacheKey) {
            finishSampleSetup(id: id, config: config, buffer: cachedBuffer, asset: asset)
            return
        }

        // Lazy-load on background queue
        let sr = actualSampleRate
        let wasAlreadyPlaying = isPlaying
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixerNode, format: format)
        // Only start at 0 if we need to fade in (adding to a running engine)
        playerNode.volume = wasAlreadyPlaying ? 0 : config.volume
        playerNodes[id] = playerNode

        loadingQueue.async { [weak self] in
            let player = SampleLoopPlayer()
            player.loadAsset(asset, targetSampleRate: sr)
            player.volume = config.volume

            DispatchQueue.main.async { [weak self] in
                guard let self, let currentNode = self.playerNodes[id] else { return }
                self.samplePlayers[id] = player

                if let buffer = player.loopBuffer {
                    // Cache the buffer (cost = byte size)
                    let cost = Int(buffer.frameLength) * Int(buffer.format.channelCount) * 4
                    self.bufferCache.setObject(buffer, forKey: cacheKey, cost: cost)

                    currentNode.scheduleBuffer(buffer, at: nil, options: .loops)
                    if self.isPlaying {
                        currentNode.play()
                        // Only per-source fade if added to a running engine
                        if wasAlreadyPlaying {
                            self.fadeInSource(id: id, targetVolume: config.volume)
                        }
                    }
                }
            }
        }

        logger.info("Playing sample: \(asset.displayName) [\(asset.id)]")
    }

    private func finishSampleSetup(id: UUID, config: SourceConfiguration, buffer: AVAudioPCMBuffer, asset: SoundAsset) {
        let player = SampleLoopPlayer()
        player.volume = config.volume
        samplePlayers[id] = player

        let wasAlreadyPlaying = isPlaying
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixerNode, format: format)
        playerNode.volume = wasAlreadyPlaying ? 0 : config.volume

        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
        playerNodes[id] = playerNode

        if isPlaying {
            playerNode.play()
            if wasAlreadyPlaying {
                fadeInSource(id: id, targetVolume: config.volume)
            }
        }

        logger.info("Playing sample (cached): \(asset.displayName) [\(asset.id)]")
    }

    private func addLegacySampleSource(id: UUID, config: SourceConfiguration, fileName: String) {
        let sr = actualSampleRate
        let wasAlreadyPlaying = isPlaying
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixerNode, format: format)
        playerNode.volume = wasAlreadyPlaying ? 0 : config.volume
        playerNodes[id] = playerNode

        loadingQueue.async { [weak self] in
            let player = SampleLoopPlayer(fileName: fileName, sampleRate: sr)
            player.volume = config.volume

            DispatchQueue.main.async { [weak self] in
                guard let self, let currentNode = self.playerNodes[id] else { return }
                self.samplePlayers[id] = player

                if let buffer = player.loopBuffer {
                    currentNode.scheduleBuffer(buffer, at: nil, options: .loops)
                    if self.isPlaying {
                        currentNode.play()
                        if wasAlreadyPlaying {
                            self.fadeInSource(id: id, targetVolume: config.volume)
                        }
                    }
                }
            }
        }

        logger.info("Playing legacy sample: \(config.type.rawValue) (\(fileName))")
    }

    func removeSource(id: UUID) {
        assertMainThread()
        sourceConfigurations.removeValue(forKey: id)

        // Fade out then remove
        if playerNodes[id] != nil {
            fadeOutSource(id: id) { [weak self] in
                self?.removeAttachedSource(id: id)
            }
        } else {
            removeAttachedSource(id: id)
        }
    }

    private func removeAttachedSource(id: UUID) {
        sourceFadeTimers[id]?.invalidate()
        sourceFadeTimers.removeValue(forKey: id)

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
        assertMainThread()
        sourceConfigurations.removeAll()
        removeAllAttachedSources()
    }

    private func removeAllAttachedSources() {
        for id in Array(sourceNodes.keys) { removeAttachedSource(id: id) }
        for id in Array(playerNodes.keys) { removeAttachedSource(id: id) }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        assertMainThread()
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
        assertMainThread()
        if var config = sourceConfigurations[id] {
            if let range { config.binauralRange = range }
            if let frequency { config.binauralFrequency = frequency }
            sourceConfigurations[id] = config
        }

        if let gen = generators[id] as? BinauralBeatGenerator {
            if let range { gen.setRange(range) }
            if let freq = frequency { gen.beatFrequency = freq }
        } else if let gen = generators[id] as? IsochronicToneGenerator {
            if let range { gen.setRange(range) }
            if let freq = frequency { gen.pulseRate = freq }
        } else if let gen = generators[id] as? MonauralBeatGenerator {
            if let range { gen.setRange(range) }
            if let freq = frequency { gen.beatFrequency = freq }
        }
    }

    func setDefaultBinauralCarrier(_ frequency: Float) {
        assertMainThread()
        for generator in generators.values {
            if let binaural = generator as? BinauralBeatGenerator {
                binaural.carrierFrequency = frequency
            } else if let isochronic = generator as? IsochronicToneGenerator {
                isochronic.carrierFrequency = frequency
            } else if let monaural = generator as? MonauralBeatGenerator {
                monaural.carrierFrequency = frequency
            }
        }
    }

    func updateToneFrequency(for id: UUID, frequency: Float) {
        assertMainThread()
        if var config = sourceConfigurations[id] {
            config.toneFrequency = frequency
            sourceConfigurations[id] = config
        }

        if let gen = generators[id] as? PureToneGenerator {
            gen.frequency = frequency
        } else if let gen = generators[id] as? DroneGenerator {
            gen.frequency = frequency
        }
    }

    // MARK: - Per-Source Fade In/Out

    private func fadeInSource(id: UUID, targetVolume: Float, duration: TimeInterval = 0.5) {
        guard let node = playerNodes[id] else { return }
        sourceFadeTimers[id]?.invalidate()

        node.volume = 0
        let steps = max(Int(duration * 60), 1)
        let step = targetVolume / Float(steps)
        var current: Float = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            current += step
            if current >= targetVolume {
                node.volume = targetVolume
                timer.invalidate()
                self?.sourceFadeTimers.removeValue(forKey: id)
            } else {
                node.volume = current
            }
        }
        sourceFadeTimers[id] = timer
    }

    private func fadeOutSource(id: UUID, duration: TimeInterval = 0.5, completion: @escaping () -> Void) {
        guard let node = playerNodes[id] else {
            completion()
            return
        }
        sourceFadeTimers[id]?.invalidate()

        let startVolume = node.volume
        let steps = max(Int(duration * 60), 1)
        let step = startVolume / Float(steps)
        var current = startVolume

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            current -= step
            if current <= 0 {
                node.volume = 0
                timer.invalidate()
                self?.sourceFadeTimers.removeValue(forKey: id)
                completion()
            } else {
                node.volume = current
            }
        }
        sourceFadeTimers[id] = timer
    }

    // MARK: - Playback Control

    func start() {
        assertMainThread()
        if isFading {
            isFading = false
            fadeCompletion = nil
        }

        configureAudioSession()

        do {
            if !engine.isRunning {
                try engine.start()
            }
            isPlaying = true
            startAllPlayerNodes()
            fadeIn()
            updateNowPlaying()
        } catch {
            logger.error("Engine start failed: \(error.localizedDescription)")
            onError?("Audio engine failed to start. Please try again.")
        }
    }

    func stop() {
        assertMainThread()
        guard isPlaying else { return }
        isPlaying = false
        fadeOut { [weak self] in
            guard let self else { return }
            self.pauseAllPlayerNodes()
            self.engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.clearNowPlaying()
        }
    }

    func togglePlayback() {
        if isPlaying { stop() } else { start() }
    }

    // MARK: - Player Node Lifecycle

    private func startAllPlayerNodes() {
        for (id, node) in playerNodes {
            if let buffer = samplePlayers[id]?.loopBuffer {
                node.stop()
                node.scheduleBuffer(buffer, at: nil, options: .loops)
            } else if let assetID = sourceConfigurations[id]?.assetID ?? sourceConfigurations[id]?.type.defaultAssetID,
                      let cached = bufferCache.object(forKey: assetID as NSString) {
                node.stop()
                node.scheduleBuffer(cached, at: nil, options: .loops)
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
        assertMainThread()
        mixerNode.outputVolume = max(0, min(1, vol))
    }

    private func fadeIn(duration: TimeInterval? = nil) {
        let duration = duration ?? configuredFadeDuration
        mixerNode.outputVolume = 0
        fadeTarget = 1.0
        let steps = Int(duration * 60)
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

    func applyTimerFade(_ multiplier: Float) {
        assertMainThread()
        mixerNode.outputVolume = max(0, min(1, multiplier))
    }

    // MARK: - Generator Factory

    private func makeGenerator(for type: SoundType,
                                binauralRange: BinauralRange?,
                                binauralFrequency: Float?,
                                toneFrequency: Float? = nil) -> any SoundGenerator {
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
        case .isochronicTones:
            let gen = IsochronicToneGenerator(sampleRate: actualSampleRate)
            gen.carrierFrequency = configuredBinauralCarrier
            if let range = binauralRange { gen.setRange(range) }
            if let freq = binauralFrequency { gen.pulseRate = freq }
            return gen
        case .monauralBeats:
            let gen = MonauralBeatGenerator(sampleRate: actualSampleRate)
            gen.carrierFrequency = configuredBinauralCarrier
            if let range = binauralRange { gen.setRange(range) }
            if let freq = binauralFrequency { gen.beatFrequency = freq }
            return gen
        case .pureTone:
            let gen = PureToneGenerator(sampleRate: actualSampleRate)
            if let freq = toneFrequency { gen.frequency = freq }
            return gen
        case .drone:
            let gen = DroneGenerator(sampleRate: actualSampleRate)
            if let freq = toneFrequency { gen.frequency = freq }
            return gen
        default:
            assertionFailure("Use addSampleSource for non-generated types")
            return WhiteNoiseGenerator(sampleRate: actualSampleRate)
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

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onNextPreset?() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPreviousPreset?() }
            return .success
        }

        remoteCommandsConfigured = true
    }

    private func updateNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentPresetName
        info[MPMediaItemPropertyArtist] = "Hush \u{2014} Focus Sounds"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Audio Graph Rebuild & Headphone Detection

    private func rebuildAudioGraph(shouldResumePlayback: Bool) {
        guard !isRebuildingGraph else { return }
        isRebuildingGraph = true

        let configs = sourceConfigurations
        let targetVolume = mixerNode.outputVolume

        isFading = false
        // Invalidate all per-source fade timers
        for (_, timer) in sourceFadeTimers { timer.invalidate() }
        sourceFadeTimers.removeAll()

        pauseAllPlayerNodes()
        engine.stop()

        // Safe to clear without detaching: resetEngineGraph() below creates a
        // brand-new AVAudioEngine, so old nodes are deallocated with the old engine.
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
                logger.error("Audio graph rebuild failed to restart playback: \(error.localizedDescription)")
            }
        } else {
            isPlaying = false
            clearNowPlaying()
        }

        isRebuildingGraph = false
    }

    nonisolated private static func supportsBinauralPlayback(_ output: AVAudioSessionPortDescription) -> Bool {
        supportsBinauralPlayback(output.portType)
    }

    nonisolated private static func supportsBinauralPlayback(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .headphones, .bluetoothA2DP, .bluetoothLE:
            return true
        default:
            return false
        }
    }

    nonisolated static var headphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains(where: supportsBinauralPlayback)
    }
}
