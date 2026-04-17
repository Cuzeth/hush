import SwiftUI
import SwiftData

struct EditPresetSheet: View {
    let preset: Preset
    let onSave: (Preset, [SoundSource]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sources: [SoundSource]
    @State private var showAddSound = false

    init(preset: Preset, onSave: @escaping (Preset, [SoundSource]) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _sources = State(initialValue: preset.sources)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(sources) { source in
                            EditSourceRow(source: source, sources: $sources)
                        }

                        if sources.count < AudioConstants.maxSimultaneousSources {
                            Button { showAddSound = true } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus")
                                        .font(.subheadline.weight(.bold))
                                    Text("Add sound")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .foregroundStyle(HushPalette.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: HushRadius.md, style: .continuous)
                                        .fill(HushPalette.surfaceRaised.opacity(0.76))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: HushRadius.md, style: .continuous)
                                                .strokeBorder(HushPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [7, 7]))
                                        )
                                )
                            }
                            .buttonStyle(HushPressButtonStyle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                    .frame(maxWidth: sizeClass == .regular ? 600 : .infinity)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Edit \(preset.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HushPalette.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preset, sources)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(HushPalette.accentSoft)
                    .disabled(sources.isEmpty)
                }
            }
        }
        .tint(HushPalette.accentSoft)
        .sheet(isPresented: $showAddSound) {
            SoundPickerGrid(activeSources: sources) { type in
                var source = SoundSource(type: type, volume: 0.5)
                if type == .pureTone || type == .drone {
                    source.toneFrequency = TonePreset.hz432.frequency
                }
                if reduceMotion {
                    sources.append(source)
                } else {
                    withAnimation(HushMotion.standard) { sources.append(source) }
                }
            } onSelectAsset: { asset in
                let source = SoundSource(asset: asset, volume: 0.5)
                if reduceMotion {
                    sources.append(source)
                } else {
                    withAnimation(HushMotion.standard) { sources.append(source) }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Source Row (local editing, no engine interaction)

private struct EditSourceRow: View {
    let source: SoundSource
    @Binding var sources: [SoundSource]
    @State private var volume: Float
    @State private var maskingStrength: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(source: SoundSource, sources: Binding<[SoundSource]>) {
        self.source = source
        self._sources = sources
        _volume = State(initialValue: source.volume)
        _maskingStrength = State(initialValue: source.maskingStrength ?? 0.5)
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
                    if reduceMotion {
                        sources.removeAll { $0.id == source.id }
                    } else {
                        withAnimation(HushMotion.standard) {
                            sources.removeAll { $0.id == source.id }
                        }
                    }
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
                    if let idx = sources.firstIndex(where: { $0.id == source.id }) {
                        sources[idx].volume = volume
                    }
                }

            if source.type == .pureTone || source.type == .drone {
                ToneFrequencyPicker(selected: source.toneFrequency) { freq in
                    if let idx = sources.firstIndex(where: { $0.id == source.id }) {
                        sources[idx].toneFrequency = freq
                    }
                }
            }

            if isBinauralType {
                BinauralRangePicker(selected: source.binauralRange) { range in
                    if let idx = sources.firstIndex(where: { $0.id == source.id }) {
                        sources[idx].binauralRange = range
                        sources[idx].binauralFrequency = range.defaultFrequency
                    }
                }
            }

            if source.type == .speechMasking {
                MaskingStrengthSlider(strength: $maskingStrength)
                    .onChange(of: maskingStrength) {
                        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
                            sources[idx].maskingStrength = maskingStrength
                        }
                    }
            }
        }
        .padding(18)
        .hushPanel(radius: HushRadius.lg)
        .accessibilityElement(children: .contain)
    }

    private var isBinauralType: Bool {
        [.binauralBeats, .isochronicTones, .monauralBeats].contains(source.type)
    }
}
