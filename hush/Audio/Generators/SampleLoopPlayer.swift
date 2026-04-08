import AVFoundation

// Plays bundled CC0 audio samples with seamless crossfade looping.
// Uses CrossfadeBuffer for equal-power crossfade at loop boundaries.
final class SampleLoopPlayer: SoundGenerator, @unchecked Sendable {
    nonisolated(unsafe) var volume: Float = 1.0

    private var crossfadeBuffer: CrossfadeBuffer?
    private var channelCount: Int = 1
    private var isLoaded = false

    nonisolated init(fileName: String? = nil) {
        if let fileName {
            loadSample(named: fileName)
        }
    }

    nonisolated func loadSample(named name: String) {
        // Try common audio extensions
        let extensions = ["m4a", "wav", "mp3", "aif", "aiff"]
        var url: URL?
        for ext in extensions {
            if let found = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Samples") {
                url = found
                break
            }
            // Also try without subdirectory
            if let found = Bundle.main.url(forResource: name, withExtension: ext) {
                url = found
                break
            }
        }

        guard let fileURL = url else {
            // No sample file found — will output silence
            isLoaded = false
            return
        }

        do {
            let file = try AVAudioFile(forReading: fileURL)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            try file.read(into: pcmBuffer)

            channelCount = Int(format.channelCount)
            let totalSamples = Int(pcmBuffer.frameLength) * channelCount

            // Copy to a plain Float array for the crossfade buffer
            guard let channelData = pcmBuffer.floatChannelData else { return }
            var samples = [Float](repeating: 0, count: totalSamples)
            let frames = Int(pcmBuffer.frameLength)

            if channelCount == 1 {
                for i in 0..<frames {
                    samples[i] = channelData[0][i]
                }
            } else {
                // Interleave channels
                for i in 0..<frames {
                    for ch in 0..<channelCount {
                        samples[i * channelCount + ch] = channelData[ch][i]
                    }
                }
            }

            crossfadeBuffer = CrossfadeBuffer(samples: samples, channelCount: channelCount)
            isLoaded = true
        } catch {
            isLoaded = false
        }
    }

    nonisolated func generateSamples(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, stereo: Bool) {
        guard isLoaded, let cb = crossfadeBuffer else {
            // No sample loaded — fill with silence
            let count = stereo ? frameCount * 2 : frameCount
            for i in 0..<count { buffer[i] = 0 }
            return
        }

        let vol = volume

        if stereo {
            if channelCount >= 2 {
                // Source is stereo — read each channel
                var tempL = [Float](repeating: 0, count: frameCount)
                var tempR = [Float](repeating: 0, count: frameCount)
                cb.read(into: &tempL, frameCount: frameCount, channel: 0)
                cb.read(into: &tempR, frameCount: frameCount, channel: 1)
                for i in 0..<frameCount {
                    buffer[i * 2] = tempL[i] * vol
                    buffer[i * 2 + 1] = tempR[i] * vol
                }
            } else {
                // Source is mono — duplicate to both channels
                var temp = [Float](repeating: 0, count: frameCount)
                cb.read(into: &temp, frameCount: frameCount, channel: 0)
                for i in 0..<frameCount {
                    let s = temp[i] * vol
                    buffer[i * 2] = s
                    buffer[i * 2 + 1] = s
                }
            }
        } else {
            var temp = [Float](repeating: 0, count: frameCount)
            cb.read(into: &temp, frameCount: frameCount, channel: 0)
            for i in 0..<frameCount {
                buffer[i] = temp[i] * vol
            }
        }
    }

    nonisolated func reset() {
        crossfadeBuffer?.reset()
    }
}
