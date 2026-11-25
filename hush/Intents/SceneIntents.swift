import AppIntents

// Siri and Shortcuts: "Play <scene> in Hush" starts any scene in the user's
// list, built-in or saved. The intent runs in the app process. When Hush
// isn't running, the system launches it in the background, HushApp.init
// registers the PlayerViewModel, and audio starts with no window.
//
// The intent and query keep the target's default MainActor isolation:
// `nonisolated` on a type with `@Parameter`/`@Dependency` wrappers is a
// Swift 6 error. Plain value types (entity, error, provider) are
// `nonisolated`.

// MARK: - Scene entity

nonisolated struct SceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static var defaultQuery: SceneQuery { SceneQuery() }

    let id: UUID
    let name: String
    let icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }

    @MainActor
    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        icon = preset.icon
    }
}

struct SceneQuery: EntityStringQuery {
    @Dependency private var player: PlayerViewModel

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SceneEntity] {
        let scenes = player.resolvedScenes()
        return identifiers.compactMap { id in
            scenes.first { $0.id == id }.map(SceneEntity.init)
        }
    }

    /// The scene list in the user's order, for the Shortcuts picker and
    /// Siri's "Which scene?" follow-up.
    @MainActor
    func suggestedEntities() async throws -> [SceneEntity] {
        player.resolvedScenes().map(SceneEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SceneEntity] {
        Self.scenes(matching: string, in: player.resolvedScenes()).map(SceneEntity.init)
    }

    /// Scenes whose name contains `query`, ignoring case and diacritics, so
    /// "cafe" finds "Café". An exact name match sorts first, so "Focus"
    /// picks Focus over Gamma Focus. Internal for tests.
    @MainActor
    static func scenes(matching query: String, in scenes: [Preset]) -> [Preset] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let matches = scenes.filter { $0.name.localizedStandardContains(query) }
        let exact = matches.filter {
            $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let exactIDs = Set(exact.map(\.id))
        return exact + matches.filter { !exactIDs.contains($0.id) }
    }
}

// MARK: - Play Scene

struct PlaySceneIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Scene"
    static let description = IntentDescription("Starts playing one of your Hush scenes.")

    @Parameter(title: "Scene")
    var scene: SceneEntity

    @Dependency private var player: PlayerViewModel

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$scene)")
    }

    init() {}

    init(scene: SceneEntity) {
        self.scene = scene
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard player.playScene(id: scene.id) != nil else {
            throw SceneIntentError.sceneNotFound(name: scene.name)
        }
        // No spoken dialog: Siri talking over the sound it just started
        // would be the first thing the user hears.
        return .result()
    }
}

nonisolated enum SceneIntentError: Error, CustomLocalizedStringResourceConvertible {
    case sceneNotFound(name: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sceneNotFound(let name):
            "\(name) isn't in your Hush scenes anymore."
        }
    }
}

// MARK: - App Shortcuts

/// Siri phrases that work with no setup. Every phrase must name the app.
/// Scene names in phrases come from `SceneQuery.suggestedEntities()` and
/// refresh when `updateAppShortcutParameters()` runs (launch and
/// backgrounding).
nonisolated struct HushShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySceneIntent(),
            phrases: [
                "Play \(\.$scene) in \(.applicationName)",
                "Start \(\.$scene) in \(.applicationName)",
                "Play \(\.$scene) on \(.applicationName)",
                "Play a scene in \(.applicationName)",
                "Start a scene in \(.applicationName)",
            ],
            shortTitle: "Play Scene",
            systemImageName: "play.circle.fill"
        )
    }
}
