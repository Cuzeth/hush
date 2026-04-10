import SwiftUI
import AVFoundation

struct SettingsView: View {
    let viewModel: PlayerViewModel

    @AppStorage("autoResumeLast") private var autoResumeLast = false
    @AppStorage("mixWithOtherAudio") private var mixWithOtherAudio = true
    @AppStorage("fadeDuration") private var fadeDuration: Double = AudioConstants.defaultFadeDuration
    @AppStorage("binauralCarrier") private var binauralCarrier: Double = Double(AudioConstants.defaultBinauralCarrier)

    @State private var headphonesConnected = AudioEngine.headphonesConnected
    @State private var showCredits = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                List {
                    Section("Playback") {
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
                    } footer: {
                        if !mixWithOtherAudio {
                            Text("Hush will appear in Now Playing and pause other audio apps.")
                                .foregroundStyle(HushPalette.textSecondary)
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
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .foregroundStyle(HushPalette.textPrimary)
                .tint(HushPalette.accentSoft)
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
        }
    }
}
