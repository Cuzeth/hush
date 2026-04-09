import SwiftUI
import SwiftData

@main
struct HushApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([SavedPreset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fall back to in-memory store so the app remains usable after a
            // schema migration failure instead of entering a permanent crash loop.
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [fallback])
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
