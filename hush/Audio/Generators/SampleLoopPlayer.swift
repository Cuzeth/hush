@preconcurrency import AVFoundation
import Synchronization

// Loads bundled CC0 audio samples and pre-bakes a seamless crossfade loop buffer
// at load time. Designed for use with AVAudioPlayerNode.scheduleBuffer(.loops) —
// no sample-level work happens in any real-time render callback.
final class SampleLoopPlayer: @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000) // 1.0f
    nonisolated(unsafe) private(set) var loopBuffer: AVAudioPCMBuffer?
    nonisolated(unsafe) private(set) var isLoaded = false

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated init(fileName: String? = nil, sampleRate: Double = 44100) {
        if let fileName {
            loadSample(named: fileName, targetSampleRate: sampleRate)
        }
    }

    // MARK: - Loading

    nonisolated func loadSample(named name: String, targetSampleRate: Double) {
        let extensions = ["m4a", "wav", "mp3", "aif", "aiff"]
        var url: URL?
        for ext in extensions {
            if let found = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Samples") {
                url = found
                break
            }
            if let found = Bundle.main.url(forResource: name, withExtension: ext) {
                url = found
                break
            }
        }

        guard let fileURL = url else {
            isLoaded = false
            return
        }

        do {
            let file = try AVAudioFile(forReading: fileURL)

            // Target format: stereo float32 at the engine's actual sample rate
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 2,
                interleaved: false
            ) else { return }

            // Read the source file into its native processing format
            let sourceFormat = file.processingFormat
            let sourceFrameCount = AVAudioFrameCount(file.length)
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: sourceFrameCount
            ) else { return }
            try file.read(into: sourceBuffer)

            // Convert to target format if needed
            let convertedBuffer: AVAudioPCMBuffer
            if sourceFormat.sampleRate != targetSampleRate || sourceFormat.channelCount != 2 {
                guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return }
                let ratio = targetSampleRate / sourceFormat.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(sourceFrameCount) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputFrameCount
                ) else { return }

                var error: NSError?
                let srcBuf = sourceBuffer
                var isDone = false
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if isDone {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    outStatus.pointee = .haveData
                    isDone = true
                    return srcBuf
                }
                if error != nil { return }
                convertedBuffer = outputBuffer
            } else {
                convertedBuffer = sourceBuffer
            }

            // Pre-bake the crossfade into the buffer
            loopBuffer = prebakeCrossfade(
                from: convertedBuffer,
                crossfadeSamples: Int(targetSampleRate * 0.1) // 100ms
            )
            isLoaded = loopBuffer != nil
        } catch {
            isLoaded = false
        }
    }

    // MARK: - Pre-baked Crossfade

    // Creates a loop-ready buffer where the tail of the original audio is
    // crossfaded into the head, so AVAudioPlayerNode.scheduleBuffer(.loops)
    // produces a seamless transition at the loop point.
    //
    // Given N source frames and C crossfade frames, the output has (N - C) frames:
    //   frames [0, C):          blend of original head (fading in) + original tail (fading out)
    //   frames [C, N - C):      verbatim original audio
    //
    // When the player loops from frame (N-C-1) back to frame 0, the crossfade
    // region ensures continuity: frame 0 starts with the tail content fully present,
    // smoothly transitioning into the head content.
    private nonisolated func prebakeCrossfade(
        from source: AVAudioPCMBuffer,
        crossfadeSamples C: Int
    ) -> AVAudioPCMBuffer? {
        let N = Int(source.frameLength)
        let channels = Int(source.format.channelCount)
        guard N > C * 2 else { return source }

        let loopLength = N - C
        guard let loopBuffer = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: AVAudioFrameCount(loopLength)
        ) else { return nil }
        loopBuffer.frameLength = AVAudioFrameCount(loopLength)

        guard let srcData = source.floatChannelData,
              let dstData = loopBuffer.floatChannelData else { return nil }

        for ch in 0..<channels {
            let src = srcData[ch]
            let dst = dstData[ch]
            let piOver2 = Float.pi / 2.0
            let invC = 1.0 / Float(C)

            for i in 0..<loopLength {
                if i < C {
                    let t = Float(i) * invC
                    let fadeIn = sinf(t * piOver2)
                    let fadeOut = cosf(t * piOver2)
                    dst[i] = src[i] * fadeIn + src[loopLength + i] * fadeOut
                } else {
                    dst[i] = src[i]
                }
            }
        }

        return loopBuffer
    }
}
