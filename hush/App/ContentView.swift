import SwiftUI
import SwiftData
import UIKit
import AppIntents

struct ContentView: View {
    /// Owned by HushApp so shortcuts can drive it with no window open.
    let viewModel: PlayerViewModel
    @Environment(UserSoundLibrary.self) private var userSoundLibrary
    @Environment(\.modelContext) private var modelContext
    /// Optional so `#Preview` and any other host that doesn't run the launch
    /// sequence can still mount this view.
    @Environment(LaunchCoordinator.self) private var launchCoordinator: LaunchCoordinator?
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
    /// Same one-shot treatment for auto-resume: a re-fired onAppear must not
    /// overwrite a session the user has since paused or changed.
    @State private var autoResumeAttempted = false

    init(viewModel: PlayerViewModel, storageFailureMessage: String? = nil) {
        self.viewModel = viewModel
        self.storageFailureMessage = storageFailureMessage
    }

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                PlayerView(viewModel: viewModel)
            } else {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
        }
        .onAppear {
            AudioEngine.shared.configureAudioSession()
            viewModel.bindUserSoundLibrary(userSoundLibrary)
            // SavedPresets for remote next/previous and session restore —
            // the same main context the selector's @Query reads.
            viewModel.bindModelContext(modelContext)
            if let storageFailureMessage, !storageFailureSurfaced {
                viewModel.storageFailureMessage = storageFailureMessage
                storageFailureSurfaced = true
            }
            if hasCompletedOnboarding && autoResumeLast && !autoResumeAttempted {
                autoResumeAttempted = true
                if viewModel.restoreLastSession() {
                    viewModel.play()
                }
            }
            viewModel.handleScenePhaseChange(.active)
            applyAppearance(appearance)
            // The first screen is mounted. The launch overlay holds its final
            // frame until this lands, then cuts away. Idempotent, because this
            // onAppear re-fires when the Group swaps views or the scene resumes.
            launchCoordinator?.markFirstScreenReady()
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
            if newPhase == .active { applyAppearance(appearance) }
            // Scenes added, renamed, or hidden this session become
            // speakable in Siri phrases ("Play Rainy Day in Hush").
            if newPhase == .background { HushShortcuts.updateAppShortcutParameters() }
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
    return ContentView(viewModel: PlayerViewModel())
        .modelContainer(container)
        .environment(UserSoundLibrary(modelContext: ModelContext(container)))
}
