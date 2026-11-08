import Foundation

struct SoundSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var type: SoundType
    var volume: Float

    // Binaural/isochronic/monaural parameters
    var binauralRange: BinauralRange?
    var binauralFrequency: Float?

    // Pure tone / drone frequency
    var toneFrequency: Float?

    // Speech masking strength (0.0 = flat pink noise, 1.0 = full speech-band emphasis)
    var maskingStrength: Float?

    // Asset-based sample: references a SoundAsset by its ID
    var assetID: String?

    init(type: SoundType, volume: Float = 0.7,
         binauralRange: BinauralRange? = nil, binauralFrequency: Float? = nil,
         toneFrequency: Float? = nil, assetID: String? = nil,
         maskingStrength: Float? = nil) {
        self.type = type
        self.volume = volume
        self.binauralRange = binauralRange
        self.binauralFrequency = binauralFrequency
        self.toneFrequency = toneFrequency
        self.assetID = assetID
        self.maskingStrength = maskingStrength
    }

    /// Convenience initializer from a SoundAsset
    init(asset: SoundAsset, volume: Float = 1.0) {
        self.type = .sampleAsset
        self.volume = volume
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

    // `isActive` existed here once but nothing ever set it false — old
    // payloads that still carry the key decode fine (unknown keys are
    // ignored).
    enum CodingKeys: String, CodingKey {
        case id, type, volume, binauralRange, binauralFrequency, toneFrequency, assetID, maskingStrength
    }
}

extension SoundSource {
    /// Slack for slider-driven values: a drag that lands back within this of
    /// the preset's value still counts as unchanged.
    static let layerMatchTolerance: Float = 0.01

    /// Whether `other` produces the same layer: same sound and parameters,
    /// volume within tolerance. Ignores `id` — built-in presets mint fresh
    /// source UUIDs every launch, so a restored session never shares IDs
    /// with the preset it came from.
    func isSameLayer(as other: SoundSource, tolerance: Float = SoundSource.layerMatchTolerance) -> Bool {
        func close(_ a: Float?, _ b: Float?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return abs(a - b) <= tolerance
            default: return false
            }
        }
        return type == other.type
            && assetID == other.assetID
            && binauralRange == other.binauralRange
            && close(volume, other.volume)
            && close(binauralFrequency, other.binauralFrequency)
            && close(toneFrequency, other.toneFrequency)
            && close(maskingStrength, other.maskingStrength)
    }

    /// Order-insensitive layer comparison of two mixes.
    static func mixesMatch(_ lhs: [SoundSource], _ rhs: [SoundSource]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var unmatched = rhs
        for source in lhs {
            guard let index = unmatched.firstIndex(where: { source.isSameLayer(as: $0) }) else {
                return false
            }
            unmatched.remove(at: index)
        }
        return true
    }
}
