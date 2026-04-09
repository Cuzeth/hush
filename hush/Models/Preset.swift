import Foundation
import SwiftData

struct Preset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var icon: String
    var sources: [SoundSource]
    var isBuiltIn: Bool

    static let builtIn: [Preset] = [
        Preset(
            name: "Focus",
            icon: "brain.head.profile",
            sources: [
                SoundSource(type: .brownNoise, volume: 0.6),
                SoundSource(type: .rain, volume: 0.4)
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Deep Work",
            icon: "bolt.fill",
            sources: [
                SoundSource(type: .pinkNoise, volume: 0.5),
                SoundSource(type: .binauralBeats, volume: 0.3,
                            binauralRange: .beta, binauralFrequency: 20)
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Sleep",
            icon: "moon.fill",
            sources: [
                SoundSource(type: .brownNoise, volume: 0.35),
                SoundSource(type: .ocean, volume: 0.3)
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Calm",
            icon: "leaf.fill",
            sources: [
                SoundSource(type: .pinkNoise, volume: 0.3),
                SoundSource(type: .birdsong, volume: 0.4)
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Storm",
            icon: "cloud.bolt.rain.fill",
            sources: [
                SoundSource(type: .rain, volume: 0.6),
                SoundSource(type: .thunder, volume: 0.4),
                SoundSource(type: .wind, volume: 0.35)
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Gamma Focus",
            icon: "bolt.trianglebadge.exclamationmark.fill",
            sources: [
                SoundSource(type: .isochronicTones, volume: 0.35,
                            binauralRange: .gamma, binauralFrequency: 40),
                SoundSource(type: .brownNoise, volume: 0.5)
            ],
            isBuiltIn: true
        ),
        // New presets using expanded sound library
        Preset(
            name: "Coffee Shop",
            icon: "cup.and.saucer.fill",
            sources: [
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.places.cafe")!, volume: 1.0),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.things.keyboard")!, volume: 0.8),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.rain.light")!, volume: 0.85),
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Rainy Day",
            icon: "cloud.rain.fill",
            sources: [
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.rain.light")!, volume: 1.0),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.rain.thunder")!, volume: 0.75),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.nature.wind")!, volume: 0.7),
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Forest",
            icon: "tree.fill",
            sources: [
                SoundSource(asset: SoundAssetRegistry.asset(withID: "sample.birds.morning")!, volume: 1.0),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.nature.river")!, volume: 0.85),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.nature.wind-trees")!, volume: 0.75),
            ],
            isBuiltIn: true
        ),
        Preset(
            name: "Cozy",
            icon: "fireplace.fill",
            sources: [
                SoundSource(asset: SoundAssetRegistry.asset(withID: "sample.fire.crackling")!, volume: 1.0),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.rain.window")!, volume: 0.85),
                SoundSource(asset: SoundAssetRegistry.asset(withID: "moodist.things.clock")!, volume: 0.6),
            ],
            isBuiltIn: true
        ),
    ]
}

// SwiftData model for user-saved presets
@Model
final class SavedPreset {
    var stableID: UUID
    var name: String
    var icon: String
    var sourcesData: Data
    var createdAt: Date

    init(name: String, icon: String, sources: [SoundSource]) {
        self.stableID = UUID()
        self.name = name
        self.icon = icon
        self.sourcesData = (try? JSONEncoder().encode(sources)) ?? Data()
        self.createdAt = Date()
    }

    @Transient private var _cachedSources: [SoundSource]?
    @Transient private var _cachedSourcesData: Data?

    var sources: [SoundSource] {
        get {
            if _cachedSourcesData == sourcesData, let cached = _cachedSources {
                return cached
            }
            let decoded = (try? JSONDecoder().decode([SoundSource].self, from: sourcesData)) ?? []
            _cachedSources = decoded
            _cachedSourcesData = sourcesData
            return decoded
        }
        set {
            sourcesData = (try? JSONEncoder().encode(newValue)) ?? Data()
            _cachedSources = newValue
            _cachedSourcesData = sourcesData
        }
    }

    func toPreset() -> Preset {
        Preset(id: stableID, name: name, icon: icon, sources: sources, isBuiltIn: false)
    }
}
