import AVFoundation
import Foundation
import Testing
@testable import hush

// Engine-level fixes that can be verified without audio hardware. Suites that
// touch `AudioEngine.shared` are @MainActor (the engine asserts main) and
// restore every callback / seam they swap.

// MARK: - Generators added mid-play fade in from silence

@MainActor
struct VolumeRampFromSilenceTests {

    @Test func rampStartingAtZeroRisesFromSilence() {
        var ramp = VolumeRamp()
        // First buffer snaps to the target — a generator attached to a
        // running engine sets its target to 0 first, so it snaps to silence.
        let first = ramp.step(toward: 0, frameCount: 256)
        #expect(first.gain == 0)
        #expect(first.step == 0)

        // The fade then ramps up from 0 instead of starting at full gain.
        let second = ramp.step(toward: 0.5, frameCount: 100)
        #expect(second.gain == 0)
        #expect(abs(second.step - 0.005) < 1e-6)
    }

    @Test func generatorAttachedSilentRampsUpInsteadOfJumping() {
        let gen = WhiteNoiseGenerator()
        let frames = 512
        var buffer = [Float](repeating: 1, count: frames)

        gen.volume = 0
        buffer.withUnsafeMutableBufferPointer { gen.generateMono(into: $0.baseAddress!, frameCount: frames) }
        #expect(buffer.allSatisfy { $0 == 0 })

        gen.volume = 1
        buffer.withUnsafeMutableBufferPointer { gen.generateMono(into: $0.baseAddress!, frameCount: frames) }
        // Noise is in [-1, 1], so a linear ramp from 0 bounds sample i by i/N.
        let overshoot = buffer.enumerated().map { abs($0.element) - Float($0.offset) / Float(frames) }.max() ?? 0
        #expect(overshoot <= 1e-5)
        #expect(buffer.contains { $0 != 0 })
    }
}

// MARK: - Generator removal waits for the ramp to render

struct RenderTickerTests {

    @Test func countsCompletedCycles() {
        let ticker = RenderTicker()
        #expect(ticker.count == 0)
        ticker.tick()
        ticker.tick()
        #expect(ticker.count == 2)
    }

    @Test func rampNeedsTwoCompletedCyclesPastTheMark() {
        // The cycle in flight at the gain write may still have read the old
        // target; only the one after it is guaranteed to ramp to 0.
        #expect(!RenderTicker.hasRenderedRamp(count: 10, since: 10))
        #expect(!RenderTicker.hasRenderedRamp(count: 11, since: 10))
        #expect(RenderTicker.hasRenderedRamp(count: 12, since: 10))
        #expect(RenderTicker.hasRenderedRamp(count: 40, since: 10))
    }

    @Test func rampCheckSurvivesCounterWraparound() {
        #expect(!RenderTicker.hasRenderedRamp(count: 0, since: UInt32.max))
        #expect(RenderTicker.hasRenderedRamp(count: 1, since: UInt32.max))
    }
}

// MARK: - Buffer cache: sample rate in the key, format check, generations

@MainActor
struct SampleBufferCacheTests {

    private static func format(_ rate: Double, channels: AVAudioChannelCount = 2) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    @Test func cacheKeyIncludesSampleRate() {
        let at44 = AudioEngine.bufferCacheKey(assetID: "nature.rain", sampleRate: 44_100)
        let at48 = AudioEngine.bufferCacheKey(assetID: "nature.rain", sampleRate: 48_000)
        #expect(at44 != at48)
        #expect(at44 == AudioEngine.bufferCacheKey(assetID: "nature.rain", sampleRate: 44_100))
        #expect(at44 != AudioEngine.bufferCacheKey(assetID: "nature.wind", sampleRate: 44_100))
    }

    @Test func bufferMustMatchNodeFormatBeforeScheduling() throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: Self.format(44_100), frameCapacity: 16))
        #expect(AudioEngine.buffer(buffer, matches: Self.format(44_100)))
        #expect(!AudioEngine.buffer(buffer, matches: Self.format(48_000)))
        #expect(!AudioEngine.buffer(buffer, matches: Self.format(44_100, channels: 1)))
    }

    @Test func invalidateBumpsOnlyThatAssetsGeneration() {
        let engine = AudioEngine.shared
        let assetID = "user.\(UUID().uuidString)"
        let otherID = "user.\(UUID().uuidString)"
        let before = engine.bufferGeneration(for: assetID)
        let otherBefore = engine.bufferGeneration(for: otherID)

        engine.invalidateCachedBuffer(assetID: assetID)
        #expect(engine.bufferGeneration(for: assetID) == before + 1)
        engine.invalidateCachedBuffer(assetID: assetID)
        #expect(engine.bufferGeneration(for: assetID) == before + 2)
        #expect(engine.bufferGeneration(for: otherID) == otherBefore)
    }
}

// MARK: - start() idempotence

@MainActor
struct StartPathTests {

    @Test func startWhilePlayingIsANoOp() {
        #expect(AudioEngine.startPath(isPlaying: true, engineRunning: true, stopFadePending: false) == .alreadyPlaying)
    }

    @Test func startDuringStopFadeOutResumesInsteadOfRestarting() {
        #expect(AudioEngine.startPath(isPlaying: false, engineRunning: true, stopFadePending: true) == .resumeFromFadeOut)
    }

    @Test func stoppedOrDeadEngineDoesAFullStart() {
        #expect(AudioEngine.startPath(isPlaying: false, engineRunning: false, stopFadePending: false) == .fullStart)
        #expect(AudioEngine.startPath(isPlaying: false, engineRunning: true, stopFadePending: false) == .fullStart)
        // Engine I/O died under us: restart it even though isPlaying is set.
        #expect(AudioEngine.startPath(isPlaying: true, engineRunning: false, stopFadePending: false) == .fullStart)
        #expect(AudioEngine.startPath(isPlaying: false, engineRunning: false, stopFadePending: true) == .fullStart)
    }
}

// MARK: - Interruption flags

@MainActor
@Suite(.serialized)
struct InterruptionRecoveryTests {

    private static func interruption(_ type: AVAudioSession.InterruptionType) -> Notification {
        Notification(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
    }

    @Test func startClearsInterruptionThatNeverEnded() {
        let engine = AudioEngine.shared
        let savedStarter = engine.startEngineIO
        let savedStateCallback = engine.onPlaybackStateChanged
        let savedErrorCallback = engine.onError
        engine.onPlaybackStateChanged = nil
        engine.onError = nil
        defer {
            engine.stop()
            if engine.isInterrupted { engine.handleInterruption(Self.interruption(.ended)) }
            engine.startEngineIO = savedStarter
            engine.onPlaybackStateChanged = savedStateCallback
            engine.onError = savedErrorCallback
        }

        engine.handleInterruption(Self.interruption(.began))
        #expect(engine.isInterrupted)

        // Another app took the session; iOS never delivers `.ended`. The
        // user presses play: once engine I/O is up, the flags must clear.
        engine.startEngineIO = { _ in }
        engine.start()
        #expect(engine.isPlaying)
        #expect(!engine.isInterrupted)
        #expect(!engine.shouldResumeAfterInterruption)
    }

    @Test func endedWithoutResumeClearsFlagsAndStaysPaused() {
        let engine = AudioEngine.shared
        let savedStateCallback = engine.onPlaybackStateChanged
        engine.onPlaybackStateChanged = nil
        defer { engine.onPlaybackStateChanged = savedStateCallback }

        engine.handleInterruption(Self.interruption(.began))
        #expect(engine.isInterrupted)
        #expect(!engine.isPlaying)

        engine.handleInterruption(Self.interruption(.ended))
        #expect(!engine.isInterrupted)
        #expect(!engine.shouldResumeAfterInterruption)
        #expect(!engine.isPlaying)
    }
}

// MARK: - Remote transport routes through the VM

@MainActor
@Suite(.serialized)
struct RemoteTransportRoutingTests {

    @Test func remoteCommandsInvokeCallbacks() {
        let engine = AudioEngine.shared
        let saved = (engine.onRemotePlay, engine.onRemotePause, engine.onRemoteTogglePlayback)
        defer {
            engine.onRemotePlay = saved.0
            engine.onRemotePause = saved.1
            engine.onRemoteTogglePlayback = saved.2
        }

        var calls: [String] = []
        engine.onRemotePlay = { calls.append("play") }
        engine.onRemotePause = { calls.append("pause") }
        engine.onRemoteTogglePlayback = { calls.append("toggle") }

        engine.handleRemotePlay()
        engine.handleRemotePause()
        engine.handleRemoteTogglePlayback()
        #expect(calls == ["play", "pause", "toggle"])
    }

    @Test func viewModelWiresRemoteTransport() {
        let viewModel = PlayerViewModel()
        let engine = AudioEngine.shared
        #expect(engine.onRemotePlay != nil)
        #expect(engine.onRemotePause != nil)
        #expect(engine.onRemoteTogglePlayback != nil)

        viewModel.isPlaying = true
        engine.handleRemotePause()
        #expect(!viewModel.isPlaying, "Remote pause must go through PlayerViewModel.stop()")

        viewModel.isPlaying = true
        engine.handleRemoteTogglePlayback()
        #expect(!viewModel.isPlaying, "Remote toggle must go through PlayerViewModel.togglePlayback()")

        // No sources: the VM's play() is a no-op, so a remote Play must not
        // start the engine behind its back.
        engine.handleRemotePlay()
        #expect(!viewModel.isPlaying)
        #expect(!engine.isPlaying)
    }
}

// MARK: - Route loss pauses

struct RouteLossTests {

    @Test func privateOutputsPauseWhenLost() {
        let pausing: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio, .carAudio, .airPlay]
        for port in pausing {
            #expect(AudioEngine.pausesOnRouteLoss(port), "\(port.rawValue) should pause on loss")
        }
    }

    @Test func builtInOutputsDoNotPause() {
        let nonPausing: [AVAudioSession.Port] = [.builtInSpeaker, .builtInReceiver, .HDMI]
        for port in nonPausing {
            #expect(!AudioEngine.pausesOnRouteLoss(port), "\(port.rawValue) should not pause on loss")
        }
    }
}

// MARK: - Deleted user import and source diffing

@MainActor
@Suite(.serialized)
struct EngineSourceSyncTests {

    @Test func unresolvedUserImportReportsMissing() {
        let engine = AudioEngine.shared
        let saved = engine.onSampleAssetMissing
        var reported: [String] = []
        engine.onSampleAssetMissing = { reported.append($0) }

        let assetID = "user.\(UUID().uuidString)"
        let source = SoundSource(type: .sampleAsset, volume: 1, assetID: assetID)
        defer {
            engine.removeSource(id: source.id)
            engine.onSampleAssetMissing = saved
        }

        engine.syncSources([source])
        #expect(reported == [assetID])
        #expect(engine.attachedNode(for: source.id) == nil)
        #expect(engine.activeSourceIDs.contains(source.id))

        // Nothing attached, so the next play() retries — the file may be back.
        engine.syncSources([source])
        #expect(reported == [assetID, assetID])
    }

    @Test func syncKeepsUnchangedSourcesAndDiffsTheRest() throws {
        let engine = AudioEngine.shared
        engine.syncSources([])
        defer { engine.syncSources([]) }

        let white = SoundSource(type: .whiteNoise, volume: 0.5)
        var pink = SoundSource(type: .pinkNoise, volume: 0.4)
        engine.syncSources([white, pink])
        #expect(engine.activeSourceIDs == [white.id, pink.id])
        let pinkNode = try #require(engine.attachedNode(for: pink.id))

        // Drop one, add one, change another's volume.
        pink.volume = 0.8
        let brown = SoundSource(type: .brownNoise, volume: 0.3)
        engine.syncSources([pink, brown])
        #expect(engine.activeSourceIDs == [pink.id, brown.id])
        #expect(engine.configuredVolume(for: white.id) == nil)
        #expect(engine.configuredVolume(for: pink.id) == 0.8)
        #expect(engine.attachedNode(for: pink.id) === pinkNode, "Kept source must be updated in place, not re-attached")
        #expect(engine.attachedNode(for: brown.id) != nil)

        // Same id, different sound: re-attached.
        var pinkAsDrone = pink
        pinkAsDrone.type = .drone
        pinkAsDrone.toneFrequency = 432
        engine.syncSources([pinkAsDrone, brown])
        let droneNode = try #require(engine.attachedNode(for: pink.id))
        #expect(droneNode !== pinkNode)

        engine.syncSources([])
        #expect(engine.activeSourceIDs.isEmpty)
    }
}
