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

    init(type: SoundType, volume: Float = 0.7, isActive: Bool = true,
         binauralRange: BinauralRange? = nil, binauralFrequency: Float? = nil,
         toneFrequency: Float? = nil) {
        self.type = type
        self.volume = volume
        self.isActive = isActive
        self.binauralRange = binauralRange
        self.binauralFrequency = binauralFrequency
        self.toneFrequency = toneFrequency
    }

    enum CodingKeys: String, CodingKey {
        case id, type, volume, isActive, binauralRange, binauralFrequency, toneFrequency
    }
}
