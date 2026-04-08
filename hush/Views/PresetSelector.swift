import SwiftUI
import SwiftData

struct PresetSelector: View {
    let onSelect: (Preset) -> Void
    let onRandom: () -> Void
    var selectedPreset: Preset?

    @Query(sort: \SavedPreset.createdAt, order: .reverse)
    private var savedPresets: [SavedPreset]

    private var allPresets: [Preset] {
        Preset.builtIn + savedPresets.map { $0.toPreset() }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Random mix button
                Button(action: onRandom) {
                    VStack(spacing: 6) {
                        Image(systemName: "dice.fill")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .background(Color.purple.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        Text("Random")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                ForEach(allPresets) { preset in
                    Button {
                        onSelect(preset)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: preset.icon)
                                .font(.title2)
                                .frame(width: 56, height: 56)
                                .background(
                                    selectedPreset?.id == preset.id
                                        ? Color.accentColor.opacity(0.4)
                                        : Color(.systemGray5).opacity(0.6)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            Text(preset.name)
                                .font(.caption)
                                .foregroundStyle(
                                    selectedPreset?.id == preset.id
                                        ? .primary
                                        : .secondary
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}
