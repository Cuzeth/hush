import AVFoundation
import Synchronization

// Pink noise via the shared Kellet IIR core (see PinkNoiseCore for the
// coefficient provenance and sample-rate caveats). The sampleRate init
// parameter is accepted for API consistency with other generators but
// unused — the coefficients are valid for standard iOS hardware rates.
final class PinkNoiseGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var core = PinkNoiseCore()
    nonisolated(unsafe) private var rng: AudioRNG
    nonisolated(unsafe) private var ramp = VolumeRamp()

    nonisolated init(sampleRate: Double = 44100) {
        self.rng = AudioRNG()
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let target = Float(bitPattern: _volume.load(ordering: .relaxed))
        var (vol, volStep) = ramp.step(toward: target, frameCount: frameCount)
        for i in 0..<frameCount {
            buffer[i] = core.process(rng.nextFloat()) * vol
            vol += volStep
        }
    }
}
