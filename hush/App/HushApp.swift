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
            do {
                let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                // In-memory container creation failing means SwiftData itself
                // is broken — there's no degraded mode left to offer. Crash
                // with a diagnosable message instead of a bare `try!`.
                appLogger.critical("In-memory ModelContainer fallback failed: \(error.localizedDescription)")
                fatalError("In-memory ModelContainer fallback failed: \(error)")
            }
            failureMessage = "Hush couldn't open your saved data. Your presets and imports won't load this session, and changes won't persist. Please report this if it keeps happening."
        }
        self.sharedModelContainer = container
        self.storageFailureMessage = failureMessage

        let library = UserSoundLibrary(modelContext: ModelContext(container))
        library.verify()
        // Edited/relinked/deleted imports must drop their pre-baked loop
        // buffer, or the engine keeps playing audio baked from the old file
        // until app restart.
        library.onAssetContentChanged = { assetID in
            AudioEngine.shared.invalidateCachedBuffer(assetID: assetID)
        }
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
