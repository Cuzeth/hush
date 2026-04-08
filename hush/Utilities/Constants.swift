import Foundation

enum AudioConstants {
    static let sampleRate: Double = 44100.0
    static let defaultFadeDuration: TimeInterval = 0.5
    static let timerFadeOutDuration: TimeInterval = 10.0
    static let maxSimultaneousSources = 6
    static let crossfadeDurationMs: Double = 100.0
    static var crossfadeSamples: Int { Int(sampleRate * crossfadeDurationMs / 1000.0) }
}

enum BinauralRange: String, CaseIterable, Identifiable {
    case alpha = "Alpha"
    case smr = "SMR"
    case beta = "Beta"
    case gamma = "Gamma"

    var id: String { rawValue }

    var frequencyRange: ClosedRange<Float> {
        switch self {
        case .alpha: return 8...13
        case .smr: return 12...15
        case .beta: return 13...30
        case .gamma: return 40...40
        }
    }

    var defaultFrequency: Float {
        switch self {
        case .alpha: return 10
        case .smr: return 13
        case .beta: return 20
        case .gamma: return 40
        }
    }

    var description: String {
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
    case rain = "Rain"
    case ocean = "Ocean"
    case thunder = "Thunder"
    case fire = "Fire"
    case birdsong = "Birdsong"
    case wind = "Wind"
    case stream = "Stream"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .whiteNoise: return "waveform"
        case .pinkNoise: return "waveform.path"
        case .brownNoise: return "water.waves"
        case .grayNoise: return "circle.hexagongrid"
        case .binauralBeats: return "headphones"
        case .rain: return "cloud.rain"
        case .ocean: return "tropicalstorm"
        case .thunder: return "cloud.bolt"
        case .fire: return "flame"
        case .birdsong: return "bird"
        case .wind: return "wind"
        case .stream: return "drop.triangle"
        }
    }

    var isGenerated: Bool {
        switch self {
        case .whiteNoise, .pinkNoise, .brownNoise, .grayNoise, .binauralBeats:
            return true
        default:
            return false
        }
    }

    var sampleFileName: String? {
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

enum TimerDuration: Int, CaseIterable, Identifiable {
    case fifteen = 15
    case twentyFive = 25
    case thirty = 30
    case fortyFive = 45
    case sixty = 60
    case ninety = 90

    var id: Int { rawValue }

    var label: String {
        "\(rawValue) min"
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue) * 60
    }
}
