import SwiftUI

struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                List {
                    Section {
                        Text("Hush is free and open source software (GPL v3)")
                            .font(.subheadline)
                            .foregroundStyle(HushPalette.textPrimary)
                    }

                    Section("Sound Credits") {
                        VStack(alignment: .leading, spacing: 10) {
                            creditRow(
                                text: "Some sounds sourced from Moodist (moodist.mvze.net)",
                                detail: "MIT License"
                            )

                            if let url = URL(string: "https://github.com/remvze/moodist") {
                                Link(destination: url) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "link")
                                            .font(.caption)
                                        Text("Moodist on GitHub")
                                            .font(.subheadline)
                                    }
                                    .foregroundStyle(HushPalette.accentSoft)
                                }
                            }
                        }

                        creditRow(
                            text: "Sounds licensed under the Pixabay Content License",
                            detail: "Free for commercial use, no attribution required"
                        )

                        creditRow(
                            text: "Sounds licensed under CC0 (Creative Commons Zero)",
                            detail: "Public domain"
                        )
                    }

                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .foregroundStyle(HushPalette.textPrimary)
            }
            .navigationTitle("Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HushPalette.textPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private func creditRow(text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(HushPalette.textPrimary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(HushPalette.textSecondary)
        }
    }
}
