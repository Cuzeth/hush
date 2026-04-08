import Foundation

// Real-time safe PRNG using xorshift32.
// No syscalls, no locks, no heap allocation — safe for audio render callbacks.
// Seeded at init time (off audio thread) via arc4random().
//
// All members are nonisolated — this struct is used exclusively on the audio
// render thread, stored inside @unchecked Sendable generator classes.
struct AudioRNG: @unchecked Sendable {
    nonisolated(unsafe) private var state: UInt32

    nonisolated init(seed: UInt32 = 0) {
        self.state = seed != 0 ? seed : (arc4random() | 1)
    }

    // Advance state and return raw UInt32.
    nonisolated mutating func next() -> UInt32 {
        state ^= state &<< 13
        state ^= state &>> 17
        state ^= state &<< 5
        return state
    }

    // Returns Float in [-1.0, 1.0).
    // Uses upper 24 bits mapped to [0, 2.0) then shifted.
    nonisolated mutating func nextFloat() -> Float {
        let bits = next()
        return Float(bits >> 8) * (1.0 / 8388608.0) - 1.0  // 2^23
    }
}
