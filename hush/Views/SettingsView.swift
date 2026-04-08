import SwiftUI

struct SettingsView: View {
    @AppStorage("autoResumeLast") private var autoResumeLast = false
    @AppStorage("fadeDuration") private var fadeDuration: Double = 0.5
    @AppStorage("binauralCarrier") private var binauralCarrier: Double = 200

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                List {
                    Section("Playback") {
                        Toggle("Auto-resume last session", isOn: $autoResumeLast)

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
                                    AudioEngine.shared.setDefaultBinauralCarrier(Float(newValue))
                                }
                        }

                        HStack {
                            Image(systemName: "headphones")
                                .foregroundStyle(HushPalette.textSecondary)
                            Text(AudioEngine.headphonesConnected ? "Headphones connected" : "No headphones detected")
                                .font(.subheadline)
                                .foregroundStyle(AudioEngine.headphonesConnected ? HushPalette.accentSoft : HushPalette.textSecondary)
                        }
                    }

                    Section("Audio") {
                        HStack {
                            Text("Sample rate")
                            Spacer()
                            Text("\(Int(AudioEngine.shared.actualSampleRate)) Hz")
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
                        Text("Hush generates ADHD-friendly focus sounds using real-time DSP. No accounts, no analytics, no tracking.")
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HushPalette.textPrimary)
                }
            }
        }
    }
}
