import SwiftUI
import SwiftData

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
        .preferredColorScheme(appearance.colorScheme)
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
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
