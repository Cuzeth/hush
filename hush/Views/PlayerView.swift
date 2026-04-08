import SwiftUI
import SwiftData

struct PlayerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var showSavePreset = false
    @State private var presetName = ""

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .title) private var playButtonHeight: CGFloat = 62
    @ScaledMetric(relativeTo: .body) private var circleButtonSize: CGFloat = 44

    var body: some View {
        ZStack(alignment: .bottom) {
            HushBackdrop()

            // Scrollable content — padding at bottom for the fixed transport bar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    topBar
                    nowPlayingHeader
                    PresetSelector(
                        onSelect: { preset in viewModel.loadPreset(preset) },
                        onRandom: { viewModel.randomMix() },
                        onDelete: { preset in viewModel.handlePresetDeleted(preset) },
                        selectedPreset: viewModel.currentPreset
                    )
                    mixerSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120) // room for transport bar
            }

            // Fixed transport bar at bottom — always visible, no scrolling needed
            transportBar
        }
        .sensoryFeedback(.selection, trigger: viewModel.isPlaying)
        .sensoryFeedback(.selection, trigger: viewModel.currentPreset?.id)
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

    // MARK: - Top Bar (compact, app-native)

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hush")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(HushPalette.textPrimary)
            }

            Spacer()

            HStack(spacing: 10) {
                if viewModel.timerState.isRunning {
                    Button { viewModel.showTimer = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.caption.weight(.bold))
                            Text(viewModel.timerState.displayTime)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(HushPalette.accent))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { viewModel.showTimer = true } label: {
                        Image(systemName: "timer")
                            .font(.body.weight(.medium))
                            .foregroundStyle(HushPalette.textSecondary)
                            .frame(width: circleButtonSize, height: circleButtonSize)
                    }
                    .buttonStyle(.plain)
                }

                Button { viewModel.showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                        .foregroundStyle(HushPalette.textSecondary)
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Now Playing (concise state, not marketing copy)

    private var nowPlayingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentTitle)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(HushPalette.textPrimary)

                    if !viewModel.activeSources.isEmpty {
                        Text(sourcesSummary)
                            .font(.subheadline)
                            .foregroundStyle(HushPalette.textSecondary)
                            .transition(.opacity)
                    }
                }

                Spacer()

                if viewModel.isPlaying {
                    HushInfoPill(icon: "waveform", text: "Playing", highlighted: true)
                        .accessibilityLabel("Now playing")
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }

            // Source chips — only when mix is loaded
            if !viewModel.activeSources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.activeSources.prefix(6)) { source in
                            HStack(spacing: 6) {
                                Image(systemName: source.type.icon)
                                    .font(.caption2.weight(.bold))
                                Text(source.type.rawValue)
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(HushPalette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(HushPalette.surfaceRaised.opacity(0.9))
                                    .overlay(Capsule().strokeBorder(HushPalette.outline, lineWidth: 1))
                            )
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(heroBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(HushPalette.outlineStrong, lineWidth: 1)
        )
    }

    // MARK: - Mixer Section (progressive disclosure, compact)

    private var mixerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if reduceMotion {
                    viewModel.showMixer.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.showMixer.toggle()
                    }
                }
            } label: {
                HStack {
                    Text("Customize")
                        .font(.headline)
                        .foregroundStyle(HushPalette.textPrimary)

                    Spacer()

                    HStack(spacing: 10) {
                        if !viewModel.activeSources.isEmpty {
                            Button {
                                showSavePreset = true
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(HushPalette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Save current mix as preset")
                        }

                        Image(systemName: viewModel.showMixer ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(HushPalette.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.showMixer ? "Hide mixer" : "Show mixer")

            if viewModel.showMixer {
                MixerView(viewModel: viewModel)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .hushPanel(fill: HushPalette.surface.opacity(0.92))
    }

    // MARK: - Fixed Transport Bar (always visible at bottom)

    private var transportBar: some View {
        VStack(spacing: 0) {
            // Gradient fade to make scroll content disappear under the bar
            LinearGradient(colors: [.clear, HushPalette.background.opacity(0.95)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .allowsHitTesting(false)

            HStack(spacing: 14) {
                Button {
                    viewModel.togglePlayback()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body.weight(.bold))
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))

                        Text(viewModel.isPlaying ? "Pause" : "Play")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(viewModel.activeSources.isEmpty ? HushPalette.textMuted : Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: playButtonHeight)
                    .background(
                        Capsule()
                            .fill(viewModel.activeSources.isEmpty ? HushPalette.surfaceRaised : HushPalette.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.activeSources.isEmpty)
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(HushPalette.background.opacity(0.95))
        }
    }

    // MARK: - Hero Background

    private var heroBackground: some View {
        let colors = activePalette
        return RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [colors[0].opacity(0.5), colors[1].opacity(0.18), HushPalette.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    // MARK: - Helpers

    private var currentTitle: String {
        if let preset = viewModel.currentPreset { return preset.name }
        if !viewModel.activeSources.isEmpty { return "Custom Mix" }
        return "Choose a Scene"
    }

    private var sourcesSummary: String {
        soundSourceSummary(viewModel.activeSources)
    }

    private var activePalette: [Color] {
        let primaryType = viewModel.activeSources.first?.type ?? viewModel.currentPreset?.sources.first?.type
        switch primaryType {
        case .rain, .stream, .ocean:
            return [Color(red: 0.23, green: 0.36, blue: 0.42), Color(red: 0.12, green: 0.17, blue: 0.23)]
        case .birdsong, .wind:
            return [Color(red: 0.28, green: 0.40, blue: 0.31), Color(red: 0.12, green: 0.18, blue: 0.15)]
        case .fire, .thunder:
            return [Color(red: 0.44, green: 0.27, blue: 0.18), Color(red: 0.18, green: 0.11, blue: 0.10)]
        case .binauralBeats, .isochronicTones, .monauralBeats, .pureTone, .drone:
            return [Color(red: 0.31, green: 0.25, blue: 0.44), Color(red: 0.16, green: 0.12, blue: 0.23)]
        case .whiteNoise, .pinkNoise, .brownNoise, .grayNoise:
            return [Color(red: 0.33, green: 0.32, blue: 0.28), Color(red: 0.16, green: 0.15, blue: 0.13)]
        case .none:
            return [HushPalette.accentGlow, HushPalette.surfaceRaised]
        }
    }
}
