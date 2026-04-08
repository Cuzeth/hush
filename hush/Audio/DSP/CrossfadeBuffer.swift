import Foundation

// Manages seamless looping of a sample buffer with equal-power crossfade
// at loop boundaries (100ms by default).
final class CrossfadeBuffer: @unchecked Sendable {
    private let samples: [Float]
    private let channelCount: Int
    private let crossfadeSamples: Int
    private var position: Int = 0

    nonisolated init(samples: [Float], channelCount: Int, crossfadeSamples: Int = AudioConstants.crossfadeSamples) {
        self.samples = samples
        self.channelCount = max(1, channelCount)
        self.crossfadeSamples = crossfadeSamples
    }

    nonisolated var totalFrames: Int {
        guard channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }

    nonisolated func read(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        let total = totalFrames
        guard total > crossfadeSamples * 2, channel < channelCount else {
            // Not enough samples or invalid channel — fill silence
            for i in 0..<frameCount {
                buffer[i] = 0
            }
            return
        }

        let fadeStart = total - crossfadeSamples

        for i in 0..<frameCount {
            let pos = (position + i) % total
            let idx = pos * channelCount + channel
            var sample = samples[idx]

            // Apply crossfade near the loop boundary
            if pos >= fadeStart {
                let fadePos = pos - fadeStart
                let t = Float(fadePos) / Float(crossfadeSamples)
                // Equal-power crossfade: cos/sin
                let gainOut = cosf(t * .pi / 2)
                let gainIn = sinf(t * .pi / 2)

                let loopIdx = fadePos * channelCount + channel
                let loopSample = samples[loopIdx]
                sample = sample * gainOut + loopSample * gainIn
            }

            buffer[i] = sample
        }

        position = (position + frameCount) % total
    }

    nonisolated func reset() {
        position = 0
    }
}
