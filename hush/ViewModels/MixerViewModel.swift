import SwiftUI

@Observable
final class MixerViewModel {
    var availableSounds: [SoundType] {
        SoundType.allCases
    }

    func soundsNotInMix(activeSources: [SoundSource]) -> [SoundType] {
        let activeTypes = Set(activeSources.map(\.type))
        return SoundType.allCases.filter { !activeTypes.contains($0) }
    }
}
