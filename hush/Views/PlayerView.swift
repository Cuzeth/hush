import SwiftUI
import SwiftData

struct PlayerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var showSavePreset = false
    @State private var presetName = ""

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HushBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    heroCard
                    currentMixCard
                    playbackCard
                    PresetSelector(
                        onSelect: { preset in viewModel.loadPreset(preset) },
                        onRandom: { viewModel.randomMix() },
                        selectedPreset: viewModel.currentPreset
                    )
                    customizeCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .tint(HushPalette.accentSoft)
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
            Button("Cancel", role: .cancel) {
                presetName = ""
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("HUSH")
                        .font(.caption.weight(.bold))
                        .tracking(3)
                        .foregroundStyle(HushPalette.textSecondary)

                    Text("Ambient Focus\nFor Deep Work")
                        .font(.system(size: 44, weight: .semibold, design: .serif))
                        .foregroundStyle(HushPalette.textPrimary)
                        .lineSpacing(2)

                    Text("A calmer, darker deck of one-tap scenes for focus, rest, and sleep.")
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                        .lineSpacing(2)
                }

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    timerAccessButton

                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.headline)
                    }
                    .buttonStyle(HushCircleButtonStyle())
                    .accessibilityLabel("Open settings")
                }
            }

            HStack(spacing: 10) {
                HushInfoPill(icon: "square.grid.2x2", text: "\(Preset.builtIn.count) scenes")
                HushInfoPill(icon: "waveform", text: "\(viewModel.activeSources.count) layers")

                if viewModel.timerState.isRunning {
                    HushInfoPill(icon: "timer", text: viewModel.timerState.displayTime, highlighted: true)
                }
            }
        }
        .padding(24)
        .background(heroBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(HushPalette.outlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 24, x: 0, y: 16)
    }

    private var currentMixCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(currentMixHeading)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(HushPalette.textPrimary)

                    Text(currentMixDetail)
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                        .lineSpacing(2)
                }

                Spacer()

                HushInfoPill(
                    icon: viewModel.isPlaying ? "waveform" : "pause.fill",
                    text: playbackStateLabel,
                    highlighted: viewModel.isPlaying
                )
            }

            if !viewModel.activeSources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.activeSources.prefix(6)) { source in
                            HStack(spacing: 8) {
                                Image(systemName: source.type.icon)
                                    .font(.caption.weight(.bold))
                                Text(source.type.rawValue)
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(HushPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(HushPalette.surfaceRaised.opacity(0.92))
                                    .overlay(Capsule().strokeBorder(HushPalette.outline, lineWidth: 1))
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .hushPanel(fill: HushPalette.surface.opacity(0.92))
    }

    private var playbackCard: some View {
        VStack(spacing: 18) {
            Button {
                viewModel.togglePlayback()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.bold))

                    Text(viewModel.isPlaying ? "Pause Mix" : "Play Mix")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(viewModel.activeSources.isEmpty ? HushPalette.textMuted : Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    Capsule()
                        .fill(viewModel.activeSources.isEmpty ? HushPalette.surfaceRaised : HushPalette.accent)
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(viewModel.activeSources.isEmpty ? 0.12 : 0.24), radius: 16, x: 0, y: 10)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.activeSources.isEmpty)
            .accessibilityLabel(viewModel.isPlaying ? "Pause playback" : "Start playback")
            .accessibilityValue(viewModel.activeSources.isEmpty ? "No sounds selected" : (viewModel.isPlaying ? "Playing" : "Stopped"))

            Text(playbackHint)
                .font(.caption)
                .foregroundStyle(HushPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .hushPanel(fill: HushPalette.surface.opacity(0.80))
    }

    private var customizeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Customize")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(HushPalette.textPrimary)

                    Text("Shape the live mix layer by layer, then save it when it clicks.")
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    if !viewModel.activeSources.isEmpty {
                        Button {
                            showSavePreset = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.headline)
                        }
                        .buttonStyle(HushCircleButtonStyle())
                        .accessibilityLabel("Save current mix as preset")
                    }

                    Button {
                        if reduceMotion {
                            viewModel.showMixer.toggle()
                        } else {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                viewModel.showMixer.toggle()
                            }
                        }
                    } label: {
                        Image(systemName: viewModel.showMixer ? "chevron.down" : "chevron.up")
                            .font(.headline)
                    }
                    .buttonStyle(HushCircleButtonStyle(selected: viewModel.showMixer))
                    .accessibilityLabel(viewModel.showMixer ? "Hide mixer" : "Show mixer")
                }
            }

            if viewModel.showMixer {
                MixerView(viewModel: viewModel)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .hushPanel(fill: HushPalette.surface.opacity(0.92))
    }

    private var timerAccessButton: some View {
        Group {
            if viewModel.timerState.isRunning {
                Button {
                    viewModel.showTimer = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "timer")
                            .font(.caption.weight(.bold))
                        Text(viewModel.timerState.displayTime)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(HushPalette.accent)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    viewModel.showTimer = true
                } label: {
                    Image(systemName: "timer")
                        .font(.headline)
                }
                .buttonStyle(HushCircleButtonStyle())
            }
        }
        .accessibilityLabel(viewModel.timerState.isRunning ? "Timer running" : "Open timer")
        .accessibilityValue(viewModel.timerState.isRunning ? viewModel.timerState.displayTime : "Off")
    }

    private var heroBackground: some View {
        let colors = activePalette

        return RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        colors[0].opacity(0.52),
                        colors[1].opacity(0.18),
                        HushPalette.surface
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.06), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    private var activePalette: [Color] {
        let primaryType: SoundType?
        if let activeType = viewModel.activeSources.first?.type {
            primaryType = activeType
        } else {
            primaryType = viewModel.currentPreset?.sources.first?.type
        }

        switch primaryType {
        case .rain, .stream, .ocean:
            return [Color(red: 0.232, green: 0.362, blue: 0.418), Color(red: 0.118, green: 0.168, blue: 0.226)]
        case .birdsong, .wind:
            return [Color(red: 0.282, green: 0.398, blue: 0.314), Color(red: 0.124, green: 0.178, blue: 0.148)]
        case .fire, .thunder:
            return [Color(red: 0.440, green: 0.266, blue: 0.176), Color(red: 0.178, green: 0.114, blue: 0.104)]
        case .binauralBeats:
            return [Color(red: 0.314, green: 0.250, blue: 0.438), Color(red: 0.156, green: 0.122, blue: 0.230)]
        case .whiteNoise, .pinkNoise, .brownNoise, .grayNoise:
            return [Color(red: 0.328, green: 0.316, blue: 0.284), Color(red: 0.156, green: 0.150, blue: 0.132)]
        case .none:
            return [HushPalette.accentGlow, HushPalette.surfaceRaised]
        }
    }

    private var currentMixHeading: String {
        if let preset = viewModel.currentPreset {
            return preset.name
        }

        if !viewModel.activeSources.isEmpty {
            return "Custom Atmosphere"
        }

        return "Choose a Scene"
    }

    private var currentMixDetail: String {
        if !viewModel.activeSources.isEmpty {
            let names = viewModel.activeSources.map(\.type.rawValue)

            if names.count <= 3 {
                return names.joined(separator: " / ")
            }

            return "\(names[0]) / \(names[1]) / \(names[2]) / +\(names.count - 3) more"
        }

        return "Start with a curated scene below or open the mix deck to build your own layered room."
    }

    private var playbackStateLabel: String {
        if viewModel.isPlaying { return "Live" }
        return viewModel.activeSources.isEmpty ? "Idle" : "Ready"
    }

    private var playbackHint: String {
        if viewModel.activeSources.isEmpty {
            return "Pick a scene first, then bring it to life with one tap."
        }

        return "Background playback, remote controls, and the sleep timer are all wired into the mix."
    }
}
