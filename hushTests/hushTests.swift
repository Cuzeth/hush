import AVFoundation
import Foundation
import SwiftData
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
        // Pink noise should be quieter due to IIR filtering and 0.11 gain scaling
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

        // Find peak and check that amplitude modulation creates near-zero samples
        var maxAbs: Float = 0
        var hasNearZero = false

        for i in 0..<frameCount {
            let absVal = abs(buffer[i])
            if absVal > maxAbs { maxAbs = absVal }
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
                                       .speechMasking, .binauralBeats, .isochronicTones,
                                       .monauralBeats, .pureTone, .drone]
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
                                       .speechMasking, .binauralBeats, .isochronicTones,
                                       .monauralBeats, .pureTone, .drone]
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

    @Test func codableRoundTripWithMaskingStrength() throws {
        let source = SoundSource(type: .speechMasking, volume: 0.6, maskingStrength: 0.75)

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SoundSource.self, from: data)

        #expect(decoded.type == .speechMasking)
        #expect(decoded.volume == 0.6)
        #expect(decoded.maskingStrength == 0.75)
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

    @Test func sourcesGetterDecodesConsistently() {
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
        #expect(AudioConstants.maxSimultaneousSources <= 6)
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

// MARK: - Generator Edge Case & Stress Tests

struct GeneratorSampleRateTests {

    @Test func whiteNoiseAt48kHz() {
        let gen = WhiteNoiseGenerator(sampleRate: 48000)
        let frameCount = 48000
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }

    @Test func brownNoiseAt48kHz() {
        let gen = BrownNoiseGenerator(sampleRate: 48000)
        let frameCount = 48000
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i].isFinite)
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }

    @Test func binauralBeatAt48kHz() {
        let gen = BinauralBeatGenerator(sampleRate: 48000)
        gen.beatFrequency = 10
        gen.carrierFrequency = 200

        let frameCount = 48000
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(left[i] >= -1.0 && left[i] <= 1.0)
            #expect(right[i] >= -1.0 && right[i] <= 1.0)
        }
    }

    @Test func pureToneAt48kHz() {
        let gen = PureToneGenerator(sampleRate: 48000)
        gen.frequency = 440

        let frameCount = 48000
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] >= -1.0 && buffer[i] <= 1.0)
        }
    }

    @Test func droneAt48kHz() {
        let gen = DroneGenerator(sampleRate: 48000)
        let frameCount = 48000
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i].isFinite)
            #expect(buffer[i] >= -1.5 && buffer[i] <= 1.5)
        }
    }
}

struct GeneratorVolumeZeroTests {

    @Test func whiteNoiseSilentAtZeroVolume() {
        let gen = WhiteNoiseGenerator()
        gen.volume = 0

        let frameCount = 4096
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] == 0.0, "White noise at volume 0 should produce silence")
        }
    }

    @Test func pureToneSilentAtZeroVolume() {
        let gen = PureToneGenerator()
        gen.volume = 0
        gen.frequency = 440

        let frameCount = 4096
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        gen.generateMono(into: buffer, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(buffer[i] == 0.0, "Pure tone at volume 0 should produce silence")
        }
    }

    @Test func binauralSilentAtZeroVolume() {
        let gen = BinauralBeatGenerator()
        gen.volume = 0

        let frameCount = 4096
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(left[i] == 0.0 && right[i] == 0.0,
                    "Binaural at volume 0 should produce silence")
        }
    }
}

struct BinauralEdgeCaseTests {

    @Test func zeroBeatFrequencyProducesIdenticalChannels() {
        let gen = BinauralBeatGenerator()
        gen.beatFrequency = 0
        gen.carrierFrequency = 200

        let frameCount = 4096
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(left[i] == right[i],
                    "Zero beat frequency should produce identical L/R (pure carrier)")
        }
    }
}

struct FrequencyChangeTests {

    @Test func pureToneFrequencyChangeAffectsOutput() {
        let gen = PureToneGenerator()
        gen.volume = 1.0
        let frameCount = 4096

        let buf1 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let buf2 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buf1.deallocate(); buf2.deallocate() }

        gen.frequency = 220
        gen.generateMono(into: buf1, frameCount: frameCount)

        // Reset phase by creating a new generator
        let gen2 = PureToneGenerator()
        gen2.volume = 1.0
        gen2.frequency = 880
        gen2.generateMono(into: buf2, frameCount: frameCount)

        var differ = false
        for i in 0..<frameCount where abs(buf1[i] - buf2[i]) > 0.001 {
            differ = true
            break
        }
        #expect(differ, "Different frequencies should produce different output")
    }

    @Test func droneFrequencyChangeAffectsOutput() {
        let gen1 = DroneGenerator()
        gen1.volume = 1.0
        gen1.frequency = 220
        let frameCount = 4096

        let buf1 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let buf2 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buf1.deallocate(); buf2.deallocate() }

        gen1.generateMono(into: buf1, frameCount: frameCount)

        let gen2 = DroneGenerator()
        gen2.volume = 1.0
        gen2.frequency = 880
        gen2.generateMono(into: buf2, frameCount: frameCount)

        var differ = false
        for i in 0..<frameCount where abs(buf1[i] - buf2[i]) > 0.001 {
            differ = true
            break
        }
        #expect(differ, "Different frequencies should produce different output")
    }
}

struct GeneratorStressTests {

    @Test func allGeneratorsStableOver10Seconds() {
        let frameCount = 48000 * 10  // 10 seconds at 48kHz
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        let generators: [any SoundGenerator] = [
            WhiteNoiseGenerator(sampleRate: 48000),
            PinkNoiseGenerator(sampleRate: 48000),
            BrownNoiseGenerator(sampleRate: 48000),
            GrayNoiseGenerator(sampleRate: 48000),
            PureToneGenerator(sampleRate: 48000),
            DroneGenerator(sampleRate: 48000),
        ]

        for gen in generators {
            gen.generateMono(into: buffer, frameCount: frameCount)

            for i in 0..<frameCount {
                #expect(buffer[i].isFinite, "Generator produced non-finite value at frame \(i)")
            }
        }
    }

    @Test func binauralStableOver10Seconds() {
        let frameCount = 48000 * 10
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { left.deallocate(); right.deallocate() }

        let gen = BinauralBeatGenerator(sampleRate: 48000)
        gen.beatFrequency = 10
        gen.carrierFrequency = 200
        gen.generateStereo(left: left, right: right, frameCount: frameCount)

        for i in 0..<frameCount {
            #expect(left[i].isFinite && right[i].isFinite,
                    "Binaural produced non-finite value at frame \(i)")
        }
    }
}

// MARK: - Additional Model Tests

@MainActor
struct SoundSourceEdgeCaseTests {

    @Test func invalidAssetIDReturnsNilResolvedAsset() {
        let source = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "nonexistent.fake.id")
        #expect(source.resolvedAsset == nil)
    }

    @Test func defaultIsActiveIsTrue() {
        let source = SoundSource(type: .whiteNoise, volume: 0.5)
        #expect(source.isActive == true)
    }
}

@MainActor
struct PresetConstraintTests {

    @Test func builtInPresetsRespectMaxSources() {
        for preset in Preset.builtIn {
            #expect(preset.sources.count <= AudioConstants.maxSimultaneousSources,
                    "\(preset.name) has \(preset.sources.count) sources, max is \(AudioConstants.maxSimultaneousSources)")
        }
    }
}

@MainActor
struct TimerStateEdgeCaseTests {

    @Test func syncRemainingNeverGoesNegative() {
        let state = TimerState()
        let start = Date(timeIntervalSince1970: 6_000)

        state.start(duration: 10, now: start)
        // Way past expiry
        let expired = state.syncRemaining(now: start.addingTimeInterval(10_000))

        #expect(expired)
        #expect(state.remainingSeconds >= 0)
    }
}

struct DCBlockingFilterEdgeCaseTests {

    @Test func zeroCutoffDoesNotCrash() {
        let filter = DCBlockingFilter(sampleRate: 44100, cutoffHz: 0)
        let output = filter.process(1.0)
        #expect(output.isFinite)
    }
}

// MARK: - UserSoundLibrary Tests

@MainActor
struct UserSoundLibraryTests {

    @Test func importCreatesRecordAndCopiesFile() throws {
        let env = try TestEnv.make()
        let source = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)

        let asset = try env.library.importSound(
            from: source,
            displayName: "My Tone",
            category: .things
        )

        #expect(asset.displayName == "My Tone")
        #expect(asset.category == .things)
        #expect(asset.durationSeconds >= 1.9 && asset.durationSeconds <= 2.1)
        #expect(asset.fileSizeBytes > 0)
        #expect(env.library.assetsByID[asset.id] != nil)

        let storedURL = env.library.url(for: asset)
        #expect(FileManager.default.fileExists(atPath: storedURL.path))
        #expect(asset.fileName.hasPrefix(asset.id.uuidString))
    }

    @Test func importRejectsTooShortClip() throws {
        let env = try TestEnv.make()
        let source = try env.makeAudioFixture(name: "blip", durationSeconds: 0.3)

        do {
            _ = try env.library.importSound(from: source, displayName: "Blip", category: .things)
            Issue.record("Expected import to throw for short clip")
        } catch let error as UserSoundImportError {
            switch error {
            case .tooShort: break
            default: Issue.record("Wrong error type: \(error)")
            }
        }
    }

    @Test func importRejectsUnreadableFile() throws {
        let env = try TestEnv.make()
        let bogus = env.tempDir.appendingPathComponent("not-audio.mp3")
        try Data("not actually audio".utf8).write(to: bogus)

        do {
            _ = try env.library.importSound(from: bogus, displayName: "Bad", category: .things)
            Issue.record("Expected import to throw for unreadable file")
        } catch let error as UserSoundImportError {
            #expect(error == .unreadable)
        }
    }

    @Test func deleteRemovesFileAndRecord() throws {
        let env = try TestEnv.make()
        let source = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)
        let asset = try env.library.importSound(from: source, displayName: "Doomed", category: .things)
        let id = asset.id
        let storedURL = env.library.url(for: asset)

        env.library.delete(asset)

        #expect(env.library.assetsByID[id] == nil)
        #expect(!FileManager.default.fileExists(atPath: storedURL.path))
    }

    @Test func registryResolvesUserAssetByID() throws {
        let env = try TestEnv.make()
        let source = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)
        let asset = try env.library.importSound(from: source, displayName: "Routable", category: .things)

        // Wire the registry hook the way HushApp.init does.
        SoundAssetRegistry.userLookup = { id in env.library.asset(withID: id) }
        defer { SoundAssetRegistry.userLookup = nil }

        let resolved = SoundAssetRegistry.asset(withID: asset.assetID)
        #expect(resolved != nil)
        #expect(resolved?.displayName == "Routable")
        #expect(resolved?.isUserImported == true)
        #expect(resolved?.resolvedURL != nil)
    }

    @Test func verifyFlagsMissingFiles() throws {
        let env = try TestEnv.make()
        let source = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)
        let asset = try env.library.importSound(from: source, displayName: "Will Disappear", category: .things)

        // Simulate the user nuking the file from the Files app.
        try FileManager.default.removeItem(at: env.library.url(for: asset))

        let missing = env.library.verify()
        #expect(missing.count == 1)
        #expect(missing.first?.id == asset.id)
        #expect(asset.isMissing == true)
    }

    @Test func relinkRebindsExistingRecord() throws {
        let env = try TestEnv.make()
        let original = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)
        let asset = try env.library.importSound(from: original, displayName: "Rebindable", category: .things)
        let originalID = asset.id

        try FileManager.default.removeItem(at: env.library.url(for: asset))
        env.library.verify()
        #expect(asset.isMissing)

        let replacement = try env.makeAudioFixture(name: "replacement", durationSeconds: 3.0)
        try env.library.relink(asset, to: replacement)

        #expect(asset.id == originalID, "ID must stay stable so saved presets keep working")
        #expect(asset.isMissing == false)
        #expect(asset.durationSeconds >= 2.9 && asset.durationSeconds <= 3.1)
        #expect(FileManager.default.fileExists(atPath: env.library.url(for: asset).path))
    }

    @Test func updateMutatesAndPersists() throws {
        let env = try TestEnv.make()
        let source = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)
        let asset = try env.library.importSound(from: source, displayName: "Original", category: .things)

        env.library.update(asset) { rec in
            rec.displayName = "Renamed"
            rec.category = .urban
            rec.crossfadeDurationMs = 300
        }

        #expect(asset.displayName == "Renamed")
        #expect(asset.category == .urban)
        #expect(asset.crossfadeDurationMs == 300)
        // Verify the assetsByID snapshot also reflects the change.
        #expect(env.library.assetsByID[asset.id]?.displayName == "Renamed")
    }

    @Test func totalDiskUsageSumsFileSizes() throws {
        let env = try TestEnv.make()
        let a = try env.makeAudioFixture(name: "a", durationSeconds: 2.0)
        let b = try env.makeAudioFixture(name: "b", durationSeconds: 2.0)
        let one = try env.library.importSound(from: a, displayName: "A", category: .things)
        let two = try env.library.importSound(from: b, displayName: "B", category: .things)

        #expect(env.library.totalDiskUsage == one.fileSizeBytes + two.fileSizeBytes)
    }

    @Test func emptyDisplayNameFallsBackToFilename() throws {
        let env = try TestEnv.make()
        let source = try env.makeAudioFixture(name: "Cool Sound", durationSeconds: 2.0)

        let asset = try env.library.importSound(from: source, displayName: "  ", category: .things)
        #expect(asset.displayName == "Cool Sound")
    }

    @Test func assetIDRoundTrip() {
        let id = UUID()
        let assetID = UserSoundAsset.assetID(for: id)
        #expect(assetID.hasPrefix("user."))
        #expect(UserSoundAsset.uuid(fromAssetID: assetID) == id)
        #expect(UserSoundAsset.uuid(fromAssetID: "moodist.rain.heavy") == nil)
        #expect(UserSoundAsset.uuid(fromAssetID: "user.") == nil)
    }
}

// MARK: - SampleLoopPlayer Tests (user-asset path)

@MainActor
struct SampleLoopPlayerUserAssetTests {

    @Test func loadsUserAssetViaAbsolutePath() throws {
        let env = try TestEnv.make()
        let url = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)
        let asset = SoundAsset(
            id: "user.test",
            displayName: "Test",
            category: .things,
            fileName: url.lastPathComponent,
            fileExtension: "",
            subdirectory: "",
            license: .userImported,
            crossfadeStyle: .stochastic,
            isMono: true,
            absolutePath: url.path
        )

        let player = SampleLoopPlayer()
        player.loadAsset(asset, targetSampleRate: 44100)

        #expect(player.isLoaded)
        #expect(player.loopBuffer != nil)
        #expect(player.assetID == "user.test")
    }

    @Test func loadAssetReturnsEmptyWhenFileMissing() {
        let asset = SoundAsset(
            id: "user.gone",
            displayName: "Gone",
            category: .things,
            fileName: "nope.wav",
            fileExtension: "",
            subdirectory: "",
            license: .userImported,
            crossfadeStyle: .stochastic,
            isMono: true,
            absolutePath: "/tmp/this-file-does-not-exist-\(UUID().uuidString).wav"
        )

        let player = SampleLoopPlayer()
        player.loadAsset(asset, targetSampleRate: 44100)

        #expect(player.isLoaded == false)
        #expect(player.loopBuffer == nil)
    }

    @Test func loadAssetWithZeroCrossfaceReturnsBufferUnchanged() throws {
        let env = try TestEnv.make()
        let url = try env.makeAudioFixture(name: "tone", durationSeconds: 2.0)
        let asset = SoundAsset(
            id: "user.nofade",
            displayName: "No Fade",
            category: .things,
            fileName: url.lastPathComponent,
            fileExtension: "",
            subdirectory: "",
            license: .userImported,
            crossfadeStyle: .stochastic,
            isMono: true,
            absolutePath: url.path,
            crossfadeOverrideMs: 0
        )

        let player = SampleLoopPlayer()
        player.loadAsset(asset, targetSampleRate: 44100)

        #expect(player.isLoaded)
        // With crossfade disabled the loop buffer keeps the full source length
        // (no trim). 2 seconds at 44.1 kHz ≈ 88200 frames; allow slack for
        // sample-rate conversion rounding.
        let frames = Int(player.loopBuffer?.frameLength ?? 0)
        #expect(frames > 87000 && frames < 89000)
    }
}

// MARK: - Helpers

@MainActor
private struct TestEnv {
    let library: UserSoundLibrary
    let tempDir: URL

    static func make() throws -> TestEnv {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hush-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let storage = tempDir.appendingPathComponent("UserSounds", isDirectory: true)
        let schema = Schema([SavedPreset.self, UserSoundAsset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let library = UserSoundLibrary(modelContext: context, storageDirectory: storage)
        return TestEnv(library: library, tempDir: tempDir)
    }

    /// Writes a short sine-wave WAV to the temp dir so import can probe it
    /// with `AVAudioFile`. Avoids bundling fixtures.
    func makeAudioFixture(name: String, durationSeconds: Double) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).wav")
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount
        if let ch = buffer.floatChannelData?[0] {
            let twoPiF = 2 * Float.pi * 440 / Float(sampleRate)
            for i in 0..<Int(frameCount) {
                ch[i] = sinf(twoPiF * Float(i)) * 0.2
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private func rms(_ buffer: UnsafeMutablePointer<Float>, count: Int) -> Float {
    var sum: Float = 0
    for i in 0..<count { sum += buffer[i] * buffer[i] }
    return sqrt(sum / Float(count))
}
