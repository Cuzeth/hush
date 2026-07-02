import Foundation
import SwiftData
import os.log

private let presetLogger = Logger(subsystem: "dev.abdeen.hush", category: "Preset")

struct Preset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var icon: String
    var sources: [SoundSource]
    var isBuiltIn: Bool

    private static func makeSource(_ assetID: String, volume: Float) -> SoundSource? {
        guard let asset = SoundAssetRegistry.asset(withID: assetID) else {
            assertionFailure("Missing required asset: \(assetID)")
            return nil
        }
        return SoundSource(asset: asset, volume: volume)
    }

    /// Built-in presets need hardcoded IDs: hide/rename/edit persistence keys
    /// on these UUIDs across launches, and `var id = UUID()` alone would mint
    /// fresh ones every launch (deleted presets resurrected, renames lost,
    /// edited built-ins duplicated).
    private static func stableID(_ uuidString: String) -> UUID {
        guard let id = UUID(uuidString: uuidString) else {
            preconditionFailure("Invalid built-in preset UUID: \(uuidString)")
        }
        return id
    }

    static let builtIn: [Preset] = [
        Preset(
            id: stableID("9689D977-9B4E-4012-9265-6E83CAB21596"),
            name: "Focus",
            icon: "brain.head.profile",
            sources: [
                SoundSource(type: .brownNoise, volume: 0.6),
                SoundSource(type: .rain, volume: 0.4)
            ],
            isBuiltIn: true
        ),
        Preset(
            id: stableID("DA3A53E0-001C-44A4-9933-A7CA40742B75"),
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
            id: stableID("B09470AB-8773-47A8-B3F9-5A7ED57F382F"),
            name: "Sleep",
            icon: "moon.fill",
            sources: [
                SoundSource(type: .brownNoise, volume: 0.35),
                SoundSource(type: .ocean, volume: 0.3)
            ],
            isBuiltIn: true
        ),
        Preset(
            id: stableID("6261F106-4DB0-40B0-9402-12022A724305"),
            name: "Calm",
            icon: "leaf.fill",
            sources: [
                SoundSource(type: .pinkNoise, volume: 0.3),
                SoundSource(type: .birdsong, volume: 0.4)
            ],
            isBuiltIn: true
        ),
        Preset(
            id: stableID("844BE7D2-F450-4FFC-8DB6-69AAC670D4D1"),
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
            id: stableID("85BF37DD-A998-4E6F-87E0-D0C72C10FA43"),
            name: "Speech Mask",
            icon: "person.wave.2",
            sources: [
                SoundSource(type: .speechMasking, volume: 0.6, maskingStrength: 0.6),
                SoundSource(type: .brownNoise, volume: 0.25)
            ],
            isBuiltIn: true
        ),
        Preset(
            id: stableID("9C4DFB9E-B150-4F11-90A1-7397A6E46ECC"),
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
            id: stableID("8B1ECE4B-7261-4607-8A58-521AAE1BE7F0"),
            name: "Coffee Shop",
            icon: "cup.and.saucer.fill",
            sources: [
                makeSource("moodist.places.cafe", volume: 1.0),
                makeSource("moodist.things.keyboard", volume: 0.8),
                makeSource("moodist.rain.light", volume: 0.85),
            ].compactMap { $0 },
            isBuiltIn: true
        ),
        Preset(
            id: stableID("2CA054C9-B389-4C55-8EB2-44B3FDB4017E"),
            name: "Rainy Day",
            icon: "cloud.rain.fill",
            sources: [
                makeSource("moodist.rain.light", volume: 1.0),
                makeSource("moodist.rain.thunder", volume: 0.75),
                makeSource("moodist.nature.wind", volume: 0.7),
            ].compactMap { $0 },
            isBuiltIn: true
        ),
        Preset(
            id: stableID("9AEED8A8-1B77-4A4D-9060-100C369FAC2D"),
            name: "Forest",
            icon: "tree.fill",
            sources: [
                makeSource("sample.birds.morning", volume: 1.0),
                makeSource("moodist.nature.river", volume: 0.85),
                makeSource("moodist.nature.wind-trees", volume: 0.75),
            ].compactMap { $0 },
            isBuiltIn: true
        ),
        Preset(
            id: stableID("23619273-4D24-49F5-BF09-CDBD0676A895"),
            name: "Cozy",
            icon: "fireplace.fill",
            sources: [
                makeSource("sample.fire.crackling", volume: 1.0),
                makeSource("moodist.rain.window", volume: 0.85),
                makeSource("moodist.things.clock", volume: 0.6),
            ].compactMap { $0 },
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
            do {
                let decoded = try JSONDecoder().decode([SoundSource].self, from: sourcesData)
                _cachedSources = decoded
                _cachedSourcesData = sourcesData
                return decoded
            } catch {
                // Deliberately NOT cached: the raw blob may be the only copy
                // of the user's mix (e.g. written by a newer app version).
                // Log so the silent-empty-preset symptom has a witness.
                presetLogger.error("SavedPreset sources decode failed (\(self.sourcesData.count) bytes): \(error.localizedDescription)")
                return []
            }
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
