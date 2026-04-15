import SwiftUI
import SwiftData
import os.log

private let appLogger = Logger(subsystem: "dev.abdeen.hush", category: "HushApp")

@main
struct HushApp: App {
    let sharedModelContainer: ModelContainer
    @State private var userSoundLibrary: UserSoundLibrary
    /// Set when ModelContainer creation falls back to an in-memory store —
    /// presets and imports won't persist this session, and the user needs to
    /// know that. Surfaced as an alert via PlayerViewModel.errorMessage.
    private let storageFailureMessage: String?

    init() {
        let schema = Schema([SavedPreset.self, UserSoundAsset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        var failureMessage: String? = nil
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fall back to in-memory store so the app remains usable after a
            // schema migration failure instead of entering a permanent crash loop.
            appLogger.error("ModelContainer failed, using in-memory fallback: \(error.localizedDescription)")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: [fallback])
            failureMessage = "Hush couldn't open your saved data. Your presets and imports won't load this session, and changes won't persist. Please report this if it keeps happening."
        }
        self.sharedModelContainer = container
        self.storageFailureMessage = failureMessage

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
            ContentView(storageFailureMessage: storageFailureMessage)
                .environment(userSoundLibrary)
        }
        .modelContainer(sharedModelContainer)
    }
}
