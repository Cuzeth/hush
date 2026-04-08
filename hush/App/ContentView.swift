import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var viewModel = PlayerViewModel()
    @AppStorage("autoResumeLast") private var autoResumeLast = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        PlayerView(viewModel: viewModel)
            .preferredColorScheme(.dark)
            .onAppear {
                AudioEngine.shared.configureAudioSession()
                if autoResumeLast {
                    _ = viewModel.restoreLastSession()
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
