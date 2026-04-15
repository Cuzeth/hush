import SwiftUI
import UniformTypeIdentifiers

extension SoundSource {
    var subtitle: String {
        switch type {
        case .binauralBeats, .isochronicTones, .monauralBeats:
            return binauralRange?.description ?? "Realtime generator"
        case .speechMasking:
            let pct = Int((maskingStrength ?? 0.5) * 100)
            return "Strength: \(pct)%"
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
    @Environment(UserSoundLibrary.self) private var library
    @State private var volume: Float
    @State private var maskingStrength: Float
    @State private var pendingRelinkURL: URL?
    @State private var showRelinkPicker = false

    init(source: SoundSource, viewModel: PlayerViewModel) {
        self.source = source
        self.viewModel = viewModel
        _volume = State(initialValue: source.volume)
        _maskingStrength = State(initialValue: source.maskingStrength ?? 0.5)
    }

    /// The backing user asset, if any, and whether its file is missing.
    private var missingUserAsset: UserSoundAsset? {
        guard let id = source.assetID,
              let uuid = UserSoundAsset.uuid(fromAssetID: id),
              let record = library.assetsByID[uuid],
              record.isMissing else { return nil }
        return record
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(HushPalette.raisedFill)
                        .frame(width: 42, height: 42)

                    Image(systemName: source.displayIcon)
                        .font(.headline)
                        .foregroundStyle(missingUserAsset != nil ? HushPalette.danger : HushPalette.textPrimary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
                        .font(.headline)
                        .foregroundStyle(HushPalette.textPrimary)

                    if let missing = missingUserAsset {
                        Button {
                            showRelinkPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Missing — tap to relink")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HushPalette.danger)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Relink \(missing.displayName)")
                    } else {
                        Text(source.subtitle)
                            .font(.caption)
                            .foregroundStyle(HushPalette.textSecondary)
                    }
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
                ToneFrequencyPicker(selected: source.toneFrequency) { freq in
                    viewModel.updateToneFrequency(for: source, frequency: freq)
                }
            }

            if isBinauralType {
                BinauralRangePicker(selected: source.binauralRange) { range in
                    viewModel.updateBinaural(for: source, range: range, frequency: range.defaultFrequency)
                }
            }

            if source.type == .speechMasking {
                MaskingStrengthSlider(strength: $maskingStrength)
                    .onChange(of: maskingStrength) {
                        viewModel.updateMaskingStrength(for: source, strength: maskingStrength)
                    }
            }
        }
        .padding(18)
        .hushPanel(radius: 26)
        .fileImporter(
            isPresented: $showRelinkPicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let asset = missingUserAsset else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try? library.relink(asset, to: url)
            // Re-attach the existing source so the engine picks up the new
            // file without changing the row's UUID, volume, or position.
            viewModel.relinkSource(source)
        }
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
    @Environment(UserSoundLibrary.self) private var library
    @State private var expandedCategories: Set<SoundCategory> = []
    @State private var showFileImporter = false
    @State private var pendingImportURL: ImportURL?
    @State private var importerError: String?

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

    /// Categories that have at least one non-active asset (bundled only —
    /// user imports are surfaced in their own section so they're easy to find).
    private var categoriesWithAssets: [SoundCategory] {
        SoundCategory.allCases.filter { cat in
            SoundAssetRegistry.bundled.contains { $0.category == cat && !activeAssetIDs.contains($0.id) }
        }
    }

    private var availableUserAssets: [SoundAsset] {
        library.allSoundAssets.filter { !activeAssetIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        mySoundsSection

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

                if let importerError {
                    VStack {
                        Spacer()
                        Text(importerError)
                            .font(.caption)
                            .foregroundStyle(HushPalette.danger)
                            .padding(12)
                            .hushPanel(radius: 14)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }
                    .transition(.opacity)
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
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let first = urls.first { pendingImportURL = ImportURL(url: first) }
                case .failure(let error):
                    flashError(error.localizedDescription)
                }
            }
            .sheet(item: $pendingImportURL) { wrap in
                ImportSoundSheet(mode: .newImport(sourceURL: wrap.url), library: library) { newAsset in
                    // Auto-add the freshly imported sound and dismiss the
                    // picker — user shouldn't have to find it in the list.
                    if let resolved = library.asset(withID: newAsset.assetID) {
                        onSelectAsset(resolved)
                        dismiss()
                    }
                }
            }
        }
        .tint(HushPalette.accentSoft)
    }

    // MARK: - My Sounds (user imports)

    @ViewBuilder private var mySoundsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My Sounds")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Audio you've imported from your device")
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                Button {
                    showFileImporter = true
                } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        ZStack {
                            Circle()
                                .strokeBorder(HushPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .frame(width: 42, height: 42)
                            Image(systemName: "plus")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(HushPalette.accentSoft)
                        }
                        Text("Import sound")
                            .font(.headline)
                            .foregroundStyle(HushPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text("Pick a file from your device")
                            .font(.caption)
                            .foregroundStyle(HushPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(HushPalette.panelFillSoft)
                            .overlay(
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .strokeBorder(HushPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                            )
                    )
                }
                .buttonStyle(HushPressButtonStyle())

                ForEach(availableUserAssets) { asset in
                    Button {
                        onSelectAsset(asset)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(HushPalette.raisedFill)
                                    .frame(width: 42, height: 42)
                                Image(systemName: asset.icon)
                                    .font(.headline)
                                    .foregroundStyle(HushPalette.textPrimary)
                            }
                            Text(asset.displayName)
                                .font(.headline)
                                .foregroundStyle(HushPalette.textPrimary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Text("Imported")
                                .font(.caption)
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
                        .padding(16)
                        .hushPanel(radius: 26)
                    }
                    .buttonStyle(HushPressButtonStyle())
                }
            }
        }
    }

    private func flashError(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            importerError = message
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeInOut(duration: 0.2)) { importerError = nil }
        }
    }

    @ViewBuilder
    private func categorySection(_ category: SoundCategory) -> some View {
        // Bundled-only here — user imports live in the My Sounds section so
        // they don't get scattered across categories.
        let assets = SoundAssetRegistry.bundled.filter {
            $0.category == category && !activeAssetIDs.contains($0.id)
        }
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
                                        .fill(HushPalette.raisedFill)
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
                            .hushPanel(radius: 26)
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
                                    .fill(HushPalette.raisedFill)
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
                        .hushPanel(radius: 26)
                    }
                    .buttonStyle(HushPressButtonStyle())
                }
            }
        }
    }
}

// MARK: - Shared Pickers
//
// One set of controls used by both MixerView (live engine updates) and
// EditPresetSheet (local state). Callers own the state and the write path.

struct ToneFrequencyPicker: View {
    let selected: Float?
    let onSelect: (Float) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TonePreset.allCases) { preset in
                    let isSelected = selected == preset.frequency
                    Button { onSelect(preset.frequency) } label: {
                        Text(preset.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? HushPalette.chipActive : HushPalette.chipMuted)
                            )
                    }
                    .buttonStyle(HushPressButtonStyle())
                    .animation(.easeInOut(duration: 0.15), value: selected)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct BinauralRangePicker: View {
    let selected: BinauralRange?
    let onSelect: (BinauralRange) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BinauralRange.allCases) { range in
                    let isSelected = selected == range
                    Button { onSelect(range) } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? HushPalette.chipActive : HushPalette.chipMuted)
                            )
                    }
                    .buttonStyle(HushPressButtonStyle())
                    .animation(.easeInOut(duration: 0.15), value: selected)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct MaskingStrengthSlider: View {
    @Binding var strength: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Masking strength")
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
                Spacer()
                Text("\(Int(strength * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HushPalette.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: $strength, in: 0...1)
            .tint(HushPalette.accentSoft)
            .accessibilityLabel("Masking strength")
            .accessibilityValue("\(Int(strength * 100)) percent")
        }
        // Subtle click every 10% during drag — matches TimerView's per-detent
        // model so the haptic language is consistent across sliders.
        .sensoryFeedback(.selection, trigger: Int(strength * 10))
    }
}
