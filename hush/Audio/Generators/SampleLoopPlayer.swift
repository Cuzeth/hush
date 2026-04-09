@preconcurrency import AVFoundation
import Synchronization

// Loads bundled audio samples and pre-bakes a seamless crossfade loop buffer
// at load time. Designed for use with AVAudioPlayerNode.scheduleBuffer(.loops) —
// no sample-level work happens in any real-time render callback.
final class SampleLoopPlayer: @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000) // 1.0f
    nonisolated(unsafe) private(set) var loopBuffer: AVAudioPCMBuffer?
    nonisolated(unsafe) private(set) var isLoaded = false

    /// The asset this player was loaded from (nil for legacy loads)
    nonisolated(unsafe) private(set) var assetID: String?

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated init() {}

    nonisolated init(fileName: String? = nil, sampleRate: Double = 44100) {
        if let fileName {
            loadSample(named: fileName, targetSampleRate: sampleRate)
        }
    }

    // MARK: - Loading from SoundAsset

    nonisolated func loadAsset(_ asset: SoundAsset, targetSampleRate: Double) {
        assetID = asset.id

        // Search for the file in the bundle subdirectory
        guard let url = Bundle.main.url(
            forResource: asset.fileName,
            withExtension: asset.fileExtension,
            subdirectory: asset.subdirectory
        ) else {
            // Fallback: search without subdirectory
            guard let fallbackURL = Bundle.main.url(
                forResource: asset.fileName,
                withExtension: asset.fileExtension
            ) else {
                print("[Hush] Failed to find audio file: \(asset.subdirectory)/\(asset.fileName).\(asset.fileExtension)")
                isLoaded = false
                return
            }
            loadFromURL(fallbackURL, targetSampleRate: targetSampleRate, crossfadeDurationMs: asset.crossfadeDurationMs)
            return
        }

        loadFromURL(url, targetSampleRate: targetSampleRate, crossfadeDurationMs: asset.crossfadeDurationMs)
    }

    // MARK: - Loading (legacy — by name)

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

        loadFromURL(fileURL, targetSampleRate: targetSampleRate, crossfadeDurationMs: AudioConstants.crossfadeDurationMs)
    }

    // MARK: - Core Loading

    private nonisolated func loadFromURL(_ fileURL: URL, targetSampleRate: Double, crossfadeDurationMs: Double) {
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

            // Convert to target format if needed (sample rate, channel count, or bit depth)
            let convertedBuffer: AVAudioPCMBuffer
            if sourceFormat.sampleRate != targetSampleRate ||
               sourceFormat.channelCount != 2 ||
               sourceFormat.commonFormat != .pcmFormatFloat32 {
                guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return }

                // Enable high-quality sample rate conversion
                converter.sampleRateConverterQuality = .max

                let ratio = targetSampleRate / sourceFormat.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(sourceFrameCount) * ratio) + 1
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
            let crossfadeSamples = Int(targetSampleRate * (crossfadeDurationMs / 1000.0))
            loopBuffer = prebakeCrossfade(
                from: convertedBuffer,
                crossfadeSamples: crossfadeSamples
            )
            isLoaded = loopBuffer != nil

            if isLoaded {
                let name = fileURL.lastPathComponent
                let frames = loopBuffer?.frameLength ?? 0
                let dur = Double(frames) / targetSampleRate
                print("[Hush] Loaded sample: \(name) (\(String(format: "%.1f", dur))s, crossfade: \(Int(crossfadeDurationMs))ms)")
            }
        } catch {
            print("[Hush] Failed to load sample from \(fileURL.lastPathComponent): \(error)")
            isLoaded = false
        }
    }

    // MARK: - Pre-baked Crossfade

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
