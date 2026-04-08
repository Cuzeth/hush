import AVFoundation
import Synchronization

// Brown (Brownian) noise via leaky integrator with DC blocking filter.
// Leaky integrator: output = (lastOutput + 0.02 * white) / 1.02
// Prevents DC drift while maintaining -6 dB/octave slope.
final class BrownNoiseGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var lastOutput: Float = 0
    nonisolated(unsafe) private var dcBlocker = DCBlockingFilter()
    nonisolated(unsafe) private var rng: AudioRNG

    nonisolated init(sampleRate: Double = 44100) {
        self.rng = AudioRNG()
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        for i in 0..<frameCount {
            let white = rng.nextFloat()
            lastOutput = (lastOutput + 0.02 * white) / 1.02
            let filtered = dcBlocker.process(lastOutput)
            buffer[i] = filtered * 3.5 * vol
        }
    }
}
