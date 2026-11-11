import AppKit
import CoreAudio
import Observation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    var inChannels = 0
    var outChannels = 0
    var transport: UInt32 = 0
    var isInput: Bool { inChannels > 0 }
    var isOutput: Bool { outChannels > 0 }

    /// Connection type shown next to the output (name, SF Symbol).
    var connection: (name: String, symbol: String) {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return ("Built-in", "laptopcomputer")
        case kAudioDeviceTransportTypeUSB: return ("USB", "cable.connector")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return ("Bluetooth", "dot.radiowaves.right")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return ("HDMI / DisplayPort", "display")
        case kAudioDeviceTransportTypeAirPlay: return ("AirPlay", "airplayaudio")
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire:
            return ("Thunderbolt / FireWire", "cable.connector.horizontal")
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return ("Virtual", "square.stack.3d.up")
        default: return ("Other", "speaker.wave.2")
        }
    }
}

/// Mac-wide audio state: default output / input / system-sound devices, their volumes and
/// per-device preferences (nicknames, hiding, limits, locks, shortcuts, preferred order).
@MainActor @Observable
final class SystemAudio {
    /// Every device (inputs, outputs and both), for the Audio Devices window.
    private(set) var allDevices: [AudioDeviceInfo] = []
    private(set) var outputDevices: [AudioDeviceInfo] = []
    private(set) var inputDevices: [AudioDeviceInfo] = []
    private(set) var outputID: AudioObjectID = .unknown
    private(set) var inputID: AudioObjectID = .unknown
    private(set) var systemOutputID: AudioObjectID = .unknown

    private(set) var outputVolume: Float = 0
    private(set) var outputMuted = false
    private(set) var outputHasHardwareVolume = false
    private(set) var inputVolume: Float = 0
    private(set) var inputMuted = false
    private(set) var inputHasVolume = false
    private(set) var alertVolume: Float = 1

    let deviceSettings = DeviceSettingsStore()

    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []
    /// Called whenever any device preference changes (the engine re-applies balance / channel routing).
    @ObservationIgnored var onDeviceSettingsChanged: (() -> Void)?

    init() {
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
        systemListeners = selectors.map { selector in
            PropertyListener(object: .system, address: AudioObjectPropertyAddress(selector)) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        deviceSettings.onChange = { [weak self] in
            self?.syncShortcuts()
            self?.onDeviceSettingsChanged?()
        }
        refresh()
        refreshAlertVolume()
        syncShortcuts()
    }

    // MARK: Device lookup helpers (nicknames, hiding, icons)

    func settings(for device: AudioDeviceInfo) -> DeviceSettings { deviceSettings[device.uid] }

    func displayName(_ device: AudioDeviceInfo) -> String {
        let nick = deviceSettings[device.uid].nickname.trimmingCharacters(in: .whitespaces)
        return nick.isEmpty ? device.name : nick
    }

    func symbol(_ device: AudioDeviceInfo) -> String {
        deviceSettings[device.uid].icon ?? DeviceSymbol.name(for: device.name)
    }

    /// Devices offered in pickers: hidden ones are left out (the current default is always kept).
    var visibleOutputDevices: [AudioDeviceInfo] {
        outputDevices.filter { !deviceSettings[$0.uid].hidden || $0.id == outputID }
    }
    var visibleInputDevices: [AudioDeviceInfo] {
        inputDevices.filter { !deviceSettings[$0.uid].hidden || $0.id == inputID }
    }

    func device(uid: String) -> AudioDeviceInfo? { allDevices.first { $0.uid == uid } }

    var outputUID: String { outputID.deviceUID ?? "" }

    /// Hardware volume, unless the user forced software volume for the current output device.
    var outputHasVolume: Bool {
        outputHasHardwareVolume && !deviceSettings[outputUID].forceSoftwareVolume
    }

    // MARK: Reading

    func refresh() {
        let ids = (try? AudioObjectID.system.readArray(AudioObjectPropertyAddress(kAudioHardwarePropertyDevices),
                                                       of: AudioObjectID.self)) ?? []
        let devices: [AudioDeviceInfo] = ids.compactMap { id in
            guard let uid = id.deviceUID, let name = id.name else { return nil }
            // Hide CoreAudio / SoundPath internals: the private aggregates created for process taps.
            guard !name.hasPrefix("CADefaultDeviceAggregate"), !name.hasPrefix("SoundPath –") else { return nil }
            let ins = id.channelCount(scope: kAudioObjectPropertyScopeInput)
            let outs = id.channelCount(scope: kAudioObjectPropertyScopeOutput)
            guard ins > 0 || outs > 0 else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: name, inChannels: ins, outChannels: outs,
                                   transport: id.transportType)
        }
        if devices != allDevices { allDevices = devices }
        let outs = devices.filter(\.isOutput)
        let ins = devices.filter(\.isInput)
        if outs != outputDevices { outputDevices = outs }
        if ins != inputDevices { inputDevices = ins }

        outputID = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        inputID = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        systemOutputID = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
        readVolumes()
        watchDeviceVolumes()
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        (try? AudioObjectID.system.read(AudioObjectPropertyAddress(selector), default: AudioObjectID.unknown)) ?? .unknown
    }

    private func readVolumes() {
        let out = readVolume(outputID, scope: kAudioObjectPropertyScopeOutput)
        outputHasHardwareVolume = out != nil
        outputVolume = out ?? 0
        outputMuted = readMute(outputID, scope: kAudioObjectPropertyScopeOutput)
        let inp = readVolume(inputID, scope: kAudioObjectPropertyScopeInput)
        inputHasVolume = inp != nil
        inputVolume = inp ?? 0
        inputMuted = readMute(inputID, scope: kAudioObjectPropertyScopeInput)
        enforceLimits()
    }

    /// Output volume ceiling and "global lock" settings for the default devices.
    private func enforceLimits() {
        if let uid = outputID.deviceUID {
            let s = deviceSettings[uid]
            if outputHasHardwareVolume {
                if s.lockVolume, abs(outputVolume - s.lockedVolume) > 0.01 {
                    write(volume: s.lockedVolume, device: outputID, scope: kAudioObjectPropertyScopeOutput)
                    outputVolume = s.lockedVolume
                } else if s.maxVolume < 1, outputVolume > s.maxVolume + 0.005 {
                    write(volume: s.maxVolume, device: outputID, scope: kAudioObjectPropertyScopeOutput)
                    outputVolume = s.maxVolume
                }
            }
            if s.lockMute, outputMuted != s.lockedMute {
                write(mute: s.lockedMute, device: outputID, scope: kAudioObjectPropertyScopeOutput)
                outputMuted = s.lockedMute
            }
            enforceRate(outputID, s)
        }
        if let uid = inputID.deviceUID {
            let s = deviceSettings[uid]
            if inputHasVolume, s.lockVolume, abs(inputVolume - s.lockedVolume) > 0.01 {
                write(volume: s.lockedVolume, device: inputID, scope: kAudioObjectPropertyScopeInput)
                inputVolume = s.lockedVolume
            }
            if s.lockMute, inputMuted != s.lockedMute {
                write(mute: s.lockedMute, device: inputID, scope: kAudioObjectPropertyScopeInput)
                inputMuted = s.lockedMute
            }
            enforceRate(inputID, s)
        }
    }

    private func enforceRate(_ device: AudioObjectID, _ s: DeviceSettings) {
        guard s.lockSampleRate, s.lockedRate > 0, abs(device.nominalSampleRate - s.lockedRate) > 1 else { return }
        setSampleRate(s.lockedRate, of: device)
    }

    /// Master element if the device has one, otherwise channels 1 and 2.
    private func volumeElements(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32] {
        guard device.isValid else { return [] }
        func has(_ e: UInt32) -> Bool {
            device.hasProperty(AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: e))
        }
        if has(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(has)
    }

    func readVolume(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        let values = volumeElements(device, scope: scope).compactMap {
            try? device.read(AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0),
                             default: Float32(0))
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    func readMute(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        guard device.isValid else { return false }
        let address = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope)
        guard device.hasProperty(address) else { return false }
        return ((try? device.read(address, default: UInt32(0))) ?? 0) != 0
    }

    /// Keeps the sliders in sync when volume is changed with the keyboard or another app.
    private func watchDeviceVolumes() {
        deviceListeners.forEach { $0.invalidate() }
        deviceListeners = []
        for (device, scope) in [(outputID, kAudioObjectPropertyScopeOutput), (inputID, kAudioObjectPropertyScopeInput)]
        where device.isValid {
            var addresses = volumeElements(device, scope: scope).map {
                AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0)
            }
            addresses.append(AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope))
            addresses.append(AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate))
            for address in addresses where device.hasProperty(address) {
                deviceListeners.append(PropertyListener(object: device, address: address) { [weak self] in
                    MainActor.assumeIsolated { self?.readVolumes() }
                })
            }
        }
    }

    // MARK: Writing

    func setOutputVolume(_ value: Float) {
        let cap = deviceSettings[outputUID].maxVolume
        let v = min(value, cap)
        write(volume: v, device: outputID, scope: kAudioObjectPropertyScopeOutput)
        outputVolume = v
        if v > 0, outputMuted { setOutputMuted(false) }
    }

    func setInputVolume(_ value: Float) {
        write(volume: value, device: inputID, scope: kAudioObjectPropertyScopeInput)
        inputVolume = value
        if value > 0, inputMuted { setInputMuted(false) }
    }

    func setOutputMuted(_ muted: Bool) {
        write(mute: muted, device: outputID, scope: kAudioObjectPropertyScopeOutput)
        outputMuted = muted
    }

    func setInputMuted(_ muted: Bool) {
        write(mute: muted, device: inputID, scope: kAudioObjectPropertyScopeInput)
        inputMuted = muted
    }

    func write(volume: Float, device: AudioObjectID, scope: AudioObjectPropertyScope) {
        for element in volumeElements(device, scope: scope) {
            try? device.write(AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: element),
                              value: Float32(min(1, max(0, volume))))
        }
    }

    func write(mute: Bool, device: AudioObjectID, scope: AudioObjectPropertyScope) {
        let address = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope)
        guard device.isValid, device.hasProperty(address) else { return }
        try? device.write(address, value: UInt32(mute ? 1 : 0))
    }

    func selectOutput(_ device: AudioDeviceInfo) { setDefault(kAudioHardwarePropertyDefaultOutputDevice, device) }
    func selectInput(_ device: AudioDeviceInfo) { setDefault(kAudioHardwarePropertyDefaultInputDevice, device) }
    func selectSystemOutput(_ device: AudioDeviceInfo) { setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, device) }

    private func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioDeviceInfo) {
        try? AudioObjectID.system.write(AudioObjectPropertyAddress(selector), value: device.id)
        refresh()
    }

    // MARK: Sample rate

    func availableSampleRates(of device: AudioObjectID) -> [Double] {
        let ranges = (try? device.readArray(AudioObjectPropertyAddress(kAudioDevicePropertyAvailableNominalSampleRates),
                                            of: AudioValueRange.self)) ?? []
        return Array(Set(ranges.map(\.mMinimum))).sorted()
    }

    func setSampleRate(_ rate: Double, of device: AudioObjectID) {
        try? device.write(AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate), value: Float64(rate))
    }

    // MARK: Device shortcuts

    private func hotKeyName(_ uid: String, _ action: DeviceAction) -> String { "dev.\(uid).\(action.rawValue)" }

    /// Registers a global hot key for every device shortcut the user recorded.
    func syncShortcuts() {
        var wanted: [String: (Shortcut, String, DeviceAction)] = [:]
        for device in allDevices {
            for (key, shortcut) in deviceSettings[device.uid].shortcuts {
                guard let action = DeviceAction(rawValue: key) else { continue }
                wanted[hotKeyName(device.uid, action)] = (shortcut, device.uid, action)
            }
        }
        for name in HotKeyCenter.shared.names(withPrefix: "dev.") where wanted[name] == nil {
            HotKeyCenter.shared.set(name, shortcut: nil)
        }
        for (name, entry) in wanted {
            let (shortcut, uid, action) = entry
            HotKeyCenter.shared.set(name, shortcut: shortcut) { [weak self] in self?.perform(action, uid: uid) }
        }
    }

    func perform(_ action: DeviceAction, uid: String) {
        guard let device = device(uid: uid) else { return }
        let step: Float = 1.0 / 16
        switch action {
        case .setInput: selectInput(device)
        case .setOutput: selectOutput(device)
        case .toggleOutputMute:
            write(mute: !readMute(device.id, scope: kAudioObjectPropertyScopeOutput), device: device.id,
                  scope: kAudioObjectPropertyScopeOutput)
        case .toggleInputMute:
            write(mute: !readMute(device.id, scope: kAudioObjectPropertyScopeInput), device: device.id,
                  scope: kAudioObjectPropertyScopeInput)
        case .outputVolumeUp, .outputVolumeDown:
            let cap = deviceSettings[uid].maxVolume
            let v = (readVolume(device.id, scope: kAudioObjectPropertyScopeOutput) ?? 0) + (action == .outputVolumeUp ? step : -step)
            write(volume: min(cap, max(0, v)), device: device.id, scope: kAudioObjectPropertyScopeOutput)
        case .inputVolumeUp, .inputVolumeDown:
            let v = (readVolume(device.id, scope: kAudioObjectPropertyScopeInput) ?? 0) + (action == .inputVolumeUp ? step : -step)
            write(volume: min(1, max(0, v)), device: device.id, scope: kAudioObjectPropertyScopeInput)
        }
    }

    // MARK: System-sound (alert) volume — only exposed through AppleScript's Standard Additions.
    // Always run through /usr/bin/osascript on a background queue so a slow call never blocks the UI.

    @ObservationIgnored private var alertWriting = false
    @ObservationIgnored private var pendingAlert: Int?

    private func runOsascript(_ script: String, completion: (@MainActor @Sendable (String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            var result: String?
            do {
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {}
            guard let completion else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    func refreshAlertVolume() {
        guard !alertWriting else { return }
        runOsascript("alert volume of (get volume settings)") { [weak self] result in
            guard let self, !self.alertWriting, let result, let n = Int(result) else { return }
            self.alertVolume = Float(n) / 100
        }
    }

    /// Writes are coalesced: while one is running only the newest value is kept.
    func setAlertVolume(_ value: Float, final: Bool = false) {
        alertVolume = value
        pendingAlert = Int((value * 100).rounded())
        flushAlertVolume()
    }

    private func flushAlertVolume() {
        guard !alertWriting, let value = pendingAlert else { return }
        pendingAlert = nil
        alertWriting = true
        runOsascript("set volume alert volume \(value)") { [weak self] _ in
            guard let self else { return }
            self.alertWriting = false
            self.flushAlertVolume()
        }
    }
}
