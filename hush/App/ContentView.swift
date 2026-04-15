import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var viewModel = PlayerViewModel()
    @Environment(UserSoundLibrary.self) private var userSoundLibrary
    @AppStorage("autoResumeLast") private var autoResumeLast = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

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
        .preferredColorScheme(.dark)
        .onAppear {
            AudioEngine.shared.configureAudioSession()
            viewModel.bindUserSoundLibrary(userSoundLibrary)
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
