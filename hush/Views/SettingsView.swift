import SwiftUI

struct SettingsView: View {
    @AppStorage("autoResumeLast") private var autoResumeLast = false
    @AppStorage("fadeDuration") private var fadeDuration: Double = 0.5
    @AppStorage("binauralCarrier") private var binauralCarrier: Double = 200

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    Toggle("Auto-resume last session", isOn: $autoResumeLast)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Fade duration")
                            Spacer()
                            Text("\(fadeDuration, specifier: "%.1f")s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $fadeDuration, in: 0.1...2.0, step: 0.1)
                    }
                }

                Section("Binaural Beats") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Carrier frequency")
                            Spacer()
                            Text("\(Int(binauralCarrier)) Hz")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $binauralCarrier, in: 100...500, step: 10)
                    }

                    HStack {
                        Image(systemName: "headphones")
                            .foregroundStyle(.secondary)
                        Text(AudioEngine.headphonesConnected ? "Headphones connected" : "No headphones detected")
                            .font(.subheadline)
                            .foregroundStyle(AudioEngine.headphonesConnected ? .green : .secondary)
                    }
                }

                Section("Audio") {
                    HStack {
                        Text("Sample rate")
                        Spacer()
                        Text("44,100 Hz")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Bit depth")
                        Spacer()
                        Text("32-bit float")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("License")
                        Spacer()
                        Text("GPL v3")
                            .foregroundStyle(.secondary)
                    }
                    Text("Hush generates ADHD-friendly focus sounds using real-time DSP. No accounts, no analytics, no tracking.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
