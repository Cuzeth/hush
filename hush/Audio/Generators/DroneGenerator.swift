import AVFoundation
import Synchronization

// Drone: a warm, shimmering ambient pad built from multiple detuned oscillators
// with slow amplitude modulation. Evokes singing bowls / ambient soundscapes.
//
// Architecture:
//   - 3 fundamental oscillators detuned ±0.3 Hz for natural beating
//   - 2 harmonic oscillators at 3rd and 5th partial, detuned ±0.5 Hz
//   - Slow LFOs (0.02–0.05 Hz) modulate each layer's amplitude
//
// Mono output — same signal to both channels.
final class DroneGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)     // 1.0f
    private let _frequency = Atomic<UInt32>(0x43D8_0000)  // 432.0f

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated var frequency: Float {
        get { Float(bitPattern: _frequency.load(ordering: .relaxed)) }
        set { _frequency.store(newValue.bitPattern, ordering: .relaxed) }
    }

    // Fundamental layer: 3 oscillators
    nonisolated(unsafe) private var fundPhase0: Double = 0
    nonisolated(unsafe) private var fundPhase1: Double = 0
    nonisolated(unsafe) private var fundPhase2: Double = 0

    // Harmonic layer: 3rd and 5th partials
    nonisolated(unsafe) private var harm3Phase0: Double = 0
    nonisolated(unsafe) private var harm3Phase1: Double = 0
    nonisolated(unsafe) private var harm5Phase: Double = 0

    // LFO phases (amplitude modulation)
    nonisolated(unsafe) private var lfoPhase0: Double = 0  // fund layer
    nonisolated(unsafe) private var lfoPhase1: Double = 0  // 3rd harmonic
    nonisolated(unsafe) private var lfoPhase2: Double = 0  // 5th harmonic

    private let sampleRate: Double

    nonisolated init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        let freq = Double(Float(bitPattern: _frequency.load(ordering: .relaxed)))
        let twoPi = 2.0 * Double.pi

        // Fundamental: center ± detune
        let fundInc0 = twoPi * freq / sampleRate
        let fundInc1 = twoPi * (freq - 0.3) / sampleRate
        let fundInc2 = twoPi * (freq + 0.3) / sampleRate

        // 3rd partial: freq * 2.99 and freq * 3.01 (slight split for shimmer)
        let harm3Inc0 = twoPi * (freq * 2.99) / sampleRate
        let harm3Inc1 = twoPi * (freq * 3.01) / sampleRate

        // 5th partial
        let harm5Inc = twoPi * (freq * 5.0) / sampleRate

        // LFO rates
        let lfoInc0 = twoPi * 0.023 / sampleRate
        let lfoInc1 = twoPi * 0.037 / sampleRate
        let lfoInc2 = twoPi * 0.051 / sampleRate

        for i in 0..<frameCount {
            // LFO envelopes: range 0.7–1.0 (gentle swell, never silent)
            let lfo0 = Float(0.85 + 0.15 * cos(lfoPhase0))
            let lfo1 = Float(0.85 + 0.15 * cos(lfoPhase1))
            let lfo2 = Float(0.85 + 0.15 * cos(lfoPhase2))

            // Fundamental layer (3 oscillators averaged)
            let fund = Float(sin(fundPhase0) + sin(fundPhase1) + sin(fundPhase2)) / 3.0 * lfo0

            // 3rd harmonic layer at -12 dB
            let h3 = Float(sin(harm3Phase0) + sin(harm3Phase1)) / 2.0 * 0.25 * lfo1

            // 5th harmonic layer at -18 dB
            let h5 = Float(sin(harm5Phase)) * 0.125 * lfo2

            buffer[i] = (fund + h3 + h5) * vol * 0.75  // headroom normalization

            // Advance phases
            fundPhase0 += fundInc0
            fundPhase1 += fundInc1
            fundPhase2 += fundInc2
            harm3Phase0 += harm3Inc0
            harm3Phase1 += harm3Inc1
            harm5Phase += harm5Inc
            lfoPhase0 += lfoInc0
            lfoPhase1 += lfoInc1
            lfoPhase2 += lfoInc2

            if fundPhase0 >= twoPi { fundPhase0 -= twoPi }
            if fundPhase1 >= twoPi { fundPhase1 -= twoPi }
            if fundPhase2 >= twoPi { fundPhase2 -= twoPi }
            if harm3Phase0 >= twoPi { harm3Phase0 -= twoPi }
            if harm3Phase1 >= twoPi { harm3Phase1 -= twoPi }
            if harm5Phase >= twoPi { harm5Phase -= twoPi }
            if lfoPhase0 >= twoPi { lfoPhase0 -= twoPi }
            if lfoPhase1 >= twoPi { lfoPhase1 -= twoPi }
            if lfoPhase2 >= twoPi { lfoPhase2 -= twoPi }
        }
    }
}
