import Foundation
import Observation

/// One card in the Add Sound picker: a live generator, or a recorded or
/// imported file.
enum PickerSound: Hashable, Identifiable {
    case generated(SoundType)
    case asset(SoundAsset)

    /// The `SoundType` raw value for generators, the asset ID otherwise.
    /// This is what `RecentSounds` stores.
    var id: String {
        switch self {
        case .generated(let type): return type.rawValue
        case .asset(let asset): return asset.id
        }
    }

    var title: String {
        switch self {
        case .generated(let type): return type.rawValue
        case .asset(let asset): return asset.displayName
        }
    }

    var icon: String {
        switch self {
        case .generated(let type): return type.icon
        case .asset(let asset): return asset.icon
        }
    }

    /// Already in the mix, by the picker's one exclusion rule: assets by ID
    /// (legacy-typed sources count as their default asset), generators by type.
    func isActive(in sources: [SoundSource]) -> Bool {
        switch self {
        case .generated(let type):
            return sources.contains { $0.type == type }
        case .asset(let asset):
            return SoundSearch.activeAssetIDs(in: sources).contains(asset.id)
        }
    }
}

/// The last few sounds added from the picker, newest first, persisted in
/// UserDefaults as `PickerSound.id` strings.
@Observable
final class RecentSounds {
    static let storageKey = "recentPickerSounds"
    static let limit = 8

    private(set) var entries: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    func record(_ sound: PickerSound) {
        entries = Self.inserting(sound.id, into: entries)
        defaults.set(entries, forKey: Self.storageKey)
    }

    /// Newest first, de-duplicated, capped at `limit`.
    static func inserting(_ entry: String, into entries: [String]) -> [String] {
        Array(([entry] + entries.filter { $0 != entry }).prefix(limit))
    }

    /// What the Recent row shows: entries that still resolve and aren't
    /// already in the mix, in recency order. Storage is left alone, so a
    /// sound removed from the mix comes back to the row.
    func visible(excluding activeSources: [SoundSource]) -> [PickerSound] {
        visible(excluding: activeSources) { SoundAssetRegistry.asset(withID: $0) }
    }

    func visible(
        excluding activeSources: [SoundSource],
        resolveAsset: (String) -> SoundAsset?
    ) -> [PickerSound] {
        entries
            .compactMap { Self.resolve($0, resolveAsset: resolveAsset) }
            .filter { !$0.isActive(in: activeSources) }
    }

    static func resolve(_ entry: String, resolveAsset: (String) -> SoundAsset?) -> PickerSound? {
        if let type = SoundType(rawValue: entry) {
            // Only generators are stored by type. Legacy sample types and
            // `.sampleAsset` are never added from the picker.
            return type.isGenerated ? .generated(type) : nil
        }
        return resolveAsset(entry).map(PickerSound.asset)
    }
}
