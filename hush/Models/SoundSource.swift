import Foundation

struct SoundSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var type: SoundType
    var volume: Float
    var isActive: Bool

    // Binaural-specific
    var binauralRange: BinauralRange?
    var binauralFrequency: Float?

    init(type: SoundType, volume: Float = 0.7, isActive: Bool = true,
         binauralRange: BinauralRange? = nil, binauralFrequency: Float? = nil) {
        self.type = type
        self.volume = volume
        self.isActive = isActive
        self.binauralRange = binauralRange
        self.binauralFrequency = binauralFrequency
    }

    enum CodingKeys: String, CodingKey {
        case id, type, volume, isActive, binauralRange, binauralFrequency
    }
}

extension BinauralRange: Codable {}
