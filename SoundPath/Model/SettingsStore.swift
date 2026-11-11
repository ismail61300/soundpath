import Foundation

struct OverdriveSettings: Codable, Equatable {
    var enabled = true
    /// Linear amplitude multiplier: 1x…4x (4x ≈ +12 dB).
    var multiplier: Int = 2

    static let range = 1...4
    var gainDB: Float { multiplier <= 1 ? 0 : 20 * log10(Float(multiplier)) }
}

struct MagicBoostSettings: Codable, Equatable {
    var enabled = true
    /// 0…1 – how hard quiet passages are lifted.
    var strength: Float = 0.5
}

/// Per-app settings, persisted by app key (bundle ID), never by PID.
/// Effects are optional: `nil` = not added to the app's FX chain.
struct AppSettings: Codable, Equatable {
    var volume: Float = 1.0
    var muted = false
    var overdrive: OverdriveSettings?
    var eq: EQSettings?
    var magicBoost: MagicBoostSettings?
    /// UID of the output device this app is redirected to; `nil` = system default output.
    var outputDeviceUID: String?
    /// Optional third-party Audio Unit effect inserted before the built-in effects.
    var plugin: AUPluginSettings?

    static let `default` = AppSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        overdrive = try c.decodeIfPresent(OverdriveSettings.self, forKey: .overdrive)
        eq = try c.decodeIfPresent(EQSettings.self, forKey: .eq)
        magicBoost = try c.decodeIfPresent(MagicBoostSettings.self, forKey: .magicBoost)
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        plugin = try c.decodeIfPresent(AUPluginSettings.self, forKey: .plugin)
    }

    var overdriveActive: Bool { overdrive.map { $0.enabled && $0.multiplier > 1 } ?? false }
    var eqActive: Bool { eq.map { $0.enabled && !$0.isNeutral } ?? false }
    var magicBoostActive: Bool { magicBoost?.enabled ?? false }
    var pluginActive: Bool { plugin?.enabled ?? false }
    var anyEffectActive: Bool { overdriveActive || eqActive || magicBoostActive || pluginActive }
    var hasEffects: Bool { overdrive != nil || eq != nil || magicBoost != nil || plugin != nil }

    /// True when the app sounds different from "untouched", so its tap must stay alive
    /// even while it is momentarily silent (avoids a loud blip when playback resumes).
    var needsPersistentTap: Bool { volume != 1 || muted || anyEffectActive || outputDeviceUID != nil }
}

struct FavoriteApp: Codable, Equatable, Identifiable {
    let id: String // bundle ID
    var name: String
}

/// A saved snapshot of every app's settings (and the master "Output" FX), restorable in one click.
struct QuickConfig: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var apps: [String: AppSettings]
}

/// JSON-in-UserDefaults store with debounced writes.
@MainActor
final class SettingsStore {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let apps = "appSettings.v1"
        static let favorites = "favorites.v1"
        static let presets = "eqUserPresets.v1"
        static let configs = "quickConfigs.v1"
        static let excluded = "excludedApps.v1"
    }

    private var cache: [String: AppSettings]
    private(set) var favorites: [FavoriteApp]
    private(set) var userPresets: [EQPreset]
    private(set) var quickConfigs: [QuickConfig]
    /// Apps SoundPath never taps or lists (default: VoiceOver, so its speech is never delayed or muted).
    private(set) var excluded: [FavoriteApp]
    private var saveWork: DispatchWorkItem?

    init() {
        cache = Self.load([String: AppSettings].self, Key.apps) ?? [:]
        favorites = Self.load([FavoriteApp].self, Key.favorites) ?? []
        userPresets = Self.load([EQPreset].self, Key.presets) ?? []
        quickConfigs = Self.load([QuickConfig].self, Key.configs) ?? []
        excluded = Self.load([FavoriteApp].self, Key.excluded) ?? [FavoriteApp(id: "com.apple.VoiceOver", name: "VoiceOver")]
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    subscript(appID: String) -> AppSettings {
        get { cache[appID] ?? .default }
        set {
            if newValue == .default { cache[appID] = nil } else { cache[appID] = newValue }
            scheduleSave()
        }
    }

    // MARK: Excluded apps

    func addExcluded(_ app: FavoriteApp) {
        guard !excluded.contains(where: { $0.id == app.id }) else { return }
        excluded.append(app)
        scheduleSave()
    }

    func removeExcluded(_ id: String) {
        excluded.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Quick configs

    var allAppSettings: [String: AppSettings] { cache }

    func replaceAppSettings(_ settings: [String: AppSettings]) {
        cache = settings.filter { $0.value != .default }
        scheduleSave()
    }

    func addQuickConfig(_ config: QuickConfig) {
        quickConfigs.append(config)
        scheduleSave()
    }

    func deleteQuickConfig(_ id: String) {
        quickConfigs.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Favorites

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func addFavorite(_ fav: FavoriteApp) {
        guard !isFavorite(fav.id) else { return }
        favorites.append(fav)
        scheduleSave()
    }

    func removeFavorite(_ id: String) {
        favorites.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: EQ presets

    var allPresets: [EQPreset] { EQPreset.builtIns + userPresets }

    func preset(id: String?) -> EQPreset? {
        guard let id else { return nil }
        return allPresets.first { $0.id == id }
    }

    func addPreset(_ preset: EQPreset) {
        userPresets.append(preset)
        scheduleSave()
    }

    func renamePreset(_ id: String, to name: String) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[index].name = name
        scheduleSave()
    }

    func deletePreset(_ id: String) {
        userPresets.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        let encoder = JSONEncoder()
        if let d = try? encoder.encode(cache) { defaults.set(d, forKey: Key.apps) }
        if let d = try? encoder.encode(favorites) { defaults.set(d, forKey: Key.favorites) }
        if let d = try? encoder.encode(userPresets) { defaults.set(d, forKey: Key.presets) }
        if let d = try? encoder.encode(quickConfigs) { defaults.set(d, forKey: Key.configs) }
        if let d = try? encoder.encode(excluded) { defaults.set(d, forKey: Key.excluded) }
    }

    func flush() {
        saveWork?.cancel()
        save()
    }
}
