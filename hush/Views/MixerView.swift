import SwiftUI

extension SoundSource {
    var subtitle: String {
        switch type {
        case .binauralBeats, .isochronicTones, .monauralBeats:
            return binauralRange?.description ?? "Realtime generator"
        case .pureTone, .drone:
            if let freq = toneFrequency { return "\(Int(freq)) Hz" }
            return "432 Hz"
        case .sampleAsset:
            if let asset = resolvedAsset {
                return asset.category.rawValue
            }
            return "Looped ambience"
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
                        .font(.title)
                        .foregroundStyle(HushPalette.textSecondary)

                    Text("Build your own layer stack")
                        .font(.system(.title3, design: .serif, weight: .semibold))
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
                .buttonStyle(HushPressButtonStyle())
            }
        }
        .sheet(isPresented: $showAddSound) {
            SoundPickerGrid(activeSources: viewModel.activeSources) { type in
                viewModel.addSource(type)
            } onSelectAsset: { asset in
                viewModel.addAsset(asset)
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

                    Image(systemName: source.displayIcon)
                        .font(.headline)
                        .foregroundStyle(HushPalette.textPrimary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
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
                .accessibilityLabel("Remove \(source.displayName)")
            }

            Slider(value: $volume, in: 0...1)
            .tint(HushPalette.accentSoft)
            .onChange(of: volume) {
                viewModel.updateVolume(for: source, volume: volume)
            }
            .accessibilityLabel("\(source.displayName) volume")
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
    let onSelectAsset: (SoundAsset) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var expandedCategories: Set<SoundCategory> = []

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    private var activeAssetIDs: Set<String> {
        Set(activeSources.compactMap(\.assetID))
    }

    private var activeGeneratedTypes: Set<SoundType> {
        Set(activeSources.map(\.type).filter(\.isGenerated))
    }

    private var availableGenerated: [SoundType] {
        SoundType.allCases.filter { $0.isGenerated && $0 != .sampleAsset && !activeGeneratedTypes.contains($0) }
    }

    /// Categories that have at least one non-active asset
    private var categoriesWithAssets: [SoundCategory] {
        SoundCategory.allCases.filter { cat in
            SoundAssetRegistry.assets(for: cat).contains { !activeAssetIDs.contains($0.id) }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        // Generated section
                        soundSection(
                            title: "Generated",
                            subtitle: "Realtime DSP layers",
                            sounds: availableGenerated
                        )

                        // Sample categories
                        ForEach(categoriesWithAssets) { category in
                            categorySection(category)
                        }
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
    private func categorySection(_ category: SoundCategory) -> some View {
        let assets = SoundAssetRegistry.assets(for: category).filter { !activeAssetIDs.contains($0.id) }
        let isExpanded = expandedCategories.contains(category)

        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if isExpanded {
                        expandedCategories.remove(category)
                    } else {
                        expandedCategories.insert(category)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: category.icon)
                        .font(.title3)
                        .foregroundStyle(HushPalette.accentSoft)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.rawValue)
                            .font(.system(.title3, design: .serif, weight: .semibold))
                            .foregroundStyle(HushPalette.textPrimary)

                        Text("\(assets.count) sound\(assets.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(HushPalette.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HushPalette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(HushPressButtonStyle())

            if isExpanded {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(assets) { asset in
                        Button {
                            onSelectAsset(asset)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(HushPalette.surfaceRaised.opacity(0.92))
                                        .frame(width: 42, height: 42)

                                    Image(systemName: asset.icon)
                                        .font(.headline)
                                        .foregroundStyle(HushPalette.textPrimary)
                                }

                                Text(asset.displayName)
                                    .font(.headline)
                                    .foregroundStyle(HushPalette.textPrimary)
                                    .multilineTextAlignment(.leading)

                                Text("Recorded")
                                    .font(.caption)
                                    .foregroundStyle(HushPalette.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
                            .padding(16)
                            .hushPanel(radius: 26, fill: HushPalette.surface.opacity(0.94))
                        }
                        .buttonStyle(HushPressButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func soundSection(title: String, subtitle: String, sounds: [SoundType]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.title2, design: .serif, weight: .semibold))
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

                            Text("Synthetic")
                                .font(.caption)
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
                        .padding(16)
                        .hushPanel(radius: 26, fill: HushPalette.surface.opacity(0.94))
                    }
                    .buttonStyle(HushPressButtonStyle())
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
                    .buttonStyle(HushPressButtonStyle())
                    .animation(.easeInOut(duration: 0.15), value: source.binauralRange)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: source.binauralRange)
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
                    .buttonStyle(HushPressButtonStyle())
                    .animation(.easeInOut(duration: 0.15), value: source.toneFrequency)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: source.toneFrequency)
    }
}
