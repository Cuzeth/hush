import SwiftUI
import SwiftData
import UIKit

struct ContentView: View {
    @State private var viewModel = PlayerViewModel()
    @Environment(UserSoundLibrary.self) private var userSoundLibrary
    @AppStorage("autoResumeLast") private var autoResumeLast = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appearance") private var appearanceRaw: String = Appearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var appearance: Appearance {
        Appearance(rawValue: appearanceRaw) ?? .system
    }
    let storageFailureMessage: String?
    /// One-shot per launch — guarantees the storage-failure alert fires once
    /// even though `.onAppear` can re-fire when the Group switches between
    /// OnboardingView and PlayerView (or on scene resume).
    @State private var storageFailureSurfaced = false

    init(storageFailureMessage: String? = nil) {
        self.storageFailureMessage = storageFailureMessage
    }

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                PlayerView(viewModel: viewModel)
            } else {
                OnboardingView { selectedPreset in
                    hasCompletedOnboarding = true
                    if let preset = selectedPreset {
                        viewModel.loadPreset(preset)
                    }
                }
            }
        }
        .onAppear {
            AudioEngine.shared.configureAudioSession()
            viewModel.bindUserSoundLibrary(userSoundLibrary)
            if let storageFailureMessage, !storageFailureSurfaced {
                viewModel.storageFailureMessage = storageFailureMessage
                storageFailureSurfaced = true
            }
            if hasCompletedOnboarding && autoResumeLast {
                if viewModel.restoreLastSession() {
                    viewModel.play()
                }
            }
            viewModel.handleScenePhaseChange(.active)
            applyAppearance(appearance)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
            if newPhase == .active { applyAppearance(appearance) }
        }
        .onChange(of: appearanceRaw) { _, _ in
            applyAppearance(appearance)
        }
    }

    /// Propagate the user's appearance choice to every window in the active
    /// scene via `overrideUserInterfaceStyle`. Plain `.preferredColorScheme`
    /// on the root view doesn't cross into sheet presentations, which is why
    /// flipping the picker in Settings used to require closing the sheet.
    private func applyAppearance(_ appearance: Appearance) {
        let style: UIUserInterfaceStyle
        switch appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

#Preview {
    let schema = Schema([SavedPreset.self, UserSoundAsset.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    return ContentView()
        .modelContainer(container)
        .environment(UserSoundLibrary(modelContext: ModelContext(container)))
}
