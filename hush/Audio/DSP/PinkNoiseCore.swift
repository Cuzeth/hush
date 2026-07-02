// Paul Kellet's pink-noise IIR — accurate to ±0.05 dB above 9.2 Hz at 44.1 kHz.
// Seven parallel first-order lowpass filters with tuned coefficients, summed to
// approximate a -3 dB/octave slope. Shared by PinkNoiseGenerator and
// SpeechMaskingGenerator so the coefficients live in exactly one place.
//
// NOTE: Coefficients are designed for 44.1 kHz. At 48 kHz (standard iPhone
// rate) the error is negligible (<0.5 dB); acceptable for target hardware.
//
// Value type mutated only on the audio thread — no locks, no allocation.
// All members are nonisolated (same pattern as AudioRNG): used exclusively
// inside @unchecked Sendable generator classes on the render thread.
struct PinkNoiseCore: @unchecked Sendable {
    nonisolated(unsafe) private var b0: Float = 0
    nonisolated(unsafe) private var b1: Float = 0
    nonisolated(unsafe) private var b2: Float = 0
    nonisolated(unsafe) private var b3: Float = 0
    nonisolated(unsafe) private var b4: Float = 0
    nonisolated(unsafe) private var b5: Float = 0
    nonisolated(unsafe) private var b6: Float = 0

    nonisolated init() {}

    /// Feeds one white-noise sample, returns one pink sample scaled to
    /// roughly ±1 (the raw Kellet sum peaks near ±9; 0.11 normalizes).
    nonisolated mutating func process(_ white: Float) -> Float {
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
        b6 = white * 0.115926
        return pink
    }
}
