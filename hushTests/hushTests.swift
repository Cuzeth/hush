import Foundation
import Testing
@testable import hush

// MARK: - TimerState Tests

@MainActor
struct TimerStateTests {

    @Test func timerTracksRemainingFromPersistedEndDate() async throws {
        let state = TimerState()
        let start = Date(timeIntervalSince1970: 1_000)

        state.start(duration: 120, now: start)

        #expect(state.isRunning)
        #expect(state.remainingSeconds == 120)
        #expect(state.endDate == start.addingTimeInterval(120))

        let expired = state.syncRemaining(now: start.addingTimeInterval(45))

        #expect(expired == false)
        #expect(Int(state.remainingSeconds.rounded(.down)) == 75)
        #expect(state.isRunning)
    }

    @Test func timerClearsWhenExpired() async throws {
        let state = TimerState()
        let start = Date(timeIntervalSince1970: 2_000)

        state.start(duration: 30, now: start)
        let expired = state.syncRemaining(now: start.addingTimeInterval(35))

        #expect(expired)
        #expect(state.isRunning == false)
        #expect(state.remainingSeconds == 0)
        #expect(state.endDate == nil)
    }

    @Test func timerClearsExactlyAtExpiry() {
        let state = TimerState()
        let start = Date(timeIntervalSince1970: 3_000)

        state.start(duration: 60, now: start)
        let expired = state.syncRemaining(now: start.addingTimeInterval(60))

        #expect(expired)
        #expect(state.isRunning == false)
        #expect(state.remainingSeconds == 0)
    }

    @Test func clearResetsAllState() {
        let state = TimerState()
        state.start(duration: 120)
        state.clear()

        #expect(state.isRunning == false)
        #expect(state.remainingSeconds == 0)
        #expect(state.endDate == nil)
    }

    @Test func syncRemainingWithNoEndDateReturnsFalse() {
        let state = TimerState()
        let expired = state.syncRemaining()

        #expect(expired == false)
        #expect(state.isRunning == false)
        #expect(state.remainingSeconds == 0)
    }

    @Test func progressComputesCorrectly() {
        let state = TimerState()
        let start = Date(timeIntervalSince1970: 4_000)

        state.start(duration: 100, now: start)
        _ = state.syncRemaining(now: start.addingTimeInterval(25))

        #expect(state.progress >= 0.24 && state.progress <= 0.26)
    }

    @Test func progressIsZeroWhenDurationIsZero() {
        let state = TimerState()
        state.selectedDuration = 0
        #expect(state.progress == 0)
    }

    @Test func progressIsZeroAtStart() {
        let state = TimerState()
        state.start(duration: 60)
        #expect(state.progress == 0)
    }

    @Test func displayTimeFormatsCorrectly() {
        let state = TimerState()

        state.remainingSeconds = 125  // 2:05
        #expect(state.displayTime == "2:05")

        state.remainingSeconds = 0
        #expect(state.displayTime == "0:00")

        state.remainingSeconds = 3599  // 59:59
        #expect(state.displayTime == "59:59")

        state.remainingSeconds = 60
        #expect(state.displayTime == "1:00")
    }

    @Test func isFadingOutOnlyDuringFadeWindow() {
        let state = TimerState()
        let fadeOut = AudioConstants.timerFadeOutDuration

        // Not running — not fading
        state.isRunning = false
        state.remainingSeconds = 5
        #expect(state.isFadingOut == false)

        // Running but above fade threshold
        state.isRunning = true
        state.remainingSeconds = fadeOut + 1
        #expect(state.isFadingOut == false)

        // Running and within fade threshold
        state.remainingSeconds = fadeOut - 1
        #expect(state.isFadingOut == true)

        // Running but at exactly zero
        state.remainingSeconds = 0
        #expect(state.isFadingOut == false)
    }

    @Test func fadeMultiplierScalesLinearly() {
        let state = TimerState()
        let fadeOut = AudioConstants.timerFadeOutDuration

        state.isRunning = true

        // At full fade duration: multiplier = 1.0 (but isFadingOut is false)
        state.remainingSeconds = fadeOut
        #expect(state.fadeMultiplier == 1.0)

        // Half way through fade
        state.remainingSeconds = fadeOut / 2
        #expect(abs(state.fadeMultiplier - 0.5) < 0.01)

        // Near zero
        state.remainingSeconds = 1
        let expected = Float(1.0 / fadeOut)
        #expect(abs(state.fadeMultiplier - expected) < 0.01)

        // Not fading — multiplier is 1.0
        state.remainingSeconds = fadeOut + 5
        #expect(state.fadeMultiplier == 1.0)
    }

    @Test func startOverwritesPreviousTimer() {
        let state = TimerState()
        let t1 = Date(timeIntervalSince1970: 5_000)

        state.start(duration: 60, now: t1)
        state.start(duration: 120, now: t1.addingTimeInterval(10))

        #expect(state.selectedDuration == 120)
        #expect(state.remainingSeconds == 120)
        #expect(state.endDate == t1.addingTimeInterval(130))
    }
}

// MARK: - AudioRNG Tests

struct AudioRNGTests {

    @Test func deterministicWithSameSeed() {
        var rng1 = AudioRNG(seed: 42)
        var rng2 = AudioRNG(seed: 42)

        for _ in 0..<100 {
            #expect(rng1.next() == rng2.next())
        }
    }

    @Test func differentSeedsProduceDifferentSequences() {
        var rng1 = AudioRNG(seed: 1)
        var rng2 = AudioRNG(seed: 2)

        let values1 = (0..<10).map { _ in rng1.next() }
        let values2 = (0..<10).map { _ in rng2.next() }

        #expect(values1 != values2)
    }

    @Test func nextFloatInExpectedRange() {
        var rng = AudioRNG(seed: 12345)

        for _ in 0..<10_000 {
            let val = rng.nextFloat()
            #expect(val >= -1.0)
            #expect(val < 1.0)
        }
    }

    @Test func nextNeverReturnsZeroState() {
        var rng = AudioRNG(seed: 1)
        for _ in 0..<1_000 {
            #expect(rng.next() != 0)
        }
    }

    @Test func zeroSeedFallsBackToNonZero() {
        var rng = AudioRNG(seed: 0)
        // Should produce valid output (seed was replaced with arc4random | 1)
        let val = rng.next()
        #expect(val != 0)
    }
}

// MARK: - DCBlockingFilter Tests

struct DCBlockingFilterTests {

    @Test func removesConstantDCOffset() {
        let filter = DCBlockingFilter(sampleRate: 44100, cutoffHz: 10.0)

        // Feed a constant DC signal
        var lastOutput: Float = 0
        for _ in 0..<44100 {
            lastOutput = filter.process(1.0)
        }

        // After one second, the DC should be almost completely removed
        #expect(abs(lastOutput) < 0.01)
    }

    @Test func passesHighFrequencySignal() {
        let sampleRate: Double = 44100
        let filter = DCBlockingFilter(sampleRate: sampleRate, cutoffHz: 10.0)
        let freq = 440.0 // Well above cutoff

        var sumInput: Float = 0
        var sumOutput: Float = 0
        let frameCount = Int(sampleRate)

        // Let filter settle for 1 second, then measure for 1 second
        for i in 0..<frameCount {
            let sample = Float(sin(2.0 * Double.pi * freq * Double(i) / sampleRate))
            _ = filter.process(sample)
        }

        for i in 0..<frameCount {
            let sample = Float(sin(2.0 * Double.pi * freq * Double(i) / sampleRate))
            let output = filter.process(sample)
            sumInput += sample * sample
            sumOutput += output * output
        }

        let rmsRatio = sqrt(sumOutput / sumInput)
        // Should pass through with minimal attenuation (> 0.95)
        #expect(rmsRatio > 0.95)
    }

    @Test func resetClearsState() {
        let filter = DCBlockingFilter()

        _ = filter.process(1.0)
        _ = filter.process(0.5)
        filter.reset()

        // After reset, feeding 0 should produce 0
        let output = filter.process(0.0)
        #expect(output == 0.0)
    }

    @Test func coefficientAdjustsWithSampleRate() {
        let filter48k = DCBlockingFilter(sampleRate: 48000, cutoffHz: 10.0)
        let filter44k = DCBlockingFilter(sampleRate: 44100, cutoffHz: 10.0)

        // Both should block DC similarly
        for _ in 0..<48000 { _ = filter48k.process(1.0) }
        for _ in 0..<44100 { _ = filter44k.process(1.0) }

        let out48k = filter48k.process(1.0)
        let out44k = filter44k.process(1.0)

        // Both should have very small DC residual
        #expect(abs(out48k) < 0.01)
        #expect(abs(out44k) < 0.01)
    }
}

// MARK: - Sound Generator Tests

struct WhiteNoiseGeneratorTests {

    @Test func outputIsWithinRange() {
        let gen = WhiteNoiseGenerator()
        let frameCount = 4096
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }

    @Test func volumeScalesOutput() {
        let frameCount = 4096
        let bufferFull = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let bufferHalf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { bufferFull.deallocate(); bufferHalf.deallocate() }

        // Two generators with same seed to compare
        let gen1 = WhiteNoiseGenerator()
        let gen2 = WhiteNoiseGenerator()

        gen1.volume = 1.0
        gen1.generateMono(into: bufferFull, frameCount: frameCount)
        let rmsFull = rms(bufferFull, count: frameCount)

        gen2.volume = 0.5
        gen2.generateMono(into: bufferHalf, frameCount: frameCount)
        let rmsHalf = rms(bufferHalf, count: frameCount)

        // Half volume should be roughly half RMS
        #expect(rmsHalf < rmsFull)
        #expect(abs(rmsHalf / rmsFull - 0.5) < 0.15)
    }

    @Test func defaultVolumeIsOne() {
        let gen = WhiteNoiseGenerator()
        #expect(gen.volume == 1.0)
    }

    @Test func stereoDefaultDuplicatesMono() {
        let gen = WhiteNoiseGenerator()
        let frameCount = 1024
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(left[i] == right[i])
        }
    }
}

struct PinkNoiseGeneratorTests {

    @Test func outputIsFinite() {
        let gen = PinkNoiseGenerator()
        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i].isFinite)
        }
    }

    @Test func outputIsBounded() {
        let gen = PinkNoiseGenerator()
        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] >= -1.5 && buffer[i] <= 1.5)
        }
    }

    @Test func lowerRMSThanWhiteNoise() {
        // Pink noise should be quieter overall due to high-frequency attenuation
        let white = WhiteNoiseGenerator()
        let pink = PinkNoiseGenerator()
        let frameCount = 44100
        let bufW = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let bufP = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { bufW.deallocate(); bufP.deallocate() }

        white.generateMono(into: bufW, frameCount: frameCount)
        pink.generateMono(into: bufP, frameCount: frameCount)

        let rmsW = rms(bufW, count: frameCount)
        let rmsP = rms(bufP, count: frameCount)

        // Pink noise post-filter and *0.11 scaling should be much quieter
        #expect(rmsP < rmsW)
    }
}

struct BrownNoiseGeneratorTests {

    @Test func outputIsFiniteAndBounded() {
        let gen = BrownNoiseGenerator()
        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i].isFinite)
            // Clamped to [-1, 1] by the min/max in generateMono
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }
}

struct GrayNoiseGeneratorTests {

    @Test func outputIsFinite() {
        let gen = GrayNoiseGenerator()
        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i].isFinite)
        }
    }

    @Test func outputIsReasonablyBounded() {
        let gen = GrayNoiseGenerator()
        let frameCount = 44100 * 2
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        // With the 0.15 scaling, output should stay well under ±2
        for i in 0..<frameCount {
            #expect(buffer[i] >= -2.0 && buffer[i] <= 2.0)
        }
    }
}

struct BinauralBeatGeneratorTests {

    @Test func stereoChannelsDiffer() {
        let gen = BinauralBeatGenerator()
        gen.beatFrequency = 10
        gen.carrierFrequency = 200

        let frameCount = 4096
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        var differ = false
        for i in 0..<frameCount where abs(left[i] - right[i]) > 0.001 {
            differ = true
            break
        }
        #expect(differ, "Binaural beats must have different L/R channels")
    }

    @Test func monoOutputIsFinite() {
        let gen = BinauralBeatGenerator()
        let frameCount = 4096
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i].isFinite)
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }

    @Test func setRangeUpdatesBeatFrequency() {
        let gen = BinauralBeatGenerator()
        gen.setRange(.gamma)
        #expect(gen.beatFrequency == BinauralRange.gamma.defaultFrequency)
    }

    @Test func stereoOutputIsBounded() {
        let gen = BinauralBeatGenerator()
        gen.volume = 1.0
        let frameCount = 44100
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(left[i] >= -1.0 && left[i] <= 1.0)
            #expect(right[i] >= -1.0 && right[i] <= 1.0)
        }
    }
}

struct IsochronicToneGeneratorTests {

    @Test func outputHasAmplitudeModulation() {
        let gen = IsochronicToneGenerator()
        gen.pulseRate = 10
        gen.carrierFrequency = 200

        let frameCount = 44100  // 1 second — 10 pulses expected
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        // Find peak and trough — amplitude modulation should create near-zero samples
        var maxAbs: Float = 0
        var minAbs: Float = Float.greatestFiniteMagnitude
        var hasNearZero = false

        for i in 0..<frameCount {
            let absVal = abs(buffer[i])
            if absVal > maxAbs { maxAbs = absVal }
            if absVal < minAbs { minAbs = absVal }
            if absVal < 0.01 { hasNearZero = true }
        }

        #expect(maxAbs > 0.1, "Should have audible peaks")
        #expect(hasNearZero, "Isochronic modulation should create near-zero points")
    }

    @Test func setRangeUpdatesPulseRate() {
        let gen = IsochronicToneGenerator()
        gen.setRange(.alpha)
        #expect(gen.pulseRate == BinauralRange.alpha.defaultFrequency)
    }
}

struct MonauralBeatGeneratorTests {

    @Test func outputIsMono() {
        let gen = MonauralBeatGenerator()
        let frameCount = 4096
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        // Default stereo duplicates mono
        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(left[i] == right[i])
        }
    }

    @Test func outputIsBounded() {
        let gen = MonauralBeatGenerator()
        gen.volume = 1.0
        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }

    @Test func setRangeUpdatesBeatFrequency() {
        let gen = MonauralBeatGenerator()
        gen.setRange(.smr)
        #expect(gen.beatFrequency == BinauralRange.smr.defaultFrequency)
    }
}

struct PureToneGeneratorTests {

    @Test func outputIsBounded() {
        let gen = PureToneGenerator()
        gen.volume = 1.0
        gen.frequency = 440

        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }

    @Test func normalizationKeepsPeakUnderOne() {
        let gen = PureToneGenerator()
        gen.volume = 1.0
        gen.frequency = 100  // Low freq where harmonics align

        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        var peak: Float = 0
        for i in 0..<frameCount {
            peak = max(peak, abs(buffer[i]))
        }

        #expect(peak <= 1.001)  // Small FP tolerance
    }

    @Test func defaultFrequencyIs432() {
        let gen = PureToneGenerator()
        #expect(gen.frequency == 432.0)
    }
}

struct DroneGeneratorTests {

    @Test func outputIsFinite() {
        let gen = DroneGenerator()
        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i].isFinite)
        }
    }

    @Test func outputIsBounded() {
        let gen = DroneGenerator()
        gen.volume = 1.0
        let frameCount = 44100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] >= -1.5 && buffer[i] <= 1.5)
        }
    }

    @Test func defaultFrequencyIs432() {
        let gen = DroneGenerator()
        #expect(gen.frequency == 432.0)
    }
}

// MARK: - Constants & Enum Tests

struct BinauralRangeTests {

    @Test func allCasesHaveValidRanges() {
        for range in BinauralRange.allCases {
            #expect(range.frequencyRange.lowerBound > 0)
            #expect(range.frequencyRange.upperBound > range.frequencyRange.lowerBound)
        }
    }

    @Test func defaultFrequencyIsWithinRange() {
        for range in BinauralRange.allCases {
            #expect(range.frequencyRange.contains(range.defaultFrequency),
                    "\(range.rawValue) default \(range.defaultFrequency) not in \(range.frequencyRange)")
        }
    }

    @Test func specificRangeValues() {
        #expect(BinauralRange.alpha.frequencyRange == 8...13)
        #expect(BinauralRange.smr.frequencyRange == 12...15)
        #expect(BinauralRange.beta.frequencyRange == 13...30)
        #expect(BinauralRange.gamma.frequencyRange == 38...42)

        #expect(BinauralRange.alpha.defaultFrequency == 10)
        #expect(BinauralRange.smr.defaultFrequency == 13)
        #expect(BinauralRange.beta.defaultFrequency == 20)
        #expect(BinauralRange.gamma.defaultFrequency == 40)
    }

    @Test func rawValueRoundTrips() {
        for range in BinauralRange.allCases {
            #expect(BinauralRange(rawValue: range.rawValue) == range)
        }
    }

    @Test func descriptionsAreNonEmpty() {
        for range in BinauralRange.allCases {
            #expect(!range.description.isEmpty)
        }
    }
}

struct SoundTypeTests {

    @Test func generatedTypesAreCorrect() {
        let generated: [SoundType] = [.whiteNoise, .pinkNoise, .brownNoise, .grayNoise,
                                       .binauralBeats, .isochronicTones, .monauralBeats,
                                       .pureTone, .drone]
        for type in generated {
            #expect(type.isGenerated, "\(type.rawValue) should be generated")
            #expect(!type.isLegacySample)
        }
    }

    @Test func legacySampleTypesAreCorrect() {
        let legacy: [SoundType] = [.rain, .ocean, .thunder, .fire, .birdsong, .wind, .stream]
        for type in legacy {
            #expect(type.isLegacySample, "\(type.rawValue) should be legacy sample")
            #expect(!type.isGenerated)
        }
    }

    @Test func sampleAssetIsNeitherGeneratedNorLegacy() {
        #expect(!SoundType.sampleAsset.isGenerated)
        #expect(!SoundType.sampleAsset.isLegacySample)
    }

    @Test func legacyTypesHaveSampleFileNames() {
        let legacy: [SoundType] = [.rain, .ocean, .thunder, .fire, .birdsong, .wind, .stream]
        for type in legacy {
            #expect(type.sampleFileName != nil, "\(type.rawValue) should have sampleFileName")
        }
    }

    @Test func generatedTypesHaveNoSampleFileName() {
        let generated: [SoundType] = [.whiteNoise, .pinkNoise, .brownNoise, .grayNoise,
                                       .binauralBeats, .isochronicTones, .monauralBeats,
                                       .pureTone, .drone]
        for type in generated {
            #expect(type.sampleFileName == nil)
        }
    }

    @Test func legacyTypesHaveDefaultAssetIDs() {
        let legacy: [SoundType] = [.rain, .ocean, .thunder, .fire, .birdsong, .wind, .stream]
        for type in legacy {
            #expect(type.defaultAssetID != nil, "\(type.rawValue) should have defaultAssetID")
        }
    }

    @Test func allTypesHaveIcons() {
        for type in SoundType.allCases {
            #expect(!type.icon.isEmpty, "\(type.rawValue) should have an icon")
        }
    }

    @Test func rawValueRoundTrips() {
        for type in SoundType.allCases {
            #expect(SoundType(rawValue: type.rawValue) == type)
        }
    }
}

struct TonePresetTests {

    @Test func frequenciesArePositive() {
        for preset in TonePreset.allCases {
            #expect(preset.frequency > 0)
        }
    }

    @Test func specificFrequencies() {
        #expect(TonePreset.hz174.frequency == 174)
        #expect(TonePreset.hz285.frequency == 285)
        #expect(TonePreset.hz396.frequency == 396)
        #expect(TonePreset.hz432.frequency == 432)
        #expect(TonePreset.hz528.frequency == 528)
        #expect(TonePreset.hz639.frequency == 639)
        #expect(TonePreset.hz741.frequency == 741)
        #expect(TonePreset.hz852.frequency == 852)
    }

    @Test func labelsMatchRawValues() {
        for preset in TonePreset.allCases {
            #expect(preset.label == preset.rawValue)
        }
    }

    @Test func frequenciesAreInAscendingOrder() {
        let frequencies = TonePreset.allCases.map(\.frequency)
        for i in 1..<frequencies.count {
            #expect(frequencies[i] > frequencies[i - 1])
        }
    }
}

struct TimerDurationTests {

    @Test func secondsConversion() {
        #expect(TimerDuration.fifteen.seconds == 900)
        #expect(TimerDuration.twentyFive.seconds == 1500)
        #expect(TimerDuration.thirty.seconds == 1800)
        #expect(TimerDuration.fortyFive.seconds == 2700)
        #expect(TimerDuration.sixty.seconds == 3600)
        #expect(TimerDuration.ninety.seconds == 5400)
    }

    @Test func labelsEndWithMin() {
        for duration in TimerDuration.allCases {
            #expect(duration.label.hasSuffix("min"))
        }
    }

    @Test func durationsAreInAscendingOrder() {
        let values = TimerDuration.allCases.map(\.rawValue)
        for i in 1..<values.count {
            #expect(values[i] > values[i - 1])
        }
    }
}

// MARK: - SoundAsset & Registry Tests

struct SoundAssetRegistryTests {

    @Test func registryIsNotEmpty() {
        #expect(!SoundAssetRegistry.all.isEmpty)
    }

    @Test func allAssetsHaveUniqueIDs() {
        let ids = SoundAssetRegistry.all.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Duplicate asset IDs found")
    }

    @Test func lookupByIDWorks() {
        for asset in SoundAssetRegistry.all {
            let found = SoundAssetRegistry.asset(withID: asset.id)
            #expect(found != nil)
            #expect(found?.id == asset.id)
        }
    }

    @Test func lookupNonexistentIDReturnsNil() {
        #expect(SoundAssetRegistry.asset(withID: "nonexistent.id") == nil)
    }

    @Test func categoryFilterWorks() {
        let rainAssets = SoundAssetRegistry.assets(for: .rain)
        #expect(!rainAssets.isEmpty)
        for asset in rainAssets {
            #expect(asset.category == .rain)
        }
    }

    @Test func everyCategoryHasAtLeastOneAsset() {
        for category in SoundCategory.allCases {
            let assets = SoundAssetRegistry.assets(for: category)
            #expect(!assets.isEmpty, "Category \(category.rawValue) has no assets")
        }
    }

    @Test func legacyDefaultAssetIDsResolve() {
        let legacyTypes: [SoundType] = [.rain, .ocean, .thunder, .fire, .birdsong, .wind, .stream]
        for type in legacyTypes {
            let assetID = type.defaultAssetID!
            let asset = SoundAssetRegistry.asset(withID: assetID)
            #expect(asset != nil, "Legacy type \(type.rawValue) default asset '\(assetID)' not in registry")
        }
    }

    @Test func allAssetsHaveNonEmptyFields() {
        for asset in SoundAssetRegistry.all {
            #expect(!asset.id.isEmpty)
            #expect(!asset.displayName.isEmpty)
            #expect(!asset.fileName.isEmpty)
            #expect(!asset.fileExtension.isEmpty)
            #expect(!asset.subdirectory.isEmpty)
        }
    }
}

struct SoundAssetTests {

    @Test func crossfadeDurationsByStyle() {
        let stochastic = SoundAsset(id: "test.s", displayName: "T", category: .rain,
                                     fileName: "f", fileExtension: "mp3", subdirectory: "S",
                                     license: .cc0, crossfadeStyle: .stochastic, isMono: false)
        let rhythmic = SoundAsset(id: "test.r", displayName: "T", category: .rain,
                                   fileName: "f", fileExtension: "mp3", subdirectory: "S",
                                   license: .cc0, crossfadeStyle: .rhythmic, isMono: false)
        let percussive = SoundAsset(id: "test.p", displayName: "T", category: .rain,
                                     fileName: "f", fileExtension: "mp3", subdirectory: "S",
                                     license: .cc0, crossfadeStyle: .percussive, isMono: false)

        #expect(stochastic.crossfadeDurationMs == 100.0)
        #expect(rhythmic.crossfadeDurationMs == 300.0)
        #expect(percussive.crossfadeDurationMs == 50.0)
    }

    @Test func iconMatchesCategory() {
        let asset = SoundAsset(id: "test", displayName: "T", category: .fire,
                                fileName: "f", fileExtension: "mp3", subdirectory: "S",
                                license: .cc0, crossfadeStyle: .stochastic, isMono: false)
        #expect(asset.icon == SoundCategory.fire.icon)
    }

    @Test func equalityAndHashingByID() {
        let a = SoundAsset(id: "same", displayName: "A", category: .rain,
                            fileName: "a", fileExtension: "mp3", subdirectory: "S",
                            license: .cc0, crossfadeStyle: .stochastic, isMono: false)
        let b = SoundAsset(id: "same", displayName: "B", category: .fire,
                            fileName: "b", fileExtension: "wav", subdirectory: "T",
                            license: .mit, crossfadeStyle: .rhythmic, isMono: true)

        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}

struct SoundCategoryTests {

    @Test func allCategoriesHaveIcons() {
        for category in SoundCategory.allCases {
            #expect(!category.icon.isEmpty)
        }
    }

    @Test func rawValueRoundTrips() {
        for category in SoundCategory.allCases {
            #expect(SoundCategory(rawValue: category.rawValue) == category)
        }
    }
}

// MARK: - SoundSource Tests

@MainActor
struct SoundSourceTests {

    @Test func codableRoundTrip() throws {
        let source = SoundSource(type: .brownNoise, volume: 0.7, isActive: true,
                                  binauralRange: .alpha, binauralFrequency: 10,
                                  toneFrequency: 432, assetID: nil)

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SoundSource.self, from: data)

        #expect(decoded.type == source.type)
        #expect(decoded.volume == source.volume)
        #expect(decoded.isActive == source.isActive)
        #expect(decoded.binauralRange == source.binauralRange)
        #expect(decoded.binauralFrequency == source.binauralFrequency)
        #expect(decoded.toneFrequency == source.toneFrequency)
        #expect(decoded.assetID == source.assetID)
    }

    @Test func codableRoundTripWithAsset() throws {
        let source = SoundSource(type: .sampleAsset, volume: 0.8, assetID: "moodist.rain.heavy")

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SoundSource.self, from: data)

        #expect(decoded.type == .sampleAsset)
        #expect(decoded.assetID == "moodist.rain.heavy")
    }

    @Test func assetConvenienceInitSetsCorrectFields() {
        let asset = SoundAssetRegistry.all.first!
        let source = SoundSource(asset: asset, volume: 0.9)

        #expect(source.type == .sampleAsset)
        #expect(source.assetID == asset.id)
        #expect(source.volume == 0.9)
        #expect(source.isActive == true)
    }

    @Test func resolvedAssetForLegacyType() {
        let source = SoundSource(type: .rain, volume: 0.5)
        let resolved = source.resolvedAsset
        #expect(resolved != nil)
        #expect(resolved?.id == "sample.rain.calming")
    }

    @Test func resolvedAssetForSampleAsset() {
        let source = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "moodist.rain.heavy")
        let resolved = source.resolvedAsset
        #expect(resolved != nil)
        #expect(resolved?.id == "moodist.rain.heavy")
    }

    @Test func resolvedAssetNilForGeneratedTypes() {
        let source = SoundSource(type: .whiteNoise, volume: 0.5)
        #expect(source.resolvedAsset == nil)
    }

    @Test func displayNameFallsBackToTypeRawValue() {
        let source = SoundSource(type: .whiteNoise, volume: 0.5)
        #expect(source.displayName == "White Noise")
    }

    @Test func displayNameUsesAssetName() {
        let source = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "moodist.rain.heavy")
        #expect(source.displayName == "Heavy Rain")
    }

    @Test func displayIconUsesAssetCategoryIcon() {
        let source = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "moodist.rain.heavy")
        #expect(source.displayIcon == SoundCategory.rain.icon)
    }

    @Test func displayIconFallsBackToTypeIcon() {
        let source = SoundSource(type: .brownNoise, volume: 0.5)
        #expect(source.displayIcon == SoundType.brownNoise.icon)
    }

    @Test func hashableConformance() {
        let a = SoundSource(type: .whiteNoise, volume: 0.5)
        let b = SoundSource(type: .whiteNoise, volume: 0.5)
        // Different UUIDs so they should not be equal
        #expect(a != b)

        // Same instance should be equal
        let set: Set<SoundSource> = [a, b]
        #expect(set.count == 2)
    }

    @Test func arrayEncodeDecode() throws {
        let sources = [
            SoundSource(type: .brownNoise, volume: 0.6),
            SoundSource(type: .rain, volume: 0.4),
            SoundSource(type: .sampleAsset, volume: 1.0, assetID: "moodist.places.cafe"),
        ]

        let data = try JSONEncoder().encode(sources)
        let decoded = try JSONDecoder().decode([SoundSource].self, from: data)

        #expect(decoded.count == 3)
        #expect(decoded[0].type == .brownNoise)
        #expect(decoded[1].type == .rain)
        #expect(decoded[2].assetID == "moodist.places.cafe")
    }
}

// MARK: - Preset Tests

@MainActor
struct PresetTests {

    @Test func builtInPresetsAreNotEmpty() {
        #expect(!Preset.builtIn.isEmpty)
    }

    @Test func allBuiltInPresetsHaveSources() {
        for preset in Preset.builtIn {
            #expect(!preset.sources.isEmpty, "\(preset.name) has no sources")
        }
    }

    @Test func allBuiltInPresetsAreMarkedBuiltIn() {
        for preset in Preset.builtIn {
            #expect(preset.isBuiltIn, "\(preset.name) should be built-in")
        }
    }

    @Test func builtInPresetsHaveUniqueNames() {
        let names = Preset.builtIn.map(\.name)
        let unique = Set(names)
        #expect(names.count == unique.count, "Duplicate preset names")
    }

    @Test func builtInPresetsHaveIcons() {
        for preset in Preset.builtIn {
            #expect(!preset.icon.isEmpty, "\(preset.name) has no icon")
        }
    }

    @Test func presetCodableRoundTrip() throws {
        let preset = Preset(name: "Test", icon: "star", sources: [
            SoundSource(type: .whiteNoise, volume: 0.5),
            SoundSource(type: .rain, volume: 0.3),
        ], isBuiltIn: false)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)

        #expect(decoded.name == "Test")
        #expect(decoded.icon == "star")
        #expect(decoded.sources.count == 2)
        #expect(decoded.isBuiltIn == false)
    }

    @Test func assetBasedPresetsResolveCorrectly() {
        // Coffee Shop, Rainy Day, Forest, Cozy all use makeSource
        let coffeeShop = Preset.builtIn.first { $0.name == "Coffee Shop" }
        #expect(coffeeShop != nil)
        #expect(!coffeeShop!.sources.isEmpty)

        // All sources should resolve to valid assets
        for source in coffeeShop!.sources {
            if source.type == .sampleAsset {
                #expect(source.resolvedAsset != nil,
                        "Asset \(source.assetID ?? "nil") should resolve")
            }
        }
    }
}

@MainActor
struct SavedPresetTests {

    @Test func initEncodesSources() {
        let sources = [
            SoundSource(type: .pinkNoise, volume: 0.5),
            SoundSource(type: .fire, volume: 0.3),
        ]
        let saved = SavedPreset(name: "My Preset", icon: "flame", sources: sources)

        #expect(saved.name == "My Preset")
        #expect(saved.icon == "flame")
        #expect(saved.sources.count == 2)
        #expect(saved.sources[0].type == .pinkNoise)
    }

    @Test func sourcesGetterCachesResult() {
        let saved = SavedPreset(name: "Test", icon: "star", sources: [
            SoundSource(type: .whiteNoise, volume: 1.0),
        ])

        let first = saved.sources
        let second = saved.sources

        // Should return same content (cached)
        #expect(first.count == second.count)
        #expect(first[0].type == second[0].type)
    }

    @Test func sourcesSetterUpdatesData() {
        let saved = SavedPreset(name: "Test", icon: "star", sources: [
            SoundSource(type: .whiteNoise, volume: 1.0),
        ])

        saved.sources = [
            SoundSource(type: .brownNoise, volume: 0.5),
            SoundSource(type: .rain, volume: 0.3),
        ]

        #expect(saved.sources.count == 2)
        #expect(saved.sources[0].type == .brownNoise)
    }

    @Test func toPresetCreatesCorrectPreset() {
        let sources = [SoundSource(type: .ocean, volume: 0.6)]
        let saved = SavedPreset(name: "Ocean Vibes", icon: "tropicalstorm", sources: sources)

        let preset = saved.toPreset()

        #expect(preset.name == "Ocean Vibes")
        #expect(preset.icon == "tropicalstorm")
        #expect(preset.id == saved.stableID)
        #expect(preset.isBuiltIn == false)
        #expect(preset.sources.count == 1)
    }
}

// MARK: - AudioConstants Tests

struct AudioConstantsTests {

    @Test func sampleRateIsStandard() {
        #expect(AudioConstants.sampleRate == 44100.0)
    }

    @Test func maxSourcesIsReasonable() {
        #expect(AudioConstants.maxSimultaneousSources > 0)
        #expect(AudioConstants.maxSimultaneousSources <= 10)
    }

    @Test func fadeDurationIsPositive() {
        #expect(AudioConstants.defaultFadeDuration > 0)
    }

    @Test func timerFadeOutDurationIsPositive() {
        #expect(AudioConstants.timerFadeOutDuration > 0)
    }

    @Test func binauralCarrierIsInAudibleRange() {
        #expect(AudioConstants.defaultBinauralCarrier >= 100)
        #expect(AudioConstants.defaultBinauralCarrier <= 500)
    }
}

// MARK: - Helpers

private func rms(_ buffer: UnsafeMutablePointer<Float>, count: Int) -> Float {
    var sum: Float = 0
    for i in 0..<count { sum += buffer[i] * buffer[i] }
    return sqrt(sum / Float(count))
}
