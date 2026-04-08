import SwiftUI

extension SoundSource {
    var subtitle: String {
        switch type {
        case .binauralBeats, .isochronicTones, .monauralBeats:
            return binauralRange?.description ?? "Realtime generator"
        case .pureTone, .drone:
            if let freq = toneFrequency { return "\(Int(freq)) Hz" }
            return "432 Hz"
        default:
            return type.isGenerated ? "Realtime generator" : "Looped ambience"
        }
    }
}

struct MixerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var showAddSound = false

    var body: some View {
        VStack(spacing: 14) {
            if viewModel.activeSources.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 26))
                        .foregroundStyle(HushPalette.textSecondary)

                    Text("Build your own layer stack")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(HushPalette.textPrimary)

                    Text("Add rain, noise, fire, or binaural beats and shape the mix with simple volume controls.")
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(viewModel.activeSources) { source in
                    SourceRow(source: source, viewModel: viewModel)
                }
            }

            if viewModel.activeSources.count < AudioConstants.maxSimultaneousSources {
                Button {
                    showAddSound = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                        Text("Layer another sound")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(HushPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(HushPalette.surfaceRaised.opacity(0.76))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(HushPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [7, 7]))
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showAddSound) {
            SoundPickerGrid(activeSources: viewModel.activeSources) { type in
                viewModel.addSource(type)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct SourceRow: View {
    let source: SoundSource
    let viewModel: PlayerViewModel
    @State private var volume: Float

    init(source: SoundSource, viewModel: PlayerViewModel) {
        self.source = source
        self.viewModel = viewModel
        _volume = State(initialValue: source.volume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(HushPalette.surfaceRaised.opacity(0.92))
                        .frame(width: 42, height: 42)

                    Image(systemName: source.type.icon)
                        .font(.headline)
                        .foregroundStyle(HushPalette.textPrimary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(source.type.rawValue)
                        .font(.headline)
                        .foregroundStyle(HushPalette.textPrimary)

                    Text(source.subtitle)
                        .font(.caption)
                        .foregroundStyle(HushPalette.textSecondary)
                }

                Spacer()

                Text("\(Int(volume * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HushPalette.textSecondary)
                    .monospacedDigit()

                Button {
                    viewModel.removeSource(source)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(HushCircleButtonStyle())
                .accessibilityLabel("Remove \(source.type.rawValue)")
            }

            Slider(value: $volume, in: 0...1)
            .tint(HushPalette.accentSoft)
            .onChange(of: volume) {
                viewModel.updateVolume(for: source, volume: volume)
            }
            .accessibilityLabel("\(source.type.rawValue) volume")
            .accessibilityValue("\(Int(volume * 100)) percent")

            if isToneType {
                ToneFrequencyPicker(source: source, viewModel: viewModel)
            }

            if isBinauralType {
                BinauralRangePicker(source: source, viewModel: viewModel)
            }
        }
        .padding(18)
        .hushPanel(radius: 26, fill: HushPalette.surface.opacity(0.94))
    }

    private var isToneType: Bool {
        source.type == .pureTone || source.type == .drone
    }

    private var isBinauralType: Bool {
        [.binauralBeats, .isochronicTones, .monauralBeats].contains(source.type)
    }
}

struct SoundPickerGrid: View {
    let activeSources: [SoundSource]
    let onSelect: (SoundType) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var available: [SoundType] {
        let activeTypes = Set(activeSources.map(\.type))
        return SoundType.allCases.filter { !activeTypes.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        soundSection(
                            title: "Generated",
                            subtitle: "Realtime DSP layers",
                            sounds: available.filter(\.isGenerated)
                        )

                        soundSection(
                            title: "Nature",
                            subtitle: "Looped ambient recordings",
                            sounds: available.filter { !$0.isGenerated }
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Add Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HushPalette.textPrimary)
                }
            }
        }
        .tint(HushPalette.accentSoft)
    }

    @ViewBuilder
    private func soundSection(title: String, subtitle: String, sounds: [SoundType]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(HushPalette.textPrimary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(sounds) { type in
                    Button {
                        onSelect(type)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(HushPalette.surfaceRaised.opacity(0.92))
                                    .frame(width: 42, height: 42)

                                Image(systemName: type.icon)
                                    .font(.headline)
                                    .foregroundStyle(HushPalette.textPrimary)
                            }

                            Text(type.rawValue)
                                .font(.headline)
                                .foregroundStyle(HushPalette.textPrimary)
                                .multilineTextAlignment(.leading)

                            Text(type.isGenerated ? "Synthetic" : "Recorded")
                                .font(.caption)
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
                        .padding(16)
                        .hushPanel(radius: 26, fill: HushPalette.surface.opacity(0.94))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct BinauralRangePicker: View {
    let source: SoundSource
    let viewModel: PlayerViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BinauralRange.allCases) { range in
                    let isSelected = source.binauralRange == range
                    Button {
                        viewModel.updateBinaural(for: source, range: range, frequency: range.defaultFrequency)
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? HushPalette.accentSoft.opacity(0.3) : HushPalette.surfaceRaised.opacity(0.6))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ToneFrequencyPicker: View {
    let source: SoundSource
    let viewModel: PlayerViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TonePreset.allCases) { preset in
                    let isSelected = source.toneFrequency == preset.frequency
                    Button {
                        viewModel.updateToneFrequency(for: source, frequency: preset.frequency)
                    } label: {
                        Text(preset.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? HushPalette.accentSoft.opacity(0.3) : HushPalette.surfaceRaised.opacity(0.6))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
