import AVFoundation

// Binaural beats: two sine oscillators at slightly different frequencies,
// one per stereo channel. Headphones required — no channel crosstalk allowed.
// Carrier: 200-400 Hz. Difference frequency determines brainwave target.
final class BinauralBeatGenerator: SoundGenerator, @unchecked Sendable {
    nonisolated(unsafe) var volume: Float = 1.0
    nonisolated(unsafe) var carrierFrequency: Float = 200.0
    nonisolated(unsafe) var beatFrequency: Float = 13.0 // SMR default

    private var phaseLeft: Double = 0
    private var phaseRight: Double = 0
    private let sampleRate = AudioConstants.sampleRate

    nonisolated func setRange(_ range: BinauralRange) {
        beatFrequency = range.defaultFrequency
    }

    nonisolated func generateSamples(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, stereo: Bool) {
        let vol = volume
        let carrier = Double(carrierFrequency)
        let beat = Double(beatFrequency)
        let leftFreq = carrier
        let rightFreq = carrier + beat
        let twoPi = 2.0 * Double.pi

        let phaseIncrementLeft = twoPi * leftFreq / sampleRate
        let phaseIncrementRight = twoPi * rightFreq / sampleRate

        if stereo {
            for i in 0..<frameCount {
                let leftSample = Float(sin(phaseLeft)) * vol
                let rightSample = Float(sin(phaseRight)) * vol
                buffer[i * 2] = leftSample
                buffer[i * 2 + 1] = rightSample

                phaseLeft += phaseIncrementLeft
                phaseRight += phaseIncrementRight

                // Keep phase in [0, 2π) to prevent floating-point precision loss
                if phaseLeft >= twoPi { phaseLeft -= twoPi }
                if phaseRight >= twoPi { phaseRight -= twoPi }
            }
        } else {
            // Mono fallback: just the carrier (binaural effect requires stereo)
            for i in 0..<frameCount {
                buffer[i] = Float(sin(phaseLeft)) * vol
                phaseLeft += phaseIncrementLeft
                if phaseLeft >= twoPi { phaseLeft -= twoPi }
            }
        }
    }

    nonisolated func reset() {
        phaseLeft = 0
        phaseRight = 0
    }
}
