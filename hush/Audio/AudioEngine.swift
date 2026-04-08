import AVFoundation
import MediaPlayer

// Central audio engine managing all sound generation and playback.
// Generated sounds use AVAudioSourceNode (render callback).
// Sample-based sounds use AVAudioPlayerNode with pre-baked loop buffers.
// Singleton — accessed from PlayerViewModel.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private let mixerNode = AVAudioMixerNode()

    // Generated sound sources (noise, binaural) — render callbacks
    private var sourceNodes: [UUID: AVAudioSourceNode] = [:]
    private var generators: [UUID: any SoundGenerator] = [:]

    // Sample-based sources — AVAudioPlayerNode with pre-baked loop buffers
    private var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var samplePlayers: [UUID: SampleLoopPlayer] = [:]

    private var channelVolumes: [UUID: Float] = [:]

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

    // Notification observers
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?

    // Callback for route-change events the UI needs to handle
    var onBinauralHeadphonesDisconnected: (() -> Void)?

    private init() {
        // Configure audio session FIRST so the output node reports the real
        // hardware format (sample rate, channel count) rather than defaults.
        Self.configureAudioSessionOnce()

        engine.attach(mixerNode)

        // Query the actual hardware sample rate from the output node.
        let hwFormat = engine.outputNode.inputFormat(forBus: 0)
        actualSampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 44100

        // Internal processing format: stereo float32 non-interleaved at hardware rate.
        // Non-interleaved is what AVAudioEngine nodes expect internally.
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: actualSampleRate,
            channels: 2,
            interleaved: false
        )!

        // Connect mixer → output using nil format to let the engine negotiate
        // the output node's native format automatically (avoids FormatNotSupported).
        engine.connect(mixerNode, to: engine.outputNode, format: nil)

        setupSessionObservers()
    }

    // MARK: - Audio Session

    private static var sessionConfigured = false

    private static func configureAudioSessionOnce() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }

    func configureAudioSession() {
        Self.configureAudioSessionOnce()
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
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Another audio source has taken priority — pause gracefully
            if isPlaying {
                engine.pause()
                pauseAllPlayerNodes()
                // Don't set isPlaying = false; we may resume
            }

        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) && isPlaying {
                do {
                    try engine.start()
                    startAllPlayerNodes()
                } catch {
                    print("Engine restart after interruption failed: \(error)")
                }
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
            // A device was removed (headphones unplugged, BT disconnected).
            // If binaural beats are active, pause and notify the UI.
            let hasBinaural = generators.values.contains { $0 is BinauralBeatGenerator }
            if hasBinaural && isPlaying {
                engine.pause()
                pauseAllPlayerNodes()
                isPlaying = false
                onBinauralHeadphonesDisconnected?()
            }
        }
    }

    deinit {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Source Management

    func addSource(id: UUID, type: SoundType, volume: Float,
                   binauralRange: BinauralRange? = nil,
                   binauralFrequency: Float? = nil) {
        removeSource(id: id)
        channelVolumes[id] = volume

        if type.isGenerated {
            addGeneratedSource(id: id, type: type, volume: volume,
                              binauralRange: binauralRange,
                              binauralFrequency: binauralFrequency)
        } else {
            addSampleSource(id: id, type: type, volume: volume)
        }
    }

    private func addGeneratedSource(id: UUID, type: SoundType, volume: Float,
                                     binauralRange: BinauralRange?,
                                     binauralFrequency: Float?) {
        let generator = makeGenerator(for: type, binauralRange: binauralRange,
                                       binauralFrequency: binauralFrequency)
        generator.volume = volume
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

    private func addSampleSource(id: UUID, type: SoundType, volume: Float) {
        let player = SampleLoopPlayer(fileName: type.sampleFileName,
                                       sampleRate: actualSampleRate)
        player.volume = volume
        samplePlayers[id] = player

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        // Connect with the engine format. AVAudioPlayerNode handles format conversion.
        engine.connect(playerNode, to: mixerNode, format: format)
        playerNode.volume = volume

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

        channelVolumes.removeValue(forKey: id)
    }

    func removeAllSources() {
        let allIDs = Array(Set(Array(sourceNodes.keys) + Array(playerNodes.keys)))
        for id in allIDs {
            removeSource(id: id)
        }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        channelVolumes[id] = volume
        // Generated sources: atomic store read by the render callback
        generators[id]?.volume = volume
        // Sample sources: AVAudioPlayerNode.volume is thread-safe
        playerNodes[id]?.volume = volume
    }

    func updateBinauralParameters(for id: UUID, range: BinauralRange?, frequency: Float?) {
        guard let gen = generators[id] as? BinauralBeatGenerator else { return }
        if let range { gen.setRange(range) }
        if let freq = frequency { gen.beatFrequency = freq }
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
            setupRemoteCommandCenter()
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

    private func fadeIn(duration: TimeInterval = AudioConstants.defaultFadeDuration) {
        mixerNode.outputVolume = 0
        fadeTarget = 1.0
        let steps = Int(duration * 60) // 60 fps timer ticks
        fadeStep = 1.0 / Float(max(steps, 1))
        isFading = true
        fadeCompletion = nil
        performFade()
    }

    private func fadeOut(duration: TimeInterval = AudioConstants.defaultFadeDuration, completion: @escaping () -> Void) {
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
            if let range = binauralRange { gen.setRange(range) }
            if let freq = binauralFrequency { gen.beatFrequency = freq }
            return gen
        default:
            fatalError("Use addSampleSource for non-generated types")
        }
    }

    // MARK: - Now Playing / Control Center

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

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

    static var headphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { port in
            port.portType == .headphones ||
            port.portType == .bluetoothA2DP ||
            port.portType == .bluetoothHFP ||
            port.portType == .bluetoothLE
        }
    }
}
