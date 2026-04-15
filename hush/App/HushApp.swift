import SwiftUI
import SwiftData

@main
struct HushApp: App {
    let sharedModelContainer: ModelContainer
    @State private var userSoundLibrary: UserSoundLibrary

    init() {
        let schema = Schema([SavedPreset.self, UserSoundAsset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fall back to in-memory store so the app remains usable after a
            // schema migration failure instead of entering a permanent crash loop.
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: [fallback])
        }
        self.sharedModelContainer = container

        let library = UserSoundLibrary(modelContext: ModelContext(container))
        library.verify()
        _userSoundLibrary = State(initialValue: library)

        // Wire the registry hook BEFORE any view materializes — built-in
        // presets are decoded eagerly and may resolve user assets if the
        // user has saved presets that reference them.
        SoundAssetRegistry.userLookup = { [weak library] id in
            library?.asset(withID: id)
        }
        SoundAssetRegistry.userAssetsProvider = { [weak library] in
            library?.allSoundAssets ?? []
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(userSoundLibrary)
        }
        .modelContainer(sharedModelContainer)
    }
}
