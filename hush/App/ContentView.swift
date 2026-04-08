import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var viewModel = PlayerViewModel()
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
    ContentView()
        .modelContainer(for: SavedPreset.self, inMemory: true)
}
