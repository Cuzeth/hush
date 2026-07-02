import AVFoundation
import Synchronization

// Speech-shaped noise generator for masking distracting conversations.
// Uses pink noise as a base, then applies a 2nd-order bandpass emphasis
// centered on the speech-intelligibility band (~500–4000 Hz). The
// "strength" parameter controls how much speech-band emphasis is mixed
// in — at 0 it's flat pink noise, at 1 the speech band dominates.
//
// All state is thread-safe for the real-time render callback.
final class SpeechMaskingGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)
    // Strength 0–100 mapped to 0.0–1.0 (how much speech-band emphasis)
    private let _strength = Atomic<UInt32>(50)

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// 0.0 (flat pink) to 1.0 (full speech-band emphasis)
    nonisolated var strength: Float {
        get { Float(_strength.load(ordering: .relaxed)) / 100.0 }
        // .rounded() so e.g. 0.999 stores as 100, not truncated to 99.
        set { _strength.store(UInt32(max(0, min(100, (newValue * 100).rounded()))), ordering: .relaxed) }
    }

    // Pink noise base (shared Kellet core, same as PinkNoiseGenerator)
    nonisolated(unsafe) private var pinkCore = PinkNoiseCore()
    nonisolated(unsafe) private var rng: AudioRNG
    nonisolated(unsafe) private var ramp = VolumeRamp()

    // Bandpass biquad state (speech band ~500–4000 Hz)
    nonisolated(unsafe) private var bpX1: Float = 0
    nonisolated(unsafe) private var bpX2: Float = 0
    nonisolated(unsafe) private var bpY1: Float = 0
    nonisolated(unsafe) private var bpY2: Float = 0

    // Biquad coefficients (computed once at init for the target sample rate)
    private let bpA0: Float
    private let bpA1: Float
    private let bpA2: Float
    private let bpB0: Float
    private let bpB1: Float
    private let bpB2: Float

    nonisolated init(sampleRate: Double = 44100) {
        self.rng = AudioRNG()

        // Design a 2nd-order bandpass centered at ~1400 Hz (geometric mean
        // of 500 and 4000 Hz) with a fairly wide Q to cover the speech band.
        let centerFreq: Double = 1400.0
        let q: Double = 0.8 // Wide bandwidth
        let w0 = 2.0 * Double.pi * centerFreq / sampleRate
        let alpha = sin(w0) / (2.0 * q)

        // Bandpass (constant 0 dB peak gain) coefficients
        let b0d = alpha
        let b1d = 0.0
        let b2d = -alpha
        let a0d = 1.0 + alpha
        let a1d = -2.0 * cos(w0)
        let a2d = 1.0 - alpha

        // Normalize
        self.bpB0 = Float(b0d / a0d)
        self.bpB1 = Float(b1d / a0d)
        self.bpB2 = Float(b2d / a0d)
        self.bpA0 = 1.0
        self.bpA1 = Float(a1d / a0d)
        self.bpA2 = Float(a2d / a0d)
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let target = Float(bitPattern: _volume.load(ordering: .relaxed))
        var (vol, volStep) = ramp.step(toward: target, frameCount: frameCount)
        let s = Float(_strength.load(ordering: .relaxed)) / 100.0

        for i in 0..<frameCount {
            let pink = pinkCore.process(rng.nextFloat())

            // Bandpass filter for speech-band emphasis
            let filtered = bpB0 * pink + bpB1 * bpX1 + bpB2 * bpX2
                         - bpA1 * bpY1 - bpA2 * bpY2
            bpX2 = bpX1
            bpX1 = pink
            bpY2 = bpY1
            bpY1 = filtered

            // Mix: flat pink + speech-band emphasis (boosted)
            let emphasized = pink * (1.0 - s * 0.4) + filtered * s * 2.5
            buffer[i] = emphasized * vol
            vol += volStep
        }
    }
}
