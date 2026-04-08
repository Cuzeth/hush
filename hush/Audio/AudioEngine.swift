import AVFoundation
import MediaPlayer

// Central audio engine managing all sound generation and playback.
// Uses AVAudioEngine with AVAudioSourceNode for real-time DSP.
// Singleton — accessed from PlayerViewModel.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private let mixerNode = AVAudioMixerNode()
    private var sourceNodes: [UUID: AVAudioSourceNode] = [:]
    private var generators: [UUID: any SoundGenerator] = [:]
    private var channelVolumes: [UUID: Float] = [:]

    // Fade state
    private var masterVolume: Float = 1.0
    private var fadeTarget: Float = 1.0
    private var fadeStep: Float = 0
    private var isFading = false
    private var fadeCompletion: (() -> Void)?

    // Audio format: stereo, 32-bit float, 44.1 kHz, non-interleaved
    private let format: AVAudioFormat

    private(set) var isPlaying = false

    private init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: 2,
            interleaved: true
        )!

        engine.attach(mixerNode)
        engine.connect(mixerNode, to: engine.outputNode, format: format)
    }

    // MARK: - Audio Session

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(AudioConstants.sampleRate)
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }

    // MARK: - Source Management

    func addSource(id: UUID, type: SoundType, volume: Float,
                   binauralRange: BinauralRange? = nil,
                   binauralFrequency: Float? = nil) {
        // Remove existing source with same ID if present
        removeSource(id: id)

        let generator = makeGenerator(for: type, binauralRange: binauralRange,
                                       binauralFrequency: binauralFrequency)
        generator.volume = volume
        generators[id] = generator
        channelVolumes[id] = volume

        let fmt = format
        let gen = generator

        let sourceNode = AVAudioSourceNode(format: fmt) { [weak self] (isSilence, _, frameCount, outputData) -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)
            guard let self, let bufferData = ablPointer.first?.mData else {
                isSilence.pointee = true
                return noErr
            }

            let buffer = bufferData.assumingMemoryBound(to: Float.self)
            let frames = Int(frameCount)

            gen.generateSamples(into: buffer, frameCount: frames, stereo: true)

            // Apply master volume and fade
            let master = self.masterVolume
            if master < 1.0 {
                let totalSamples = frames * 2 // stereo interleaved
                for i in 0..<totalSamples {
                    buffer[i] *= master
                }
            }

            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: mixerNode, format: format)
        sourceNodes[id] = sourceNode
    }

    func removeSource(id: UUID) {
        if let node = sourceNodes.removeValue(forKey: id) {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        generators.removeValue(forKey: id)
        channelVolumes.removeValue(forKey: id)
    }

    func removeAllSources() {
        let ids = Array(sourceNodes.keys)
        for id in ids {
            removeSource(id: id)
        }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        channelVolumes[id] = volume
        generators[id]?.volume = volume
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
            self?.engine.stop()
            self?.isPlaying = false
            self?.clearNowPlaying()
        }
    }

    func togglePlayback() {
        if isPlaying { stop() } else { start() }
    }

    // MARK: - Fading

    func setMasterVolume(_ vol: Float) {
        masterVolume = max(0, min(1, vol))
    }

    private func fadeIn(duration: TimeInterval = AudioConstants.defaultFadeDuration) {
        masterVolume = 0
        fadeTarget = 1.0
        let steps = Int(duration * AudioConstants.sampleRate / 512) // approximate
        fadeStep = 1.0 / Float(max(steps, 1))
        isFading = true
        fadeCompletion = nil
        performFade()
    }

    private func fadeOut(duration: TimeInterval = AudioConstants.defaultFadeDuration, completion: @escaping () -> Void) {
        fadeTarget = 0
        let steps = Int(duration * AudioConstants.sampleRate / 512)
        fadeStep = -masterVolume / Float(max(steps, 1))
        isFading = true
        fadeCompletion = completion
        performFade()
    }

    private func performFade() {
        guard isFading else { return }
        let interval = 1.0 / 60.0 // 60 fps updates

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.isFading else { return }

            self.masterVolume += self.fadeStep

            if (self.fadeStep > 0 && self.masterVolume >= self.fadeTarget) ||
               (self.fadeStep < 0 && self.masterVolume <= self.fadeTarget) {
                self.masterVolume = self.fadeTarget
                self.isFading = false
                self.fadeCompletion?()
                self.fadeCompletion = nil
            } else {
                self.performFade()
            }
        }
    }

    // Apply timer fade multiplier (called from PlayerViewModel timer tick)
    func applyTimerFade(_ multiplier: Float) {
        masterVolume = max(0, min(1, multiplier))
    }

    // MARK: - Generator Factory

    private func makeGenerator(for type: SoundType,
                                binauralRange: BinauralRange?,
                                binauralFrequency: Float?) -> any SoundGenerator {
        switch type {
        case .whiteNoise:
            return WhiteNoiseGenerator()
        case .pinkNoise:
            return PinkNoiseGenerator()
        case .brownNoise:
            return BrownNoiseGenerator()
        case .grayNoise:
            return GrayNoiseGenerator()
        case .binauralBeats:
            let gen = BinauralBeatGenerator()
            if let range = binauralRange { gen.setRange(range) }
            if let freq = binauralFrequency { gen.beatFrequency = freq }
            return gen
        case .rain, .ocean, .thunder, .fire, .birdsong, .wind, .stream:
            let player = SampleLoopPlayer(fileName: type.sampleFileName)
            return player
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
