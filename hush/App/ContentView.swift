import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var viewModel = PlayerViewModel()
    @AppStorage("autoResumeLast") private var autoResumeLast = false

    var body: some View {
        PlayerView(viewModel: viewModel)
            .preferredColorScheme(.dark)
            .onAppear {
                AudioEngine.shared.configureAudioSession()
                if autoResumeLast {
                    _ = viewModel.restoreLastSession()
                }
            }
            .onDisappear {
                viewModel.saveLastSession()
            }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedPreset.self, inMemory: true)
}
