import AVFoundation
import AudioToolbox
import MediaPlayer
import os.log

private let logger = Logger(subsystem: "dev.abdeen.hush", category: "AudioEngine")

// Central audio engine managing all sound generation and playback.
// Generated sounds use AVAudioSourceNode (render callback).
// Sample-based sounds use AVAudioPlayerNode with pre-baked loop buffers.
// Singleton — accessed from PlayerViewModel.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    private struct SourceConfiguration: Sendable, Equatable {
        var type: SoundType
        var volume: Float
        var binauralRange: BinauralRange?
        var binauralFrequency: Float?
        var toneFrequency: Float?
        var assetID: String?
        var maskingStrength: Float?
    }

    private static let fadeDurationKey = "fadeDuration"
    private static let binauralCarrierKey = "binauralCarrier"
    private static let mixWithOtherAudioKey = "mixWithOtherAudio"

    private var engine = AVAudioEngine()
    private var mixerNode = AVAudioMixerNode()
    private var limiterNode: AVAudioUnitEffect?

    // Generated sound sources (noise, binaural) — render callbacks
    private var sourceNodes: [UUID: AVAudioSourceNode] = [:]
    private var generators: [UUID: any SoundGenerator] = [:]
    // Render-cycle counters, one per source node (see RenderTicker)
    private var renderTickers: [UUID: RenderTicker] = [:]

    // Sample-based sources — AVAudioPlayerNode with pre-baked loop buffers
    private var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var samplePlayers: [UUID: SampleLoopPlayer] = [:]
    private var sourceConfigurations: [UUID: SourceConfiguration] = [:]

    // Lazy-load buffer cache: keyed by asset ID + sample rate, evicted at 200MB
    private let bufferCache = NSCache<NSString, AVAudioPCMBuffer>()
    // Rates each asset has been cached at, so invalidation can drop them all
    private var cachedBufferRates: [String: Set<Double>] = [:]
    // Bumped by invalidateCachedBuffer; an in-flight load that captured an
    // older value decoded the old file and must not re-cache it.
    private var bufferGenerations: [String: UInt64] = [:]

    // Fade state — applied via mixerNode.outputVolume (never in render callbacks)
    private var fadeTarget: Float = 1.0
    private var fadeStartVolume: Float = 0
    private var fadeStartTime: TimeInterval = 0
    private var fadeDuration: TimeInterval = 0
    private var isFading = false
    private var fadeCompletion: (() -> Void)?
    // Each new master fade bumps this; a tick from an older chain bails out,
    // so overlapping chains can't double the fade speed.
    private var fadeGeneration: UInt64 = 0

    // Per-source fade timers
    private var sourceFadeTimers: [UUID: Timer] = [:]

    // Actual hardware sample rate, queried from engine output node at setup
    private(set) var actualSampleRate: Double = 44100

    // Audio format: stereo, 32-bit float, interleaved, at actual hardware rate
    private var format: AVAudioFormat!

    private(set) var isPlaying = false
    private(set) var isInterrupted = false
    private var isRebuildingGraph = false
    private(set) var shouldResumeAfterInterruption = false
    private var remoteCommandsConfigured = false

    /// Starts engine I/O. A seam so tests can exercise `start()`'s state
    /// bookkeeping without audio hardware; production never reassigns it.
    var startEngineIO: (AVAudioEngine) throws -> Void = { try $0.start() }

    // Background loading queue
    private let loadingQueue = DispatchQueue(label: "dev.abdeen.hush.audio.loading", qos: .userInitiated)

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
    /// Remote (Control Center / lock screen / AirPods) transport. The VM
    /// routes these through its own play()/stop() so sources are re-applied
    /// and UI state stays in sync; nil falls back to driving the engine.
    var onRemotePlay: (() -> Void)?
    var onRemotePause: (() -> Void)?
    var onRemoteTogglePlayback: (() -> Void)?
    var onError: ((String) -> Void)?

    /// Fires when a sample source can't be played because the backing file
    /// is gone (user-imported sound deleted in Files app, etc.). The string
    /// is the missing assetID. The VM uses this to surface a "missing
    /// sounds" banner without the engine knowing about UI state.
    var onSampleAssetMissing: ((String) -> Void)?

    // Displayed in Now Playing / lock screen
    var currentPresetName: String = "Hush"
    var currentPresetIcon: String?

    private init() {
        // 200MB cache limit
        bufferCache.totalCostLimit = 200 * 1024 * 1024
        bufferCache.name = "dev.abdeen.hush.audio.bufferCache"

        configureAudioSession()
        configureEngineGraph()
        setupSessionObservers()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session

    private static var sessionCategoryConfigured = false

    private static var mixWithOtherAudio: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: mixWithOtherAudioKey) == nil
            ? true
            : defaults.bool(forKey: mixWithOtherAudioKey)
    }

    private static func configureAudioSessionCategoryIfNeeded() {
        guard !sessionCategoryConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            let options: AVAudioSession.CategoryOptions = mixWithOtherAudio ? [.mixWithOthers] : []
            try session.setCategory(.playback, mode: .default, options: options)
            let preferredRate = session.sampleRate > 0 ? session.sampleRate : 48_000
            try session.setPreferredIOBufferDuration(
                Double(AudioConstants.preferredIOBufferFrameCount) / preferredRate
            )
            sessionCategoryConfigured = true
        } catch {
            logger.error("Audio session configuration failed: \(error.localizedDescription)")
        }
    }

    func reconfigureAudioSession(mixWithOthers: Bool) {
        assertMainThread()
        UserDefaults.standard.set(mixWithOthers, forKey: Self.mixWithOtherAudioKey)
        let session = AVAudioSession.sharedInstance()
        do {
            let options: AVAudioSession.CategoryOptions = mixWithOthers ? [.mixWithOthers] : []
            try session.setCategory(.playback, mode: .default, options: options)
            Self.sessionCategoryConfigured = true
            // A mixable session can't own Now Playing — that includes the
            // paused info kept for lock-screen resume.
            if mixWithOthers {
                clearNowPlaying()
            } else if isPlaying {
                updateNowPlaying()
            }
        } catch {
            logger.error("Audio session reconfiguration failed: \(error.localizedDescription)")
        }
    }

    /// Configures the session *category* only. Activation is deferred to
    /// `start()`/graph rebuild — activating a non-mixable .playback session
    /// at app launch silenced the user's music before Hush played anything.
    func configureAudioSession() {
        Self.configureAudioSessionCategoryIfNeeded()
    }

    private func activateAudioSession() {
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

        // Insert a peak limiter between the mixer and output so layered sources
        // can't sum past 0 dBFS and clip the DAC. Apple's AUPeakLimiter catches
        // transients transparently; below threshold it's a bypass.
        let limiter = Self.makePeakLimiter()
        engine.attach(limiter)
        engine.connect(mixerNode, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        Self.configurePeakLimiter(limiter)
        limiterNode = limiter

        registerEngineConfigurationObserver()
    }

    private static func makePeakLimiter() -> AVAudioUnitEffect {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = kAudioUnitSubType_PeakLimiter
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        desc.componentFlags = 0
        desc.componentFlagsMask = 0
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    private static func configurePeakLimiter(_ limiter: AVAudioUnitEffect) {
        // 1 ms attack — catches transient peaks before they clip.
        // 50 ms decay — fast enough to avoid audible ducking on sustained content.
        // PreGain 0 dB — we're catching peaks, not boosting.
        guard let tree = limiter.auAudioUnit.parameterTree else { return }
        tree.parameter(withAddress: AUParameterAddress(kLimiterParam_AttackTime))?.value = 0.001
        tree.parameter(withAddress: AUParameterAddress(kLimiterParam_DecayTime))?.value = 0.05
        tree.parameter(withAddress: AUParameterAddress(kLimiterParam_PreGain))?.value = 0
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

    /// Internal (not private) so tests can drive it with a synthesized
    /// notification.
    func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            isInterrupted = true
            shouldResumeAfterInterruption = isPlaying
            // A stop() fade-out in flight would otherwise lose its completion
            // and leave the session active for good.
            cancelMasterFade(completingPendingStop: true)
            pauseAllPlayerNodes()
            engine.pause()
            // Reflect reality: we're paused. Leaving isPlaying true here let
            // sample-load completions call play() on a paused engine (an
            // uncatchable NSException) and kept the UI showing "playing"
            // through the whole interruption.
            isPlaying = false
            onPlaybackStateChanged?(false)
            markNowPlayingPaused()

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
                markNowPlayingPaused()
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

        guard reason == .oldDeviceUnavailable else { return }
        let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let lostPrivateRoute = previousRoute?.outputs.contains { Self.pausesOnRouteLoss($0.portType) } ?? false
        guard lostPrivateRoute, !Self.privateListeningRouteConnected else { return }

        // Apple's guidance: losing headphones pauses, so nothing carries on
        // out of the speaker. A stop() fade-out still in flight finishes now
        // for the same reason.
        if isStopFadePending {
            cancelMasterFade(completingPendingStop: true)
            return
        }
        guard isPlaying else { return }

        let hadBinaural = generators.values.contains(where: { $0 is BinauralBeatGenerator })
        cancelMasterFade(completingPendingStop: false)
        pauseAllPlayerNodes()
        engine.pause()
        // isPlaying = false also keeps the engineConfigurationChange rebuild
        // that follows a route change from resuming playback.
        isPlaying = false
        onPlaybackStateChanged?(false)
        markNowPlayingPaused()
        if hadBinaural {
            onBinauralHeadphonesDisconnected?()
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

    private func assertMainThread() {
        dispatchPrecondition(condition: .onQueue(.main))
    }

    func addSource(id: UUID, type: SoundType, volume: Float,
                   binauralRange: BinauralRange? = nil,
                   binauralFrequency: Float? = nil,
                   toneFrequency: Float? = nil,
                   assetID: String? = nil,
                   maskingStrength: Float? = nil) {
        assertMainThread()
        let config = SourceConfiguration(
            type: type,
            volume: volume,
            binauralRange: binauralRange,
            binauralFrequency: binauralFrequency,
            toneFrequency: toneFrequency,
            assetID: assetID,
            maskingStrength: maskingStrength
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
        // Added to a running engine: start silent and fade in. (VolumeRamp
        // snaps its first buffer to the target, so the target must start at
        // 0.) Under start()/rebuild the engine isn't running yet and the
        // master fade covers the entry.
        let fadeInOnAttach = engine.isRunning && !isInterrupted
        generator.volume = fadeInOnAttach ? 0 : config.volume
        if let gen = generator as? SpeechMaskingGenerator, let strength = config.maskingStrength {
            gen.strength = strength
        }
        generators[id] = generator

        guard let fmt = format else {
            assertionFailure("Audio format not initialized")
            return
        }

        let ticker = RenderTicker()
        let sourceNode = makeSourceNode(for: generator, ticker: ticker, format: fmt)
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: mixerNode, format: format)
        sourceNodes[id] = sourceNode
        renderTickers[id] = ticker

        if fadeInOnAttach {
            fadeInSource(id: id)
        }

        logger.info("Playing generated: \(config.type.rawValue)")
    }

    /// Builds the render node in a generic context so the closure captures a
    /// concretely-typed `Unmanaged<G>` — no ARC traffic AND no existential
    /// dynamic cast per render cycle (swift_dynamicCast can take runtime
    /// locks on its slow path, which is off-limits on the audio thread).
    /// Callers pass the existential; SE-0352 opens it to bind `G`.
    /// The generator and ticker are kept alive by the `generators` /
    /// `renderTickers` dictionaries and, after removal, briefly by
    /// `retiredGenerators` / `retiredRenderTickers`.
    private func makeSourceNode<G: SoundGenerator>(for generator: G, ticker: RenderTicker, format: AVAudioFormat) -> AVAudioSourceNode {
        let unmanagedGen = Unmanaged.passUnretained(generator)
        let unmanagedTicker = Unmanaged.passUnretained(ticker)

        return AVAudioSourceNode(format: format) { (isSilence, _, frameCount, outputData) -> OSStatus in
            let gen = unmanagedGen.takeUnretainedValue()
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
                unmanagedTicker.takeUnretainedValue().tick()
                return noErr
            }

            gen.generateStereo(left: ch0, right: ch1, frameCount: frames)
            unmanagedTicker.takeUnretainedValue().tick()
            return noErr
        }
    }

    // MARK: - Sample Buffers

    /// Cache key for a pre-baked loop buffer. The rate is part of the key: a
    /// buffer baked at 44.1 kHz must never be scheduled on a 48 kHz graph
    /// after a route change (CarPlay, Bluetooth).
    static func bufferCacheKey(assetID: String, sampleRate: Double) -> String {
        "\(assetID)@\(Int(sampleRate.rounded()))"
    }

    /// AVAudioPlayerNode raises an uncatchable exception when a scheduled
    /// buffer's format doesn't match its output format.
    static func buffer(_ buffer: AVAudioPCMBuffer, matches format: AVAudioFormat) -> Bool {
        buffer.format.sampleRate == format.sampleRate
            && buffer.format.channelCount == format.channelCount
    }

    /// Current content generation for an asset's cached buffer. Internal for
    /// tests.
    func bufferGeneration(for assetID: String) -> UInt64 {
        bufferGenerations[assetID, default: 0]
    }

    private func cachedBuffer(assetID: String, sampleRate: Double) -> AVAudioPCMBuffer? {
        let key = Self.bufferCacheKey(assetID: assetID, sampleRate: sampleRate) as NSString
        guard let buffer = bufferCache.object(forKey: key) else { return nil }
        guard buffer.format.sampleRate == sampleRate else {
            bufferCache.removeObject(forKey: key)
            return nil
        }
        return buffer
    }

    private func cacheBuffer(_ buffer: AVAudioPCMBuffer, assetID: String, sampleRate: Double) {
        let key = Self.bufferCacheKey(assetID: assetID, sampleRate: sampleRate) as NSString
        let cost = Int(buffer.frameLength) * Int(buffer.format.channelCount) * 4
        bufferCache.setObject(buffer, forKey: key, cost: cost)
        cachedBufferRates[assetID, default: []].insert(sampleRate)
    }

    /// Schedules a freshly loaded loop on its node. Whether to fade is
    /// decided now, not when the source was added: a load that lands after
    /// the master fade-in finished would otherwise start at full level.
    /// Returns false (scheduling nothing) when the buffer's format doesn't
    /// match the node's.
    @discardableResult
    private func startLoadedSample(id: UUID, node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) -> Bool {
        guard Self.buffer(buffer, matches: node.outputFormat(forBus: 0)) else {
            logger.error("Loop buffer format doesn't match its node (\(buffer.format.sampleRate) Hz vs \(node.outputFormat(forBus: 0).sampleRate) Hz)")
            return false
        }
        let volume = sourceConfigurations[id]?.volume ?? 0
        // play() on a node whose engine isn't running raises an uncatchable
        // NSException — interruptions pause the engine.
        guard isPlaying && !isInterrupted && engine.isRunning else {
            // Not playing: start() reschedules and plays it. Restore the
            // target volume so it doesn't come up silent.
            node.volume = volume
            node.scheduleBuffer(buffer, at: nil, options: .loops)
            return true
        }

        // While the master is still at 0 its fade-in covers this entry.
        let audible = mixerNode.outputVolume > 0
        node.stop()
        node.volume = audible ? 0 : volume
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        node.play()
        if audible {
            fadeInSource(id: id)
        }
        return true
    }

    private func addSampleSource(id: UUID, config: SourceConfiguration) {
        // Resolve the asset
        let resolvedAssetID = config.assetID ?? config.type.defaultAssetID
        guard let assetID = resolvedAssetID,
              let asset = SoundAssetRegistry.asset(withID: assetID) else {
            // Legacy fallback: try loading by sample file name
            if let fileName = config.type.sampleFileName {
                addLegacySampleSource(id: id, config: config, fileName: fileName)
            } else if let assetID = resolvedAssetID, assetID.hasPrefix("user.") {
                // A user import deleted from the library no longer resolves at
                // all. Surface it like a missing file so the layer gets the
                // relink affordance instead of going silently quiet.
                logger.warning("Skipping unresolved user asset: \(assetID)")
                onSampleAssetMissing?(assetID)
            }
            return
        }

        // Asset is registered but its file is missing — usually a user import
        // whose backing file was deleted. Skip the load and notify the VM so
        // it can surface a banner. Don't tear down or warn; the source row
        // will render with a "Missing — relink" affordance.
        guard asset.resolvedURL != nil else {
            logger.warning("Skipping missing sample asset: \(asset.id)")
            // Bundled missing means a distribution bug (corrupt app bundle),
            // not a user-actionable problem. The "go to Settings → Imported
            // Sounds" banner copy would be misleading, so only notify for
            // user imports.
            if asset.id.hasPrefix("user.") {
                onSampleAssetMissing?(asset.id)
            }
            return
        }

        // Check buffer cache first
        let sr = actualSampleRate
        if let cachedBuffer = cachedBuffer(assetID: assetID, sampleRate: sr),
           finishSampleSetup(id: id, config: config, buffer: cachedBuffer, asset: asset) {
            return
        }

        // Lazy-load on background queue
        let generation = bufferGeneration(for: assetID)
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixerNode, format: format)
        // Nothing is scheduled until the load lands; startLoadedSample
        // decides the starting gain then.
        playerNode.volume = config.volume
        playerNodes[id] = playerNode

        loadingQueue.async { [weak self] in
            let player = SampleLoopPlayer()
            player.loadAsset(asset, targetSampleRate: sr)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // invalidateCachedBuffer ran mid-decode: this buffer was baked
                // from the old file (or old crossfade) and must not be cached
                // or played.
                let isCurrentContent = self.bufferGeneration(for: assetID) == generation

                // Cache even if this load turns out to be stale — the decode
                // work is still useful to the replacement node.
                if let buffer = player.loopBuffer, isCurrentContent {
                    self.cacheBuffer(buffer, assetID: assetID, sampleRate: sr)
                }

                // Stale load: a graph rebuild replaced the node under this id
                // while we were decoding. The replacement scheduled its own
                // load — touching it here would double-schedule.
                guard let currentNode = self.playerNodes[id], currentNode === playerNode else { return }

                // Removed while loading: the source's fade-out completion does
                // the detach, but scheduling + fadeInSource here would cancel
                // that fade and orphan a looping node with no UI to stop it.
                // Tear it down instead.
                guard let currentConfig = self.sourceConfigurations[id] else {
                    self.removeAttachedSource(id: id)
                    return
                }

                // Content changed under the decode — load again from the
                // current file.
                guard isCurrentContent else {
                    self.removeAttachedSource(id: id)
                    self.attachSource(id: id, config: currentConfig)
                    return
                }

                self.samplePlayers[id] = player

                let started = player.loopBuffer.map {
                    self.startLoadedSample(id: id, node: currentNode, buffer: $0)
                } ?? false
                if !started {
                    // Decode failed (e.g. user file was corrupted between the
                    // URL probe and now). Surface to the VM the same way a
                    // missing-URL asset does, and tear down the orphaned node
                    // so it doesn't sit attached forever.
                    logger.warning("Sample buffer load failed: \(asset.id)")
                    if asset.id.hasPrefix("user.") {
                        self.onSampleAssetMissing?(asset.id)
                    }
                    currentNode.stop()
                    self.engine.disconnectNodeOutput(currentNode)
                    self.engine.detach(currentNode)
                    self.playerNodes.removeValue(forKey: id)
                    self.samplePlayers.removeValue(forKey: id)
                }
            }
        }

        logger.info("Playing sample: \(asset.displayName) [\(asset.id)]")
    }

    /// Returns false (attaching nothing) when the cached buffer doesn't fit
    /// the graph; the caller falls back to a fresh load.
    private func finishSampleSetup(id: UUID, config: SourceConfiguration, buffer: AVAudioPCMBuffer, asset: SoundAsset) -> Bool {
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixerNode, format: format)
        playerNode.volume = config.volume
        playerNodes[id] = playerNode

        guard startLoadedSample(id: id, node: playerNode, buffer: buffer) else {
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
            playerNodes.removeValue(forKey: id)
            return false
        }

        let player = SampleLoopPlayer()
        // Hold the buffer strongly: with only the node schedule + NSCache
        // referencing it, an eviction after stop() left the source silent on
        // the next start() (startAllPlayerNodes had nothing to reschedule).
        player.loopBuffer = buffer
        samplePlayers[id] = player

        logger.info("Playing sample (cached): \(asset.displayName) [\(asset.id)]")
        return true
    }

    private func addLegacySampleSource(id: UUID, config: SourceConfiguration, fileName: String) {
        let sr = actualSampleRate
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixerNode, format: format)
        playerNode.volume = config.volume
        playerNodes[id] = playerNode

        loadingQueue.async { [weak self] in
            let player = SampleLoopPlayer(fileName: fileName, sampleRate: sr)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Same staleness/removal guards as addSampleSource — see the
                // comments there.
                guard let currentNode = self.playerNodes[id], currentNode === playerNode else { return }
                guard self.sourceConfigurations[id] != nil else {
                    self.removeAttachedSource(id: id)
                    return
                }

                self.samplePlayers[id] = player

                let started = player.loopBuffer.map {
                    self.startLoadedSample(id: id, node: currentNode, buffer: $0)
                } ?? false
                if !started {
                    // Same surface as `addSampleSource` — a corrupt bundle
                    // shouldn't fail silently for legacy types either, but
                    // bundled missing isn't user-actionable, so we only
                    // notify for user imports (the banner copy points at
                    // Settings → Imported Sounds).
                    let missingID = config.assetID ?? config.type.rawValue
                    logger.warning("Legacy sample missing: \(missingID) (\(fileName))")
                    if missingID.hasPrefix("user.") {
                        self.onSampleAssetMissing?(missingID)
                    }
                    currentNode.stop()
                    self.engine.disconnectNodeOutput(currentNode)
                    self.engine.detach(currentNode)
                    self.playerNodes.removeValue(forKey: id)
                    self.samplePlayers.removeValue(forKey: id)
                }
            }
        }

        logger.info("Playing legacy sample: \(config.type.rawValue) (\(fileName))")
    }

    func removeSource(id: UUID) {
        assertMainThread()
        sourceConfigurations.removeValue(forKey: id)

        // Fade out then remove. With the engine stopped nothing is audible,
        // so detach right away rather than leave a node a start() would
        // replay mid-fade.
        if playerNodes[id] != nil, engine.isRunning {
            fadeOutSource(id: id) { [weak self] in
                self?.removeAttachedSource(id: id)
            }
        } else if let generator = generators[id], let node = sourceNodes[id],
                  let ticker = renderTickers[id], engine.isRunning {
            // Ramp the generator to silence (VolumeRamp spreads the change
            // across the next render buffer), then detach clear of the click
            // a mid-waveform truncation would cause — but only once that
            // ramp has actually rendered. A fixed delay was shorter than one
            // I/O buffer at the 4096-frame background size.
            sourceFadeTimers[id]?.invalidate()
            sourceFadeTimers.removeValue(forKey: id)
            generator.volume = 0
            detachWhenRampRendered(id: id, node: node, ticker: ticker, mark: ticker.count,
                                   deadline: ProcessInfo.processInfo.systemUptime + Self.generatorDetachTimeout)
        } else {
            removeAttachedSource(id: id)
        }
        // Nothing left to resume — don't leave a paused widget behind.
        if !isPlaying && sourceConfigurations.isEmpty {
            clearNowPlaying()
        }
    }

    /// Upper bound on waiting for a removal's ramp to render. Far past two
    /// 4096-frame buffers; only hit if renders stall without the engine
    /// reporting stopped.
    private static let generatorDetachTimeout: TimeInterval = 0.5

    private func detachWhenRampRendered(id: UUID, node: AVAudioSourceNode, ticker: RenderTicker,
                                        mark: UInt32, deadline: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            // Re-added under the same id, or torn down by a rebuild.
            guard let self, self.sourceConfigurations[id] == nil, self.sourceNodes[id] === node else { return }
            if RenderTicker.hasRenderedRamp(count: ticker.count, since: mark)
                || !self.engine.isRunning
                || ProcessInfo.processInfo.systemUptime >= deadline {
                self.removeAttachedSource(id: id)
            } else {
                self.detachWhenRampRendered(id: id, node: node, ticker: ticker, mark: mark, deadline: deadline)
            }
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
        let ticker = renderTickers.removeValue(forKey: id)
        if let generator = generators.removeValue(forKey: id) {
            retireGenerator(generator, ticker: ticker)
        }

        // Sample source
        if let node = playerNodes.removeValue(forKey: id) {
            node.stop()
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        samplePlayers.removeValue(forKey: id)
    }

    /// Render callbacks hold generators unretained, and AVAudioEngine doesn't
    /// document that detach() waits out an in-flight render cycle. Dropping
    /// the last strong reference synchronously after detach therefore races a
    /// possible use-after-free on the audio thread. Park retired generators
    /// briefly instead; half a second is orders of magnitude past any render
    /// cycle.
    private var retiredGenerators: [any SoundGenerator] = []
    // The render callback holds its ticker unretained too — parked alongside.
    private var retiredRenderTickers: [RenderTicker] = []

    private func retireGenerator(_ generator: any SoundGenerator, ticker: RenderTicker?) {
        retiredGenerators.append(generator)
        if let ticker { retiredRenderTickers.append(ticker) }
        let hasTicker = ticker != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.retiredGenerators.isEmpty else { return }
            self.retiredGenerators.removeFirst()
            if hasTicker, !self.retiredRenderTickers.isEmpty {
                self.retiredRenderTickers.removeFirst()
            }
        }
    }

    /// Drops the pre-baked loop buffer for one asset. Must be called when a
    /// user import's audio changes (relink, crossfade edit, delete) — the
    /// cache would otherwise keep serving a buffer baked from the old file
    /// or old crossfade until the app restarts.
    func invalidateCachedBuffer(assetID: String) {
        assertMainThread()
        // An in-flight load captured the old generation; it now skips its
        // cache write instead of re-caching the stale decode.
        bufferGenerations[assetID, default: 0] &+= 1
        for rate in cachedBufferRates.removeValue(forKey: assetID) ?? [] {
            bufferCache.removeObject(forKey: Self.bufferCacheKey(assetID: assetID, sampleRate: rate) as NSString)
        }
    }

    func removeAllSources() {
        assertMainThread()
        sourceConfigurations.removeAll()
        removeAllAttachedSources()
        if !isPlaying {
            clearNowPlaying()
        }
    }

    private func removeAllAttachedSources() {
        for id in Array(sourceNodes.keys) { removeAttachedSource(id: id) }
        for id in Array(playerNodes.keys) { removeAttachedSource(id: id) }
    }

    /// IDs of the sources the engine is configured to play.
    var activeSourceIDs: Set<UUID> {
        Set(sourceConfigurations.keys)
    }

    /// Configured (target) volume for a source. Internal for tests.
    func configuredVolume(for id: UUID) -> Float? {
        sourceConfigurations[id]?.volume
    }

    /// The node currently attached for a source. Internal for tests: lets
    /// them tell an in-place update from a detach + re-attach.
    func attachedNode(for id: UUID) -> AVAudioNode? {
        sourceNodes[id] ?? playerNodes[id]
    }

    /// Brings the engine's sources in line with `sources` without tearing
    /// down the ones that stay: removed sources fade out, new ones are added,
    /// and kept ones get parameter updates in place. Replaces the old
    /// remove-all + re-add on every play(), which hard-detached nodes (a
    /// click on a quick pause → play) and re-decoded every sample.
    func syncSources(_ sources: [SoundSource]) {
        assertMainThread()
        let desiredIDs = Set(sources.map(\.id))
        for id in Array(sourceConfigurations.keys) where !desiredIDs.contains(id) {
            removeSource(id: id)
        }

        for source in sources {
            let desired = SourceConfiguration(
                type: source.type,
                volume: source.volume,
                binauralRange: source.binauralRange,
                binauralFrequency: source.binauralFrequency,
                toneFrequency: source.toneFrequency,
                assetID: source.assetID,
                maskingStrength: source.maskingStrength
            )
            let hasAttachedNode = sourceNodes[source.id] != nil || playerNodes[source.id] != nil

            // New source, a different sound under the same id, or one with
            // nothing attached (missing import, failed decode): (re)attach.
            // The latter retries a file that may have come back.
            guard let current = sourceConfigurations[source.id],
                  current.type == desired.type,
                  current.assetID == desired.assetID,
                  hasAttachedNode else {
                addSource(id: source.id, type: desired.type, volume: desired.volume,
                          binauralRange: desired.binauralRange,
                          binauralFrequency: desired.binauralFrequency,
                          toneFrequency: desired.toneFrequency,
                          assetID: desired.assetID,
                          maskingStrength: desired.maskingStrength)
                continue
            }
            guard current != desired else { continue }

            if current.volume != desired.volume {
                setVolume(desired.volume, for: source.id)
            }
            if current.binauralRange != desired.binauralRange || current.binauralFrequency != desired.binauralFrequency {
                updateBinauralParameters(for: source.id, range: desired.binauralRange, frequency: desired.binauralFrequency)
            }
            if current.toneFrequency != desired.toneFrequency, let frequency = desired.toneFrequency {
                updateToneFrequency(for: source.id, frequency: frequency)
            }
            if current.maskingStrength != desired.maskingStrength, let strength = desired.maskingStrength {
                updateMaskingStrength(for: source.id, strength: strength)
            }
        }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        assertMainThread()
        if var config = sourceConfigurations[id] {
            config.volume = volume
            sourceConfigurations[id] = config
        }
        // A per-source fade in flight reads its target from the
        // configuration on every tick; writing the gain here would jump it
        // to full and the next tick would yank it back.
        guard sourceFadeTimers[id] == nil else { return }
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

    func updateMaskingStrength(for id: UUID, strength: Float) {
        assertMainThread()
        if var config = sourceConfigurations[id] {
            config.maskingStrength = strength
            sourceConfigurations[id] = config
        }

        if let gen = generators[id] as? SpeechMaskingGenerator {
            gen.strength = strength
        }
    }

    // MARK: - Per-Source Fade In/Out

    /// Applied gain for one source: the player node's volume, or the
    /// generator's atomic target (VolumeRamp smooths between writes).
    private func setSourceGain(_ gain: Float, for id: UUID) {
        if let node = playerNodes[id] {
            node.volume = gain
        } else {
            generators[id]?.volume = gain
        }
    }

    /// Fades a sample or generator in from 0 to its *configured* volume,
    /// read on every tick so a setVolume mid-fade lands instead of being
    /// overwritten by a captured target.
    private func fadeInSource(id: UUID, duration: TimeInterval = 0.5) {
        guard playerNodes[id] != nil || generators[id] != nil else { return }
        sourceFadeTimers[id]?.invalidate()

        setSourceGain(0, for: id)
        let steps = max(Int(duration * 60), 1)
        var tick = 0

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            tick += 1
            let target = self.sourceConfigurations[id]?.volume
            if tick >= steps || target == nil {
                if let target { self.setSourceGain(target, for: id) }
                timer.invalidate()
                if self.sourceFadeTimers[id] === timer {
                    self.sourceFadeTimers.removeValue(forKey: id)
                }
            } else if let target {
                self.setSourceGain(target * Float(tick) / Float(steps), for: id)
            }
        }
        // .common, not .default: the fade must keep running while a scroll
        // view is tracking.
        RunLoop.main.add(timer, forMode: .common)
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

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
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
        RunLoop.main.add(timer, forMode: .common)
        sourceFadeTimers[id] = timer
    }

    // MARK: - Playback Control

    enum StartPath: Equatable {
        /// Already playing: nothing to do. Restarting stopped every loop and
        /// snapped the master to 0.
        case alreadyPlaying
        /// start() landed during stop()'s fade-out: cancel it and fade back
        /// up from the current level, leaving running nodes alone.
        case resumeFromFadeOut
        case fullStart
    }

    static func startPath(isPlaying: Bool, engineRunning: Bool, stopFadePending: Bool) -> StartPath {
        guard engineRunning else { return .fullStart }
        if isPlaying { return .alreadyPlaying }
        if stopFadePending { return .resumeFromFadeOut }
        return .fullStart
    }

    func start() {
        assertMainThread()

        switch Self.startPath(isPlaying: isPlaying, engineRunning: engine.isRunning,
                              stopFadePending: isStopFadePending) {
        case .alreadyPlaying:
            // The VM may have renamed the mix just before calling.
            publishNowPlayingForPlayback()
            return

        case .resumeFromFadeOut:
            cancelMasterFade(completingPendingStop: false)
            noteEngineRunning()
            isPlaying = true
            // Sources synced in during the fade-out window are attached but idle.
            startIdlePlayerNodes()
            fadeIn(fromCurrentVolume: true)
            publishNowPlayingForPlayback()
            onPlaybackStateChanged?(true)
            return

        case .fullStart:
            break
        }

        cancelMasterFade(completingPendingStop: false)
        configureAudioSession()
        activateAudioSession()

        do {
            if !engine.isRunning {
                try startEngineIO(engine)
            }
            noteEngineRunning()
            isPlaying = true
            startAllPlayerNodes()
            fadeIn()
            publishNowPlayingForPlayback()
            onPlaybackStateChanged?(true)
        } catch {
            logger.error("Engine start failed: \(error.localizedDescription)")
            isPlaying = false
            onPlaybackStateChanged?(false)
            onError?("Audio engine failed to start. Please try again.")
        }
    }

    /// The engine's I/O is up, so any interruption is over — whether or not
    /// iOS ever delivered `.ended` (it doesn't guarantee one, e.g. when
    /// another app takes the session). A stale flag silenced sounds added
    /// mid-play and made every route change stop playback.
    private func noteEngineRunning() {
        isInterrupted = false
        shouldResumeAfterInterruption = false
    }

    func stop() {
        assertMainThread()
        guard isPlaying else { return }
        isPlaying = false
        onPlaybackStateChanged?(false)
        markNowPlayingPaused()
        fadeOut { [weak self] in
            guard let self else { return }
            self.pauseAllPlayerNodes()
            self.engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // Keep the (paused) Now Playing info so the lock screen can
            // resume; it's only cleared once there's nothing to resume.
            self.markNowPlayingPaused()
        }
    }

    func togglePlayback() {
        if isPlaying { stop() } else { start() }
    }

    // MARK: - Remote Transport

    func handleRemotePlay() {
        assertMainThread()
        if let onRemotePlay { onRemotePlay() } else { start() }
    }

    func handleRemotePause() {
        assertMainThread()
        if let onRemotePause { onRemotePause() } else { stop() }
    }

    func handleRemoteTogglePlayback() {
        assertMainThread()
        if let onRemoteTogglePlayback { onRemoteTogglePlayback() } else { togglePlayback() }
    }

    // MARK: - Player Node Lifecycle

    /// Schedules (if needed) and plays nodes that aren't playing, fading
    /// each in — for start() during a fade-out, where the nodes that kept
    /// running must not restart.
    private func startIdlePlayerNodes() {
        for (id, node) in playerNodes where !node.isPlaying && sourceConfigurations[id] != nil {
            let nodeFormat = node.outputFormat(forBus: 0)
            guard let buffer = samplePlayers[id]?.loopBuffer, Self.buffer(buffer, matches: nodeFormat) else {
                // Still loading: startLoadedSample schedules and fades it.
                node.play()
                continue
            }
            node.stop()
            node.volume = 0
            node.scheduleBuffer(buffer, at: nil, options: .loops)
            node.play()
            fadeInSource(id: id)
        }
    }

    private func startAllPlayerNodes() {
        // Removed sources still fading out are on their way out — don't
        // restart them.
        for (id, node) in playerNodes where sourceConfigurations[id] != nil {
            let nodeFormat = node.outputFormat(forBus: 0)
            if let buffer = samplePlayers[id]?.loopBuffer, Self.buffer(buffer, matches: nodeFormat) {
                node.stop()
                node.scheduleBuffer(buffer, at: nil, options: .loops)
            } else if let assetID = sourceConfigurations[id]?.assetID ?? sourceConfigurations[id]?.type.defaultAssetID,
                      let cached = cachedBuffer(assetID: assetID, sampleRate: nodeFormat.sampleRate) {
                node.stop()
                node.scheduleBuffer(cached, at: nil, options: .loops)
            }
            // A source added-while-playing starts at volume 0 for its fade-in;
            // if playback stopped before the fade ran, the 0 sticks. Restore
            // the configured volume unless a fade is actively driving it.
            if sourceFadeTimers[id] == nil, let volume = sourceConfigurations[id]?.volume {
                node.volume = volume
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

    /// Focus-timer fade multiplier. The engine owns all writes to
    /// `mixerNode.outputVolume`; the VM only reports the multiplier. Master
    /// fades target this value, so a fade-in during the timer's fade-out
    /// window lands at the reduced level instead of fighting it.
    private var timerFadeMultiplier: Float = 1.0

    /// How long the master takes to follow each focus-timer multiplier
    /// change. The VM reports at 1 Hz, so ramping over ~1 s turns the steps
    /// into one continuous fade.
    private static let timerFadeRampDuration: TimeInterval = 1.0

    /// stop()'s fade-out is running and its completion (pause nodes, stop
    /// the engine, deactivate the session) hasn't fired yet.
    private var isStopFadePending: Bool {
        isFading && fadeCompletion != nil
    }

    private func fadeIn(duration: TimeInterval? = nil, fromCurrentVolume: Bool = false) {
        let duration = duration ?? configuredFadeDuration
        if !fromCurrentVolume {
            mixerNode.outputVolume = 0
        }
        guard timerFadeMultiplier > 0 || mixerNode.outputVolume > 0 else {
            // Timer fade is already at silence — nothing to ramp to.
            cancelMasterFade(completingPendingStop: false)
            return
        }
        rampMaster(to: timerFadeMultiplier, duration: duration)
    }

    private func fadeOut(duration: TimeInterval? = nil, completion: @escaping () -> Void) {
        let duration = duration ?? configuredFadeDuration
        guard mixerNode.outputVolume > 0 else {
            // Already silent — finish now rather than tick toward nothing.
            cancelMasterFade(completingPendingStop: false)
            completion()
            return
        }
        rampMaster(to: 0, duration: duration, completion: completion)
    }

    /// Starts a linear master ramp from the current level. Supersedes any
    /// fade in flight (its completion is dropped — callers that must keep
    /// one use cancelMasterFade(completingPendingStop:) first).
    private func rampMaster(to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeGeneration &+= 1
        fadeTarget = target
        fadeStartVolume = mixerNode.outputVolume
        fadeStartTime = ProcessInfo.processInfo.systemUptime
        fadeDuration = max(duration, 0)
        fadeCompletion = completion
        isFading = true
        performFade(generation: fadeGeneration)
    }

    /// Stops the master fade in flight. With `completingPendingStop`, a
    /// stop() fade-out's pending work runs now instead of being dropped —
    /// otherwise the session would never deactivate.
    private func cancelMasterFade(completingPendingStop: Bool) {
        let pending = fadeCompletion
        fadeGeneration &+= 1
        isFading = false
        fadeCompletion = nil
        if completingPendingStop {
            pending?()
        }
    }

    private func performFade(generation: UInt64) {
        guard isFading, generation == fadeGeneration else { return }
        let interval = 1.0 / 60.0

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            // A newer fade (or a cancel) owns the master now.
            guard let self, self.isFading, self.fadeGeneration == generation else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - self.fadeStartTime
            let progress = self.fadeDuration > 0 ? min(Float(elapsed / self.fadeDuration), 1) : 1

            if progress >= 1 {
                self.isFading = false
                self.mixerNode.outputVolume = self.fadeTarget
                let completion = self.fadeCompletion
                self.fadeCompletion = nil
                completion?()
            } else {
                self.mixerNode.outputVolume = self.fadeStartVolume
                    + (self.fadeTarget - self.fadeStartVolume) * progress
                self.performFade(generation: generation)
            }
        }
    }

    func applyTimerFade(_ multiplier: Float) {
        assertMainThread()
        let level = max(0, min(1, multiplier))
        timerFadeMultiplier = level
        // Paused: the next fadeIn targets the multiplier. stop()'s fade-out
        // owns the master until it completes.
        guard isPlaying, !isStopFadePending else { return }
        // Already there, or already heading there.
        if isFading ? fadeTarget == level : mixerNode.outputVolume == level { return }
        // Ramp from wherever the master is — never assign it outright, which
        // stepped audibly at 1 Hz and jumped to full on timer cancel. An
        // in-progress fade-in is continued toward the new level over at
        // least its remaining time, so it isn't cut short.
        let remaining = isFading
            ? max(0, fadeStartTime + fadeDuration - ProcessInfo.processInfo.systemUptime)
            : 0
        rampMaster(to: level, duration: max(Self.timerFadeRampDuration, remaining))
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
        case .speechMasking:
            return SpeechMaskingGenerator(sampleRate: actualSampleRate)
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

        // All handlers hop to main: MPRemoteCommandCenter doesn't guarantee
        // the calling thread, and start()/stop() assert main-queue.
        // Transport goes through the VM (handleRemote*) so a remote Play
        // re-applies the current mix instead of resuming a stale graph.
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.handleRemotePlay() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.handleRemotePause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.handleRemoteTogglePlayback() }
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

    private static let defaultNowPlayingIcon = "waveform"

    /// Memoized per symbol — rasterizing 600×600 on the main thread on every
    /// updateNowPlaying (each start()/rebuild) was measurable jank for an
    /// image that only changes when the preset icon does.
    private var cachedArtwork: (symbol: String, artwork: MPMediaItemArtwork)?

    private func renderNowPlayingArtwork() -> MPMediaItemArtwork? {
        let symbolName = currentPresetIcon ?? Self.defaultNowPlayingIcon
        if let cached = cachedArtwork, cached.symbol == symbolName {
            return cached.artwork
        }
        let size = CGSize(width: 600, height: 600)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Background matching the app theme
            UIColor(red: 0.035, green: 0.036, blue: 0.044, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Subtle radial glow
            let glowColor = UIColor(red: 0.412, green: 0.498, blue: 0.474, alpha: 0.3)
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [glowColor.cgColor, UIColor.clear.cgColor] as CFArray,
                locations: [0, 1]
            ) {
                ctx.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                    startRadius: 0,
                    endCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                    endRadius: size.width * 0.42,
                    options: []
                )
            }

            // SF Symbol
            let symbolSize: CGFloat = size.width * 0.35
            let config = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            guard let symbol = UIImage(systemName: symbolName, withConfiguration: config) else { return }
            let tinted = symbol.withTintColor(
                UIColor(red: 0.690, green: 0.760, blue: 0.734, alpha: 1),
                renderingMode: .alwaysOriginal
            )
            let symbolBounds = tinted.size
            let origin = CGPoint(
                x: (size.width - symbolBounds.width) / 2,
                y: (size.height - symbolBounds.height) / 2
            )
            tinted.draw(at: origin)
        }

        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
        cachedArtwork = (symbolName, artwork)
        return artwork
    }

    private func updateNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentPresetName
        info[MPMediaItemPropertyArtist] = "Hush \u{2014} Focus Sounds"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        if let artwork = renderNowPlayingArtwork() {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Now Playing for active playback. A mixable session can't own the
    /// lock-screen widget, so mix-with-others clears it instead.
    private func publishNowPlayingForPlayback() {
        if Self.mixWithOtherAudio {
            clearNowPlaying()
        } else {
            updateNowPlaying()
        }
    }

    /// A pause keeps the info (rate 0) so the lock-screen controls stay up
    /// and can resume. It's cleared only when there's nothing to resume.
    private func markNowPlayingPaused() {
        guard !Self.mixWithOtherAudio, !sourceConfigurations.isEmpty else {
            clearNowPlaying()
            return
        }
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        center.nowPlayingInfo = info
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
        // A fade toward a nonzero level (start's fade-in, a timer ramp) was
        // mid-flight: the captured volume is a waypoint, not the target.
        let wasFadingUp = isFading && fadeCompletion == nil && fadeTarget > 0

        // A stop() fade-out in flight would lose its completion here; run
        // the pending stop work (incl. session deactivation) now.
        cancelMasterFade(completingPendingStop: true)
        // Invalidate all per-source fade timers
        for (_, timer) in sourceFadeTimers { timer.invalidate() }
        sourceFadeTimers.removeAll()

        pauseAllPlayerNodes()
        engine.stop()

        // Safe to clear without detaching: resetEngineGraph() below creates a
        // brand-new AVAudioEngine, so old nodes are deallocated with the old engine.
        sourceNodes.removeAll()
        generators.removeAll()
        renderTickers.removeAll()
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
                activateAudioSession()
                try engine.start()
                noteEngineRunning()
                isPlaying = true
                startAllPlayerNodes()
                if targetVolume <= 0 {
                    fadeIn()
                } else if wasFadingUp {
                    rampMaster(to: timerFadeMultiplier, duration: configuredFadeDuration)
                }
                publishNowPlayingForPlayback()
                onPlaybackStateChanged?(true)
            } catch {
                isPlaying = false
                markNowPlayingPaused()
                onPlaybackStateChanged?(false)
                logger.error("Audio graph rebuild failed to restart playback: \(error.localizedDescription)")
            }
        } else {
            isPlaying = false
            markNowPlayingPaused()
            onPlaybackStateChanged?(false)
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

    /// Personal/private outputs whose disappearance must pause playback
    /// rather than fall through to the speaker (Apple's route-change
    /// guidance). Internal for tests.
    nonisolated static func pausesOnRouteLoss(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
             .usbAudio, .carAudio, .airPlay:
            return true
        default:
            return false
        }
    }

    nonisolated private static var privateListeningRouteConnected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { pausesOnRouteLoss($0.portType) }
    }
}
