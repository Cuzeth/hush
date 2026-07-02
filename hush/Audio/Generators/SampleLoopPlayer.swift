@preconcurrency import AVFoundation
import os.log

// Loads bundled audio samples and pre-bakes a seamless crossfade loop buffer
// at load time. Designed for use with AVAudioPlayerNode.scheduleBuffer(.loops) —
// no sample-level work happens in any real-time render callback.
final class SampleLoopPlayer: @unchecked Sendable {
    nonisolated private static let logger = Logger(subsystem: "dev.abdeen.hush", category: "SampleLoopPlayer")
    /// Settable so the engine can attach a cached buffer on the cache-hit
    /// path — the player is then the strong reference that survives NSCache
    /// eviction. (Playback volume lives on the AVAudioPlayerNode, not here.)
    nonisolated(unsafe) var loopBuffer: AVAudioPCMBuffer?
    nonisolated(unsafe) private(set) var isLoaded = false

    /// The asset this player was loaded from (nil for legacy loads)
    nonisolated(unsafe) private(set) var assetID: String?

    nonisolated init() {}

    nonisolated init(fileName: String? = nil, sampleRate: Double = 44100) {
        if let fileName {
            loadSample(named: fileName, targetSampleRate: sampleRate)
        }
    }

    // MARK: - Loading from SoundAsset

    nonisolated func loadAsset(_ asset: SoundAsset, targetSampleRate: Double) {
        guard !isLoaded else { return }
        assetID = asset.id

        guard let url = asset.resolvedURL else {
            // For user assets this means the file was deleted out from under us
            // (Files app, restore from a partial backup). For bundled assets it
            // would only happen on a corrupt build.
            Self.logger.error("Failed to resolve URL for asset: \(asset.id)")
            isLoaded = false
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

            // File metadata is untrusted (user imports arrive via the Files
            // picker, and files are re-read from disk on every playback):
            // validate before any trapping conversion or large allocation.
            let sourceFormat = file.processingFormat
            guard file.length > 0,
                  sourceFormat.sampleRate > 0,
                  sourceFormat.channelCount > 0,
                  let sourceFrameCount = AVAudioFrameCount(exactly: file.length) else {
                Self.logger.error("Rejected sample with invalid metadata: \(fileURL.lastPathComponent)")
                isLoaded = false
                return
            }

            // Bound decode memory: the import-time duration cap doesn't limit
            // bytes when the header declares an extreme sample rate.
            let ratio = targetSampleRate / sourceFormat.sampleRate
            let estimatedBytes = Double(sourceFrameCount) * Double(sourceFormat.channelCount) * 4
                + Double(sourceFrameCount) * ratio * 2 * 4
            guard estimatedBytes.isFinite, estimatedBytes <= AudioConstants.maxDecodedSampleBytes else {
                Self.logger.error("Rejected sample exceeding decode budget: \(fileURL.lastPathComponent)")
                isLoaded = false
                return
            }

            // Read the source file into its native processing format
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

                // Headroom past the exact ratio so the resampler's flushed
                // tail (filter delay) fits in one conversion pass.
                let outputFrames = (Double(sourceFrameCount) * ratio).rounded(.up) + 64
                guard let outputFrameCount = AVAudioFrameCount(exactly: outputFrames),
                      let outputBuffer = AVAudioPCMBuffer(
                          pcmFormat: targetFormat,
                          frameCapacity: outputFrameCount
                      ) else { return }

                var error: NSError?
                let srcBuf = sourceBuffer
                var isDone = false
                // .endOfStream (not .noDataNow) after the single input buffer:
                // it tells the converter to flush its internal filter delay.
                // .noDataNow ("more later") dropped the last few milliseconds,
                // so the pre-baked crossfade blended the head against the
                // wrong tail — an audible thump at every loop seam for any
                // asset whose native rate differs from the hardware's.
                let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if isDone {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    isDone = true
                    return srcBuf
                }
                if error != nil || status == .error { return }
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
                Self.logger.info("Loaded sample: \(name) (\(String(format: "%.1f", dur))s, crossfade: \(Int(crossfadeDurationMs))ms)")
            }
        } catch {
            Self.logger.error("Failed to load sample from \(fileURL.lastPathComponent): \(error.localizedDescription)")
            isLoaded = false
        }
    }

    // MARK: - Pre-baked Crossfade

    private nonisolated func prebakeCrossfade(
        from source: AVAudioPCMBuffer,
        crossfadeSamples C: Int
    ) -> AVAudioPCMBuffer? {
        // Caller opted out of crossfading (e.g. user import with the toggle
        // off). Return the converted buffer unchanged — loops will click at
        // the seam but playback is otherwise faithful to the source.
        if C <= 0 { return source }

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
