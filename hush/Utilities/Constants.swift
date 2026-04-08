import Foundation

enum AudioConstants {
    nonisolated static let sampleRate: Double = 44100.0
    nonisolated static let defaultFadeDuration: TimeInterval = 0.5
    nonisolated static let defaultBinauralCarrier: Float = 200
    nonisolated static let timerFadeOutDuration: TimeInterval = 10.0
    nonisolated static let maxSimultaneousSources = 6
    nonisolated static let crossfadeDurationMs: Double = 100.0
    nonisolated static let preferredIOBufferFrameCount: Double = 2048.0
}

enum BinauralRange: String, CaseIterable, Identifiable, Codable {
    case alpha = "Alpha"
    case smr = "SMR"
    case beta = "Beta"
    case gamma = "Gamma"

    nonisolated var id: String { rawValue }

    nonisolated var frequencyRange: ClosedRange<Float> {
        switch self {
        case .alpha: return 8...13
        case .smr: return 12...15
        case .beta: return 13...30
        case .gamma: return 40...40
        }
    }

    nonisolated var defaultFrequency: Float {
        switch self {
        case .alpha: return 10
        case .smr: return 13
        case .beta: return 20
        case .gamma: return 40
        }
    }

    nonisolated var description: String {
        switch self {
        case .alpha: return "Calm Focus (8-13 Hz)"
        case .smr: return "ADHD Sweet Spot (12-15 Hz)"
        case .beta: return "Alertness (13-30 Hz)"
        case .gamma: return "Peak Cognition (40 Hz)"
        }
    }
}

enum SoundType: String, Codable, CaseIterable, Identifiable {
    case whiteNoise = "White Noise"
    case pinkNoise = "Pink Noise"
    case brownNoise = "Brown Noise"
    case grayNoise = "Gray Noise"
    case binauralBeats = "Binaural Beats"
    case isochronicTones = "Isochronic Tones"
    case monauralBeats = "Monaural Beats"
    case pureTone = "Pure Tone"
    case drone = "Drone"
    case rain = "Rain"
    case ocean = "Ocean"
    case thunder = "Thunder"
    case fire = "Fire"
    case birdsong = "Birdsong"
    case wind = "Wind"
    case stream = "Stream"

    nonisolated var id: String { rawValue }

    nonisolated var icon: String {
        switch self {
        case .whiteNoise: return "waveform"
        case .pinkNoise: return "waveform.path"
        case .brownNoise: return "water.waves"
        case .grayNoise: return "circle.hexagongrid"
        case .binauralBeats: return "headphones"
        case .isochronicTones: return "metronome.fill"
        case .monauralBeats: return "speaker.wave.2"
        case .pureTone: return "tuningfork"
        case .drone: return "waveform.circle"
        case .rain: return "cloud.rain"
        case .ocean: return "tropicalstorm"
        case .thunder: return "cloud.bolt"
        case .fire: return "flame"
        case .birdsong: return "bird"
        case .wind: return "wind"
        case .stream: return "drop.triangle"
        }
    }

    nonisolated var isGenerated: Bool {
        switch self {
        case .whiteNoise, .pinkNoise, .brownNoise, .grayNoise,
             .binauralBeats, .isochronicTones, .monauralBeats,
             .pureTone, .drone:
            return true
        default:
            return false
        }
    }

    nonisolated var sampleFileName: String? {
        switch self {
        case .rain: return "rain"
        case .ocean: return "ocean"
        case .thunder: return "thunder"
        case .fire: return "fire"
        case .birdsong: return "birdsong"
        case .wind: return "wind"
        case .stream: return "stream"
        default: return nil
        }
    }
}

enum TonePreset: String, CaseIterable, Identifiable, Codable {
    case hz174 = "174 Hz"
    case hz285 = "285 Hz"
    case hz396 = "396 Hz"
    case hz432 = "432 Hz"
    case hz528 = "528 Hz"
    case hz639 = "639 Hz"
    case hz741 = "741 Hz"
    case hz852 = "852 Hz"

    nonisolated var id: String { rawValue }

    nonisolated var frequency: Float {
        switch self {
        case .hz174: return 174
        case .hz285: return 285
        case .hz396: return 396
        case .hz432: return 432
        case .hz528: return 528
        case .hz639: return 639
        case .hz741: return 741
        case .hz852: return 852
        }
    }

    nonisolated var label: String { rawValue }
}

enum TimerDuration: Int, CaseIterable, Identifiable {
    case fifteen = 15
    case twentyFive = 25
    case thirty = 30
    case fortyFive = 45
    case sixty = 60
    case ninety = 90

    nonisolated var id: Int { rawValue }

    nonisolated var label: String {
        "\(rawValue) min"
    }

    nonisolated var seconds: TimeInterval {
        TimeInterval(rawValue) * 60
    }
}
