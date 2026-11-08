import SwiftUI

/// The Now Playing header's compact mixer: one row per active layer with
/// its level and a remove button. The full per-layer controls (tones,
/// ranges, masking, relink) stay in Customize.
struct LayerLevelStrip: View {
    let viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 2) {
            ForEach(viewModel.activeSources) { source in
                LayerLevelRow(source: source, viewModel: viewModel)
            }
        }
    }
}

private struct LayerLevelRow: View {
    let source: SoundSource
    let viewModel: PlayerViewModel
    @State private var volume: Float

    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 22
    /// One fixed name column, so every row picks the same layout and the
    /// sliders line up. Long names wrap to a second line.
    @ScaledMetric(relativeTo: .subheadline) private var nameWidth: CGFloat = 92
    @ScaledMetric(relativeTo: .subheadline) private var removeSize: CGFloat = 44
    /// Below this the inline slider is too short to set a level with; the
    /// row stacks the slider under the name instead.
    private let inlineSliderMinWidth: CGFloat = 100

    /// The xmark's hit area grows with the text, but only so far: at the
    /// largest sizes an uncapped frame would starve the slider beside it.
    private var removeFrame: CGFloat { min(removeSize, 60) }

    init(source: SoundSource, viewModel: PlayerViewModel) {
        self.source = source
        self.viewModel = viewModel
        _volume = State(initialValue: source.volume)
    }

    var body: some View {
        // Inline on most phones at standard sizes; stacked at large and
        // accessibility text sizes, or wherever the inline row won't fit.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                icon
                name
                    .lineLimit(2)
                    .frame(width: nameWidth, alignment: .leading)
                slider
                    .frame(minWidth: inlineSliderMinWidth, idealWidth: inlineSliderMinWidth,
                           maxWidth: .infinity)
                removeButton
            }

            // Stacked: the name gets the full width to wrap in, and the
            // controls share the line below it.
            VStack(alignment: .leading, spacing: 2) {
                name
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    icon
                    slider
                    removeButton
                }
            }
            .padding(.vertical, 4)
        }
        .onChange(of: volume) {
            // Skip the echo of a sync from the view model below.
            guard volume != source.volume else { return }
            viewModel.updateVolume(for: source, volume: volume)
        }
        .sensoryFeedback(.selection, trigger: Int(volume * 10))
        // The local @State keeps dragging smooth, but it only seeds once per
        // row identity. Presets reuse source UUIDs, so reloading one keeps
        // this row alive with a new level: follow the view model's value.
        .onChange(of: source.volume) { _, newValue in
            if volume != newValue { volume = newValue }
        }
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        // Decorative: the name next to it says it all.
        Image(systemName: source.displayIcon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(HushPalette.textSecondary)
            .frame(width: iconWidth)
            .accessibilityHidden(true)
    }

    private var name: some View {
        Text(source.displayName)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(HushPalette.textPrimary)
            // The slider carries the name for VoiceOver; one stop, not two.
            .accessibilityHidden(true)
    }

    private var slider: some View {
        Slider(value: $volume, in: 0...1)
            .tint(HushPalette.accentSoft)
            .accessibilityLabel(source.displayName)
            .accessibilityValue("\(Int(volume * 100)) percent")
    }

    private var removeButton: some View {
        Button {
            viewModel.removeSource(source)
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(HushPalette.textSecondary)
                .frame(width: removeFrame, height: removeFrame)
                .contentShape(Rectangle())
        }
        .buttonStyle(HushPressButtonStyle())
        .accessibilityLabel("Remove \(source.displayName)")
    }
}
