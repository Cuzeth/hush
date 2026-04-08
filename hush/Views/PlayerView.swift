import SwiftUI
import SwiftData

struct PlayerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var showSavePreset = false
    @State private var presetName = ""
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("Hush")
                    .font(.title2.weight(.bold))

                Spacer()

                Button {
                    viewModel.showTimer = true
                } label: {
                    if viewModel.timerState.isRunning {
                        Text(viewModel.timerState.displayTime)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.3))
                            .clipShape(Capsule())
                    } else {
                        Image(systemName: "timer")
                            .font(.title3)
                    }
                }
                .foregroundStyle(.primary)

                Button {
                    viewModel.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            // Central play button
            VStack(spacing: 24) {
                // Current state label
                if let preset = viewModel.currentPreset {
                    Text(preset.name)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else if !viewModel.activeSources.isEmpty {
                    Text("Custom Mix")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Active source icons
                if !viewModel.activeSources.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(viewModel.activeSources.prefix(6)) { source in
                            Image(systemName: source.type.icon)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Play/Pause button
                Button {
                    viewModel.togglePlayback()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(viewModel.isPlaying ? 0.3 : 0.15))
                            .frame(width: 88, height: 88)

                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.accentColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.activeSources.isEmpty)
            }

            Spacer()

            // Preset selector
            PresetSelector(
                onSelect: { preset in viewModel.loadPreset(preset) },
                onRandom: { viewModel.randomMix() },
                selectedPreset: viewModel.currentPreset
            )
            .padding(.bottom, 8)

            // Mixer toggle
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.showMixer.toggle()
                    }
                } label: {
                    HStack {
                        Text("Mix")
                            .font(.subheadline.weight(.medium))
                        Spacer()

                        if !viewModel.activeSources.isEmpty {
                            // Save preset button
                            Button {
                                showSavePreset = true
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.secondary)
                        }

                        Image(systemName: viewModel.showMixer ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                if viewModel.showMixer {
                    Divider()
                        .padding(.horizontal)
                    MixerView(viewModel: viewModel)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color(.systemGray6).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $viewModel.showTimer) {
            TimerView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView()
        }
        .alert("Headphones Recommended", isPresented: $viewModel.showHeadphoneWarning) {
            Button("OK") {}
        } message: {
            Text("Binaural beats require headphones to work. Each ear must receive a different frequency without crosstalk.")
        }
        .alert("Headphones Disconnected", isPresented: $viewModel.showBinauralRouteWarning) {
            Button("OK") {}
        } message: {
            Text("Binaural beats were paused because headphones were disconnected. Reconnect headphones and press play to resume.")
        }
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") {
                guard !presetName.isEmpty else { return }
                viewModel.saveCurrentAsPreset(name: presetName, context: modelContext)
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        }
    }
}
