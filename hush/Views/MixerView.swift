import SwiftUI

struct MixerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var mixerVM = MixerViewModel()
    @State private var showAddSound = false

    var body: some View {
        VStack(spacing: 16) {
            // Active sources
            if viewModel.activeSources.isEmpty {
                Text("No sounds active")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 32)
            } else {
                ForEach(viewModel.activeSources) { source in
                    SourceRow(source: source, viewModel: viewModel)
                }
            }

            // Add sound button
            if viewModel.activeSources.count < AudioConstants.maxSimultaneousSources {
                Button {
                    showAddSound = true
                } label: {
                    Label("Add Sound", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
            }
        }
        .sheet(isPresented: $showAddSound) {
            AddSoundSheet(viewModel: viewModel, mixerVM: mixerVM)
                .presentationDetents([.medium])
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
        self._volume = State(initialValue: source.volume)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.type.icon)
                .font(.body)
                .frame(width: 32)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.type.rawValue)
                    .font(.subheadline.weight(.medium))

                if source.type == .binauralBeats, let range = source.binauralRange {
                    Text(range.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Slider(value: $volume, in: 0...1) { editing in
                if !editing {
                    viewModel.updateVolume(for: source, volume: volume)
                }
            }
            .frame(width: 100)
            .onChange(of: volume) {
                viewModel.updateVolume(for: source, volume: volume)
            }
            .accessibilityLabel("\(source.type.rawValue) volume")
            .accessibilityValue("\(Int(volume * 100)) percent")

            Button {
                viewModel.removeSource(source)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

private struct AddSoundSheet: View {
    let viewModel: PlayerViewModel
    let mixerVM: MixerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let available = mixerVM.soundsNotInMix(activeSources: viewModel.activeSources)

                Section("Generated Noise") {
                    ForEach(available.filter(\.isGenerated)) { type in
                        Button {
                            viewModel.addSource(type)
                            dismiss()
                        } label: {
                            Label(type.rawValue, systemImage: type.icon)
                        }
                    }
                }

                Section("Nature Sounds") {
                    ForEach(available.filter { !$0.isGenerated }) { type in
                        Button {
                            viewModel.addSource(type)
                            dismiss()
                        } label: {
                            Label(type.rawValue, systemImage: type.icon)
                        }
                    }
                }
            }
            .navigationTitle("Add Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
