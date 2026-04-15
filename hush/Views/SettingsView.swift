import SwiftUI
import SwiftData
import AVFoundation

struct SettingsView: View {
    let viewModel: PlayerViewModel

    @AppStorage("autoResumeLast") private var autoResumeLast = false
    @AppStorage("mixWithOtherAudio") private var mixWithOtherAudio = true
    @AppStorage("fadeDuration") private var fadeDuration: Double = AudioConstants.defaultFadeDuration
    @AppStorage("binauralCarrier") private var binauralCarrier: Double = Double(AudioConstants.defaultBinauralCarrier)

    @State private var headphonesConnected = AudioEngine.headphonesConnected
    @State private var showCredits = false
    @State private var showResetConfirmation = false
    @State private var isResetting = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                List {
                    Section {
                        Toggle("Auto-resume last session", isOn: $autoResumeLast)

                        Toggle("Mix with other audio", isOn: $mixWithOtherAudio)
                            .onChange(of: mixWithOtherAudio) { _, newValue in
                                viewModel.setMixWithOtherAudio(newValue)
                            }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Fade duration")
                                Spacer()
                                Text("\(fadeDuration, specifier: "%.1f")s")
                                    .foregroundStyle(HushPalette.textSecondary)
                            }
                            Slider(value: $fadeDuration, in: 0.1...2.0, step: 0.1)
                                .accessibilityLabel("Fade duration")
                                .accessibilityValue("\(fadeDuration, specifier: "%.1f") seconds")
                        }
                    } header: {
                        Text("Playback")
                    } footer: {
                        if mixWithOtherAudio {
                            Text("Hush plays alongside music and podcasts. Turn this off to show playback controls in Control Center and on the lock screen.")
                        } else {
                            Text("Hush will appear in Now Playing and pause other audio apps.")
                        }
                    }

                    Section("Presets") {
                        Button("Restore Built-In Presets") {
                            UserDefaults.standard.removeObject(forKey: "hiddenBuiltInPresets")
                            UserDefaults.standard.removeObject(forKey: "renamedBuiltInPresets")
                        }
                        .foregroundStyle(HushPalette.accentSoft)
                    }

                    Section("Tones") {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Carrier frequency")
                                Spacer()
                                Text("\(Int(binauralCarrier)) Hz")
                                    .foregroundStyle(HushPalette.textSecondary)
                            }
                            Slider(value: $binauralCarrier, in: 100...500, step: 10)
                                .accessibilityLabel("Binaural carrier frequency")
                                .accessibilityValue("\(Int(binauralCarrier)) hertz")
                                .onChange(of: binauralCarrier) { _, newValue in
                                    viewModel.setBinauralCarrier(Float(newValue))
                                }
                        }

                        HStack {
                            Image(systemName: "headphones")
                                .foregroundStyle(HushPalette.textSecondary)
                            Text(headphonesConnected ? "Headphones connected" : "No headphones detected")
                                .font(.subheadline)
                                .foregroundStyle(headphonesConnected ? HushPalette.accentSoft : HushPalette.textSecondary)
                        }
                    }

                    Section("Audio") {
                        HStack {
                            Text("Sample rate")
                            Spacer()
                            Text("\(Int(viewModel.actualSampleRate)) Hz")
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                        HStack {
                            Text("Bit depth")
                            Spacer()
                            Text("32-bit float")
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                    }

                    Section("About") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("1.0")
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                        HStack {
                            Text("License")
                            Spacer()
                            Text("GPL v3")
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                        Button {
                            showCredits = true
                        } label: {
                            HStack {
                                Text("Sound Credits & Acknowledgments")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HushPalette.textSecondary)
                            }
                        }
                        .foregroundStyle(HushPalette.accentSoft)
                        Text("Hush generates focus sounds using real-time DSP. No accounts, no analytics, no tracking.")
                            .font(.caption)
                            .foregroundStyle(HushPalette.textSecondary)
                        Text("Hush is a focus and relaxation aid, not a medical device, and it is not intended to diagnose or treat any condition.")
                            .font(.caption)
                            .foregroundStyle(HushPalette.textSecondary)
                    }

                    Section {
                        Button("Reset App", role: .destructive) {
                            showResetConfirmation = true
                        }
                        .disabled(isResetting)
                    } footer: {
                        Text("Deletes all saved presets and preferences, then closes the app.")
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .foregroundStyle(HushPalette.textPrimary)
                .tint(HushPalette.accentSoft)

                if isResetting {
                    resetOverlay
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                headphonesConnected = viewModel.headphonesConnected
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HushPalette.textPrimary)
                }
            }
            .sheet(isPresented: $showCredits) {
                CreditsView()
            }
            .alert("Reset Hush?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset & Close", role: .destructive) {
                    resetApp()
                }
            } message: {
                Text("This will delete all saved presets, reset all settings to defaults, and close the app.")
            }
        }
    }

    private var resetOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(HushPalette.accent)
                    .controlSize(.large)

                Text("Resetting Hush…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .hushPanel(radius: 20)
        }
        .transition(.opacity)
    }

    private func resetApp() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isResetting = true
        }

        // Stop playback
        viewModel.stop()
        viewModel.stopTimer()

        // Delete all saved presets
        let descriptor = FetchDescriptor<SavedPreset>()
        if let savedPresets = try? modelContext.fetch(descriptor) {
            for preset in savedPresets {
                modelContext.delete(preset)
            }
            try? modelContext.save()
        }

        // Nuke all UserDefaults for the app
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // Close the app after a brief delay so the overlay is visible and
        // the data wipe completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            exit(0)
        }
    }
}
