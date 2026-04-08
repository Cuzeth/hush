import SwiftUI

struct MixerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var mixerVM = MixerViewModel()
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
            AddSoundSheet(viewModel: viewModel, mixerVM: mixerVM)
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

                    Text(sourceSubtitle)
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

            Slider(value: $volume, in: 0...1) { editing in
                if !editing {
                    viewModel.updateVolume(for: source, volume: volume)
                }
            }
            .tint(HushPalette.accentSoft)
            .onChange(of: volume) {
                viewModel.updateVolume(for: source, volume: volume)
            }
            .accessibilityLabel("\(source.type.rawValue) volume")
            .accessibilityValue("\(Int(volume * 100)) percent")
        }
        .padding(18)
        .hushPanel(radius: 26, fill: HushPalette.surface.opacity(0.94))
    }

    private var sourceSubtitle: String {
        if source.type == .binauralBeats, let range = source.binauralRange {
            return range.description
        }

        return source.type.isGenerated ? "Realtime generator" : "Looped ambience"
    }
}

private struct AddSoundSheet: View {
    let viewModel: PlayerViewModel
    let mixerVM: MixerViewModel

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    let available = mixerVM.soundsNotInMix(activeSources: viewModel.activeSources)

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
                        viewModel.addSource(type)
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
