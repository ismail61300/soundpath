import AppKit
import SwiftUI

/// UserDefaults keys for the Settings window.
enum PrefKey {
    static let appearance = "pref.appearance"
    static let accent = "pref.accent"
    static let menuBarIcon = "pref.menuBarIcon"
    static let latency = "pref.latency"
    static let superKeys = "pref.superVolumeKeys"
    static let shortcut = "pref.globalShortcut"
    static let softwareVolume = "pref.softwareVolume"
    static let stripColumns = "pref.stripColumns"
    static let onboardingDone = "pref.onboardingDone"
    /// Set once System Audio Recording was granted (the system gives no reliable way to read it back).
    static let audioPermissionGranted = "pref.audioPermissionGranted"
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    var titleKey: String { "set.theme.\(rawValue)" }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }
    /// `nil` = follow the system accent colour.
    var color: Color? {
        switch self {
        case .system: return nil
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .graphite: return .gray
        }
    }
    var titleKey: String { "set.accent.\(rawValue)" }
}

enum MenuBarIconChoice: String, CaseIterable, Identifiable {
    /// Speaker symbol that follows the output volume (slash when muted, 1–3 waves otherwise).
    case volume = "volume.auto"
    case sliders = "slider.vertical.3"
    case speaker = "speaker.wave.2.fill"
    case hifi = "hifispeaker.fill"
    case waveform = "waveform"
    case note = "music.note"
    var id: String { rawValue }
    /// SF Symbol shown in the picker.
    var previewSymbol: String { self == .volume ? "speaker.wave.2.fill" : rawValue }

    /// Speaker symbol for a volume level.
    static func volumeSymbol(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var titleKey: String {
        switch self {
        case .volume: return "set.icon.volume"
        case .sliders: return "set.icon.sliders"
        case .speaker: return "set.icon.speaker"
        case .hifi: return "set.icon.hifi"
        case .waveform: return "set.icon.waveform"
        case .note: return "set.icon.note"
        }
    }
}

/// Maps the Settings latency slider (0 = lowest latency … 1 = most reliable) to audio parameters.
enum LatencySetting {
    static let defaultValue = 0.5
    /// Output-device I/O buffer size: 128 … 2048 frames.
    static func deviceFrames(_ x: Double) -> UInt32 { UInt32(128) << UInt32(max(0, min(4, (x * 4).rounded()))) }
    /// Ring-buffer prefill / skip-ahead limit (frames).
    static func ring(_ x: Double) -> (target: Int, max: Int) {
        let target = Int(deviceFrames(x)) * 2
        return (target, target * 4)
    }
}

/// A recorded global keyboard shortcut (Carbon modifier mask).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static func load() -> Shortcut? {
        guard let json = UserDefaults.standard.string(forKey: PrefKey.shortcut), !json.isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    var json: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

struct AppThemeModifier: ViewModifier {
    @AppStorage(PrefKey.accent) private var accent = AccentChoice.system.rawValue
    func body(content: Content) -> some View {
        content.tint(AccentChoice(rawValue: accent)?.color)
    }
}

extension View {
    /// Applies the user's accent-colour choice.
    func appTheme() -> some View { modifier(AppThemeModifier()) }
}

private struct OpenSettingsKey: EnvironmentKey { static let defaultValue: @MainActor () -> Void = {} }
extension EnvironmentValues {
    var openSettingsWindow: @MainActor () -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

private struct OpenDevicesKey: EnvironmentKey { static let defaultValue: @MainActor () -> Void = {} }
extension EnvironmentValues {
    var openAudioDevicesWindow: @MainActor () -> Void {
        get { self[OpenDevicesKey.self] }
        set { self[OpenDevicesKey.self] = newValue }
    }
}
