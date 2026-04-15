import Foundation

// MARK: - Sound Category

enum SoundCategory: String, CaseIterable, Identifiable, Codable {
    case rain = "Rain"
    case ocean = "Ocean & Waves"
    case thunder = "Thunder & Storm"
    case fire = "Fire & Campfire"
    case wind = "Wind"
    case water = "Water"
    case birds = "Birds"
    case animals = "Animals"
    case places = "Places"
    case things = "Things"
    case transport = "Transport"
    case urban = "City & Urban"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rain: return "cloud.rain"
        case .ocean: return "tropicalstorm"
        case .thunder: return "cloud.bolt"
        case .fire: return "flame"
        case .wind: return "wind"
        case .water: return "drop.triangle"
        case .birds: return "bird"
        case .animals: return "pawprint"
        case .places: return "building.2"
        case .things: return "gearshape"
        case .transport: return "airplane"
        case .urban: return "car.fill"
        }
    }
}

// MARK: - License Attribution

enum SoundLicense: String, Codable {
    case cc0 = "CC0"
    case pixabay = "Pixabay Content License"
    case mit = "MIT (Moodist)"
    case userImported = "User Imported"
}

// MARK: - Crossfade Style

enum CrossfadeStyle: Codable {
    case stochastic   // 100ms — noisy/random sounds (rain, fire, wind, cafe)
    case rhythmic     // 300ms — tonal/periodic sounds (ocean waves, train)
    case percussive   // 50ms — transient/clicky sounds (clock, keyboard)
}

// MARK: - Sound Asset

struct SoundAsset: Identifiable, Codable, Hashable {
    let id: String               // Unique key, e.g. "moodist.rain.heavy-rain"
    let displayName: String      // Human-readable, title case
    let category: SoundCategory
    let fileName: String         // e.g. "heavy-rain"
    let fileExtension: String    // e.g. "mp3"
    let subdirectory: String     // e.g. "MoodistSounds/rain"
    let license: SoundLicense
    let crossfadeStyle: CrossfadeStyle
    let isMono: Bool

    /// Optional override for the per-asset SF Symbol. Only set for user
    /// imports today; bundled assets fall back to their category icon.
    let iconOverride: String?

    /// Absolute filesystem path for user-imported assets. When non-nil, the
    /// loader uses this directly instead of resolving via Bundle.
    let absolutePath: String?

    /// Per-asset crossfade override in milliseconds. Lets user imports pick
    /// any duration (or `0` for none) without inventing new `CrossfadeStyle`
    /// cases. Bundled assets leave this nil and inherit from `crossfadeStyle`.
    let crossfadeOverrideMs: Double?

    init(
        id: String,
        displayName: String,
        category: SoundCategory,
        fileName: String,
        fileExtension: String,
        subdirectory: String,
        license: SoundLicense,
        crossfadeStyle: CrossfadeStyle,
        isMono: Bool,
        iconOverride: String? = nil,
        absolutePath: String? = nil,
        crossfadeOverrideMs: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.subdirectory = subdirectory
        self.license = license
        self.crossfadeStyle = crossfadeStyle
        self.isMono = isMono
        self.iconOverride = iconOverride
        self.absolutePath = absolutePath
        self.crossfadeOverrideMs = crossfadeOverrideMs
    }

    var icon: String { iconOverride ?? category.icon }

    var isUserImported: Bool { absolutePath != nil }

    nonisolated var crossfadeDurationMs: Double {
        if let override = crossfadeOverrideMs { return override }
        switch crossfadeStyle {
        case .stochastic: return 100.0
        case .rhythmic: return 300.0
        case .percussive: return 50.0
        }
    }

    /// Resolved file URL: absolute path for user assets, bundle lookup for
    /// bundled ones. Returns nil if a bundled asset's file is missing.
    nonisolated var resolvedURL: URL? {
        if let absolutePath {
            let url = URL(fileURLWithPath: absolutePath)
            return FileManager.default.fileExists(atPath: absolutePath) ? url : nil
        }
        if let url = Bundle.main.url(
            forResource: fileName,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) { return url }
        return Bundle.main.url(forResource: fileName, withExtension: fileExtension)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SoundAsset, rhs: SoundAsset) -> Bool { lhs.id == rhs.id }
}

// MARK: - Asset Registry

enum SoundAssetRegistry {
    /// Bundled assets only — stable, always available.
    static let bundled: [SoundAsset] = sampleAssets + moodistAssets

    /// Hook the user library plugs into at app launch. Kept as a closure so
    /// the registry stays a stateless enum and tests can inject fixtures.
    /// The registry checks this only for IDs prefixed `user.`, so bundled
    /// lookups stay zero-cost.
    ///
    /// Convention: all callers go through main. We use `nonisolated(unsafe)`
    /// to match the surrounding codebase's pattern (audio engine asserts
    /// main thread; views are MainActor by default). The accessor methods
    /// below assert main-thread to trap accidental background callers in
    /// debug instead of risking a silent data race against `library.refresh()`.
    nonisolated(unsafe) static var userLookup: ((String) -> SoundAsset?)?
    nonisolated(unsafe) static var userAssetsProvider: (() -> [SoundAsset])?

    /// All known assets — bundled plus whatever the user library currently
    /// exposes. Used by category listings.
    static var all: [SoundAsset] {
        if userAssetsProvider != nil { assertMainThreadForUserAccess() }
        return bundled + (userAssetsProvider?() ?? [])
    }

    static func assets(for category: SoundCategory) -> [SoundAsset] {
        all.filter { $0.category == category }
    }

    static func asset(withID id: String) -> SoundAsset? {
        if id.hasPrefix("user.") {
            if userLookup != nil { assertMainThreadForUserAccess() }
            if let userAsset = userLookup?(id) { return userAsset }
            return nil
        }
        return bundled.first { $0.id == id }
    }

    /// Trips in debug if a user-asset lookup happens off main while the hook
    /// is wired — `library.refresh()` mutates `assetsByID` on main and the
    /// hook reads it. Skipped when the hook is nil (tests / pre-launch).
    /// Wrapped in `#if DEBUG` so a future background caller doesn't crash
    /// release builds; the data race is still real in either configuration,
    /// but a fatal in production is worse than the race itself.
    private static func assertMainThreadForUserAccess() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
    }

    // MARK: - Samples (Manual Downloads — CC0 / Pixabay)

    private static let sampleAssets: [SoundAsset] = [
        SoundAsset(id: "sample.rain.calming", displayName: "Calming Rain", category: .rain,
                   fileName: "liecio-calming-rain-257596", fileExtension: "mp3", subdirectory: "Samples",
                   license: .pixabay, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "sample.storm.rain-thunder", displayName: "Rain & Thunder", category: .thunder,
                   fileName: "freesound_community-rain-and-thunder-16705", fileExtension: "mp3", subdirectory: "Samples",
                   license: .cc0, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "sample.storm.thunder", displayName: "Thunder", category: .thunder,
                   fileName: "soundreality-thunder-sound-375727", fileExtension: "mp3", subdirectory: "Samples",
                   license: .pixabay, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "sample.fire.crackling", displayName: "Fire Crackling", category: .fire,
                   fileName: "soundreality-fire-crackling-sound-499636", fileExtension: "mp3", subdirectory: "Samples",
                   license: .pixabay, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "sample.fire.campfire", displayName: "Campfire", category: .fire,
                   fileName: "soundreality-fire-sound-334130", fileExtension: "mp3", subdirectory: "Samples",
                   license: .pixabay, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "sample.birds.morning", displayName: "Morning Birdsong", category: .birds,
                   fileName: "creative_spark-morning-birdsong-246402", fileExtension: "mp3", subdirectory: "Samples",
                   license: .pixabay, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "sample.birds.chirping", displayName: "Birds Chirping", category: .birds,
                   fileName: "freesound_community-birds-chirping-ambiance-26052", fileExtension: "mp3", subdirectory: "Samples",
                   license: .cc0, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "sample.things.clock", displayName: "Clock Ticking", category: .things,
                   fileName: "dragon-studio-slow-cinematic-clock-ticking-357979", fileExtension: "mp3", subdirectory: "Samples",
                   license: .pixabay, crossfadeStyle: .percussive, isMono: false),
    ]

    // MARK: - Moodist Sounds (MIT)

    private static let moodistAssets: [SoundAsset] = [
        // Rain
        SoundAsset(id: "moodist.rain.heavy", displayName: "Heavy Rain", category: .rain,
                   fileName: "heavy-rain", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.rain.light", displayName: "Light Rain", category: .rain,
                   fileName: "light-rain", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.rain.car-roof", displayName: "Rain on Car Roof", category: .rain,
                   fileName: "rain-on-car-roof", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.rain.leaves", displayName: "Rain on Leaves", category: .rain,
                   fileName: "rain-on-leaves", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.rain.tent", displayName: "Rain on Tent", category: .rain,
                   fileName: "rain-on-tent", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.rain.umbrella", displayName: "Rain on Umbrella", category: .rain,
                   fileName: "rain-on-umbrella", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.rain.window", displayName: "Rain on Window", category: .rain,
                   fileName: "rain-on-window", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.rain.thunder", displayName: "Thunderstorm", category: .thunder,
                   fileName: "thunder", fileExtension: "mp3", subdirectory: "MoodistSounds/rain",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),

        // Nature
        SoundAsset(id: "moodist.nature.campfire", displayName: "Campfire", category: .fire,
                   fileName: "campfire", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.nature.droplets", displayName: "Water Droplets", category: .water,
                   fileName: "droplets", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.nature.howling-wind", displayName: "Howling Wind", category: .wind,
                   fileName: "howling-wind", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.nature.jungle", displayName: "Jungle", category: .animals,
                   fileName: "jungle", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.nature.river", displayName: "River", category: .water,
                   fileName: "river", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.nature.walk-snow", displayName: "Walk in Snow", category: .things,
                   fileName: "walk-in-snow", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.nature.walk-gravel", displayName: "Walk on Gravel", category: .things,
                   fileName: "walk-on-gravel", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.nature.walk-leaves", displayName: "Walk on Leaves", category: .things,
                   fileName: "walk-on-leaves", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.nature.waterfall", displayName: "Waterfall", category: .water,
                   fileName: "waterfall", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.nature.waves", displayName: "Ocean Waves", category: .ocean,
                   fileName: "waves", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.nature.wind-trees", displayName: "Wind in Trees", category: .wind,
                   fileName: "wind-in-trees", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.nature.wind", displayName: "Wind", category: .wind,
                   fileName: "wind", fileExtension: "mp3", subdirectory: "MoodistSounds/nature",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),

        // Animals
        SoundAsset(id: "moodist.animals.beehive", displayName: "Beehive", category: .animals,
                   fileName: "beehive", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.animals.birds", displayName: "Birds", category: .birds,
                   fileName: "birds", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.animals.cat-purring", displayName: "Cat Purring", category: .animals,
                   fileName: "cat-purring", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .stochastic, isMono: true),
        SoundAsset(id: "moodist.animals.chickens", displayName: "Chickens", category: .animals,
                   fileName: "chickens", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.animals.cows", displayName: "Cows", category: .animals,
                   fileName: "cows", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.animals.crickets", displayName: "Crickets", category: .animals,
                   fileName: "crickets", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.animals.crows", displayName: "Crows", category: .animals,
                   fileName: "crows", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.animals.dog-barking", displayName: "Dog Barking", category: .animals,
                   fileName: "dog-barking", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.animals.frog", displayName: "Frogs", category: .animals,
                   fileName: "frog", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.animals.horse-gallop", displayName: "Horse Gallop", category: .animals,
                   fileName: "horse-gallop", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.animals.owl", displayName: "Owl", category: .animals,
                   fileName: "owl", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: true),
        SoundAsset(id: "moodist.animals.seagulls", displayName: "Seagulls", category: .animals,
                   fileName: "seagulls", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .stochastic, isMono: true),
        SoundAsset(id: "moodist.animals.sheep", displayName: "Sheep", category: .animals,
                   fileName: "sheep", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.animals.whale", displayName: "Whale", category: .animals,
                   fileName: "whale", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.animals.wolf", displayName: "Wolf", category: .animals,
                   fileName: "wolf", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: true),
        SoundAsset(id: "moodist.animals.woodpecker", displayName: "Woodpecker", category: .animals,
                   fileName: "woodpecker", fileExtension: "mp3", subdirectory: "MoodistSounds/animals",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),

        // Places
        SoundAsset(id: "moodist.places.airport", displayName: "Airport", category: .places,
                   fileName: "airport", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.cafe", displayName: "Cafe", category: .places,
                   fileName: "cafe", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.carousel", displayName: "Carousel", category: .places,
                   fileName: "carousel", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.places.church", displayName: "Church", category: .places,
                   fileName: "church", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: true),
        SoundAsset(id: "moodist.places.construction", displayName: "Construction Site", category: .urban,
                   fileName: "construction-site", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.bar", displayName: "Crowded Bar", category: .places,
                   fileName: "crowded-bar", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.laboratory", displayName: "Laboratory", category: .places,
                   fileName: "laboratory", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.laundry", displayName: "Laundry Room", category: .things,
                   fileName: "laundry-room", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.places.library", displayName: "Library", category: .places,
                   fileName: "library", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.night-village", displayName: "Night Village", category: .places,
                   fileName: "night-village", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.office", displayName: "Office", category: .places,
                   fileName: "office", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.restaurant", displayName: "Restaurant", category: .places,
                   fileName: "restaurant", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.subway", displayName: "Subway Station", category: .transport,
                   fileName: "subway-station", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.supermarket", displayName: "Supermarket", category: .places,
                   fileName: "supermarket", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.places.temple", displayName: "Temple", category: .places,
                   fileName: "temple", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.places.underwater", displayName: "Underwater", category: .ocean,
                   fileName: "underwater", fileExtension: "mp3", subdirectory: "MoodistSounds/places",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),

        // Things
        SoundAsset(id: "moodist.things.boiling-water", displayName: "Boiling Water", category: .things,
                   fileName: "boiling-water", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.things.bubbles", displayName: "Bubbles", category: .things,
                   fileName: "bubbles", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .stochastic, isMono: true),
        SoundAsset(id: "moodist.things.ceiling-fan", displayName: "Ceiling Fan", category: .things,
                   fileName: "ceiling-fan", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .stochastic, isMono: true),
        SoundAsset(id: "moodist.things.clock", displayName: "Clock", category: .things,
                   fileName: "clock", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .percussive, isMono: true),
        SoundAsset(id: "moodist.things.keyboard", displayName: "Keyboard Typing", category: .things,
                   fileName: "keyboard", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.things.paper", displayName: "Paper", category: .things,
                   fileName: "paper", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.things.singing-bowl", displayName: "Singing Bowl", category: .things,
                   fileName: "singing-bowl", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.things.slide-projector", displayName: "Slide Projector", category: .things,
                   fileName: "slide-projector", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.things.tuning-radio", displayName: "Tuning Radio", category: .things,
                   fileName: "tuning-radio", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .stochastic, isMono: true),
        SoundAsset(id: "moodist.things.typewriter", displayName: "Typewriter", category: .things,
                   fileName: "typewriter", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .percussive, isMono: false),
        SoundAsset(id: "moodist.things.vinyl", displayName: "Vinyl Crackle", category: .things,
                   fileName: "vinyl-effect", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.things.washing-machine", displayName: "Washing Machine", category: .things,
                   fileName: "washing-machine", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.things.wind-chimes", displayName: "Wind Chimes", category: .things,
                   fileName: "wind-chimes", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.things.windshield-wipers", displayName: "Windshield Wipers", category: .things,
                   fileName: "windshield-wipers", fileExtension: "mp3", subdirectory: "MoodistSounds/things",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),

        // Transport
        SoundAsset(id: "moodist.transport.airplane", displayName: "Airplane", category: .transport,
                   fileName: "airplane", fileExtension: "mp3", subdirectory: "MoodistSounds/transport",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.transport.inside-train", displayName: "Inside a Train", category: .transport,
                   fileName: "inside-a-train", fileExtension: "mp3", subdirectory: "MoodistSounds/transport",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.transport.rowing-boat", displayName: "Rowing Boat", category: .transport,
                   fileName: "rowing-boat", fileExtension: "mp3", subdirectory: "MoodistSounds/transport",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.transport.sailboat", displayName: "Sailboat", category: .transport,
                   fileName: "sailboat", fileExtension: "mp3", subdirectory: "MoodistSounds/transport",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.transport.submarine", displayName: "Submarine", category: .transport,
                   fileName: "submarine", fileExtension: "mp3", subdirectory: "MoodistSounds/transport",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.transport.train", displayName: "Train", category: .transport,
                   fileName: "train", fileExtension: "mp3", subdirectory: "MoodistSounds/transport",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),

        // Urban
        SoundAsset(id: "moodist.urban.ambulance", displayName: "Ambulance Siren", category: .urban,
                   fileName: "ambulance-siren", fileExtension: "mp3", subdirectory: "MoodistSounds/urban",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.urban.busy-street", displayName: "Busy Street", category: .urban,
                   fileName: "busy-street", fileExtension: "mp3", subdirectory: "MoodistSounds/urban",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.urban.crowd", displayName: "Crowd", category: .urban,
                   fileName: "crowd", fileExtension: "mp3", subdirectory: "MoodistSounds/urban",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.urban.fireworks", displayName: "Fireworks", category: .urban,
                   fileName: "fireworks", fileExtension: "mp3", subdirectory: "MoodistSounds/urban",
                   license: .mit, crossfadeStyle: .rhythmic, isMono: false),
        SoundAsset(id: "moodist.urban.highway", displayName: "Highway", category: .urban,
                   fileName: "highway", fileExtension: "mp3", subdirectory: "MoodistSounds/urban",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.urban.road", displayName: "Road", category: .urban,
                   fileName: "road", fileExtension: "mp3", subdirectory: "MoodistSounds/urban",
                   license: .mit, crossfadeStyle: .stochastic, isMono: false),
        SoundAsset(id: "moodist.urban.traffic", displayName: "Traffic", category: .urban,
                   fileName: "traffic", fileExtension: "mp3", subdirectory: "MoodistSounds/urban",
                   license: .mit, crossfadeStyle: .stochastic, isMono: true),
    ]
}
