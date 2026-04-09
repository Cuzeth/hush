import Foundation

struct SoundSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var type: SoundType
    var volume: Float
    var isActive: Bool

    // Binaural/isochronic/monaural parameters
    var binauralRange: BinauralRange?
    var binauralFrequency: Float?

    // Pure tone / drone frequency
    var toneFrequency: Float?

    // Asset-based sample: references a SoundAsset by its ID
    var assetID: String?

    init(type: SoundType, volume: Float = 0.7, isActive: Bool = true,
         binauralRange: BinauralRange? = nil, binauralFrequency: Float? = nil,
         toneFrequency: Float? = nil, assetID: String? = nil) {
        self.type = type
        self.volume = volume
        self.isActive = isActive
        self.binauralRange = binauralRange
        self.binauralFrequency = binauralFrequency
        self.toneFrequency = toneFrequency
        self.assetID = assetID
    }

    /// Convenience initializer from a SoundAsset
    init(asset: SoundAsset, volume: Float = 1.0) {
        self.type = .sampleAsset
        self.volume = volume
        self.isActive = true
        self.assetID = asset.id
    }

    /// Resolves the effective asset for this source (works for both legacy and new types)
    var resolvedAsset: SoundAsset? {
        if let assetID { return SoundAssetRegistry.asset(withID: assetID) }
        if let defaultID = type.defaultAssetID { return SoundAssetRegistry.asset(withID: defaultID) }
        return nil
    }

    /// Display name: uses asset name if available, else the type rawValue
    var displayName: String {
        resolvedAsset?.displayName ?? type.rawValue
    }

    /// Icon: uses asset category icon for asset-based sounds
    var displayIcon: String {
        resolvedAsset?.icon ?? type.icon
    }

    enum CodingKeys: String, CodingKey {
        case id, type, volume, isActive, binauralRange, binauralFrequency, toneFrequency, assetID
    }
}
