import Foundation
import Observation

/// Per-audio-device preferences (keyed by device UID).
struct DeviceSettings: Codable, Equatable {
    var nickname = ""
    var icon: String?
    var hidden = false
    /// When off, SoundPath leaves audio to this device untouched (no muting, volume or effects).
    var processing = true
    var forceSoftwareVolume = false
    /// Output volume ceiling (0…1).
    var maxVolume: Float = 1
    /// -1 (left) … 1 (right).
    var balance: Float = 0
    /// "Balance" effect card shown in the Output FX panel, and whether it is switched on.
    var balanceCard = false
    var balanceOn = true
    var inLeft = 1, inRight = 2
    var outLeft = 1, outRight = 2
    var lockVolume = false, lockMute = false, lockSampleRate = false
    var lockedVolume: Float = 1
    var lockedMute = false
    var lockedRate: Double = 0
    /// Shortcut actions, keyed by `DeviceAction.rawValue`.
    var shortcuts: [String: Shortcut] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        processing = try c.decodeIfPresent(Bool.self, forKey: .processing) ?? true
        forceSoftwareVolume = try c.decodeIfPresent(Bool.self, forKey: .forceSoftwareVolume) ?? false
        maxVolume = try c.decodeIfPresent(Float.self, forKey: .maxVolume) ?? 1
        balance = try c.decodeIfPresent(Float.self, forKey: .balance) ?? 0
        balanceCard = try c.decodeIfPresent(Bool.self, forKey: .balanceCard) ?? false
        balanceOn = try c.decodeIfPresent(Bool.self, forKey: .balanceOn) ?? true
        inLeft = try c.decodeIfPresent(Int.self, forKey: .inLeft) ?? 1
        inRight = try c.decodeIfPresent(Int.self, forKey: .inRight) ?? 2
        outLeft = try c.decodeIfPresent(Int.self, forKey: .outLeft) ?? 1
        outRight = try c.decodeIfPresent(Int.self, forKey: .outRight) ?? 2
        lockVolume = try c.decodeIfPresent(Bool.self, forKey: .lockVolume) ?? false
        lockMute = try c.decodeIfPresent(Bool.self, forKey: .lockMute) ?? false
        lockSampleRate = try c.decodeIfPresent(Bool.self, forKey: .lockSampleRate) ?? false
        lockedVolume = try c.decodeIfPresent(Float.self, forKey: .lockedVolume) ?? 1
        lockedMute = try c.decodeIfPresent(Bool.self, forKey: .lockedMute) ?? false
        lockedRate = try c.decodeIfPresent(Double.self, forKey: .lockedRate) ?? 0
        shortcuts = try c.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts) ?? [:]
    }
}

/// What a device shortcut does.
enum DeviceAction: String, CaseIterable, Identifiable {
    case setInput, toggleInputMute, inputVolumeDown, inputVolumeUp
    case setOutput, toggleOutputMute, outputVolumeDown, outputVolumeUp
    var id: String { rawValue }
    var isInput: Bool {
        switch self {
        case .setInput, .toggleInputMute, .inputVolumeDown, .inputVolumeUp: return true
        default: return false
        }
    }
    var titleKey: String { "dev.sc.\(rawValue)" }
}

@MainActor @Observable
final class DeviceSettingsStore {
    private var cache: [String: DeviceSettings]
    private(set) var outputOrder: [String]
    private(set) var inputOrder: [String]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private enum Key {
        static let settings = "deviceSettings.v1"
        static let outOrder = "deviceOrder.out.v1"
        static let inOrder = "deviceOrder.in.v1"
    }

    init() {
        let defaults = UserDefaults.standard
        cache = defaults.data(forKey: Key.settings).flatMap { try? JSONDecoder().decode([String: DeviceSettings].self, from: $0) } ?? [:]
        outputOrder = defaults.stringArray(forKey: Key.outOrder) ?? []
        inputOrder = defaults.stringArray(forKey: Key.inOrder) ?? []
    }

    subscript(uid: String) -> DeviceSettings {
        get { cache[uid] ?? DeviceSettings() }
        set {
            guard newValue != self[uid] else { return }
            if newValue == DeviceSettings() { cache[uid] = nil } else { cache[uid] = newValue }
            scheduleSave()
            onChange?()
        }
    }

    func setOrder(output: [String]? = nil, input: [String]? = nil) {
        if let output { outputOrder = output }
        if let input { inputOrder = input }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Key.settings) }
        defaults.set(outputOrder, forKey: Key.outOrder)
        defaults.set(inputOrder, forKey: Key.inOrder)
    }
}
