import AppKit
import AVFoundation
import CoreAudio
import OSLog

private let log = Logger(subsystem: "com.soundpath.SoundPath", category: "Engine")

/// One `AVAudioEngine` bound to one output device, with its own master effect chain.
/// `key == ""` follows the system default output; any other key is a device UID ("redirect").
@MainActor
final class EngineHost {
    let key: String
    let engine = AVAudioEngine()
    let master = MasterChain()
    private(set) var device: AudioObjectID = .unknown
    private(set) var uid = ""
    private(set) var sampleRate: Double = 48_000
    private(set) var attached: [String: AppAudioChain] = [:]
    var rebuildPending = false
    var settingsProvider: ((String) -> DeviceSettings)?
    /// Non-nil while the master level meter is wanted.
    var meter: LevelMeter? {
        didSet { if let meter { master.installMeterTap(meter) } else { master.removeMeterTap() } }
    }
    var bufferFrames: UInt32 = LatencySetting.deviceFrames(LatencySetting.defaultValue)
    var onNeedsRebuild: ((EngineHost, String) -> Void)?

    private var configObserver: NSObjectProtocol?
    private var defaultDeviceListener: PropertyListener?
    private var sampleRateListener: PropertyListener?

    var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)! }

    init(key: String) {
        self.key = key
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onNeedsRebuild?(self, "configuration change")
            }
        }
        if key.isEmpty {
            defaultDeviceListener = PropertyListener(
                object: .system, address: AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
            ) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onNeedsRebuild?(self, "default output changed")
                }
            }
        }
        refreshDevice()
        master.attach(to: engine, format: format)
    }

    func shutdown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        defaultDeviceListener?.invalidate()
        sampleRateListener?.invalidate()
        engine.stop()
    }

    func resolveDevice() -> AudioObjectID {
        key.isEmpty ? ((try? AudioObjectID.defaultOutputDevice()) ?? .unknown) : AudioObjectID.device(forUID: key)
    }

    private func refreshDevice() {
        device = resolveDevice()
        uid = device.deviceUID ?? ""
        let rate = device.nominalSampleRate
        if rate > 0 { sampleRate = rate }
        sampleRateListener = PropertyListener(
            object: device, address: AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate)
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onNeedsRebuild?(self, "sample rate changed")
            }
        }
    }

    // MARK: Chains

    func attach(_ chain: AppAudioChain) {
        chain.attach(to: engine, output: master.bus)
        attached[chain.id] = chain
    }

    func detach(_ chain: AppAudioChain) {
        guard attached[chain.id] != nil else { return }
        chain.detach(from: engine)
        attached[chain.id] = nil
    }

    // MARK: Lifecycle

    /// Output-device I/O buffer size (smaller = lower latency, larger = fewer glitches).
    func applyBufferSize(_ frames: UInt32) {
        guard device.isValid else { return }
        try? device.write(AudioObjectPropertyAddress(kAudioDevicePropertyBufferFrameSize), value: frames)
    }

    /// Per-device balance and output-channel routing from the Audio Devices window.
    func applyDeviceSettings(_ s: DeviceSettings) {
        master.setBalance(s.balanceOn ? s.balance : 0)
        applyChannelMap(left: s.outLeft, right: s.outRight)
    }

    /// Routes our stereo output to the chosen pair of device channels (multi-channel interfaces only).
    private func applyChannelMap(left: Int, right: Int) {
        guard engine.isRunning, device.isValid, let unit = engine.outputNode.audioUnit else { return }
        let total = device.channelCount(scope: kAudioObjectPropertyScopeOutput)
        guard total > 2, left >= 1, right >= 1, left <= total, right <= total, left != right || total == 1 else { return }
        var map = [Int32](repeating: -1, count: total)
        map[left - 1] = 0
        map[right - 1] = 1
        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
                                 map, UInt32(total * MemoryLayout<Int32>.size))
    }

    func startIfNeeded() {
        guard !engine.isRunning, !attached.isEmpty else { return }
        applyBufferSize(bufferFrames)
        defer { if let provider = settingsProvider { applyDeviceSettings(provider(uid)) } }
        do {
            if device.isValid { try engine.outputNode.auAudioUnit.setDeviceID(device) }
            engine.prepare()
            try engine.start()
            log.notice("Engine[\(self.key, privacy: .private)] started @ \(self.sampleRate) Hz on \(self.device.name ?? "?", privacy: .private)")
        } catch {
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopIfIdle() {
        guard engine.isRunning, !attached.values.contains(where: \.isTapping) else { return }
        engine.pause()
        log.notice("Engine[\(self.key, privacy: .private)] paused (idle)")
    }

    /// Tears down and rebuilds for the current device / sample rate. Returns true when taps must restart.
    func rebuildIfNeeded() -> Bool {
        let previousDevice = device
        let previousRate = sampleRate
        let newDevice = resolveDevice()
        let newRate = newDevice.nominalSampleRate
        if newDevice == previousDevice, newRate == previousRate || newRate == 0 {
            // Same device & rate (e.g. our own aggregate devices appearing): just make sure we run.
            if attached.values.contains(where: \.isTapping) { startIfNeeded() }
            return false
        }
        for chain in attached.values { chain.stopTap() }
        engine.stop()
        for chain in attached.values { chain.detach(from: engine) }
        master.removeMeterTap()
        master.detach(from: engine)
        engine.reset()

        refreshDevice()
        master.attach(to: engine, format: format)
        if let meter { master.installMeterTap(meter) }
        for chain in attached.values {
            chain.setSampleRate(sampleRate)
            chain.attach(to: engine, output: master.bus)
        }
        return true
    }
}

/// Owns every per-app chain and the engine hosts. The default host follows the system output;
/// apps redirected to another device get an extra host for that device. Main-actor only.
@MainActor
final class AudioEngineController {
    private(set) var chains: [String: AppAudioChain] = [:]
    private var hosts: [String: EngineHost] = [:]
    private var hostKey: [String: String] = [:]
    private var masterSettings = AppSettings.default
    private var masterVolume: Float = 1
    /// Level of everything SoundPath routes to the output (shown next to the Output row).
    let masterMeter = LevelMeter()
    private var meteringOn = false
    private var latency = LatencySetting.defaultValue
    /// Per-device settings (balance, channel routing) supplied by the model.
    var settingsProvider: ((String) -> DeviceSettings)? {
        didSet { refreshDeviceSettings() }
    }

    /// Called when an Audio Unit plug-in could not be loaded (argument: its name).
    var onPluginFailure: ((String) -> Void)?

    /// Called after a host was rebuilt (device / format change) so the owner can restart taps.
    var onRebuild: (() -> Void)?

    private var defaultHost: EngineHost { hosts[""]! }

    private var wakeObserver: NSObjectProtocol?

    init() {
        hosts[""] = makeHost(key: "")
        // After sleep the output device and the process taps can be stale; restart them cleanly.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give CoreAudio a moment to bring the devices back before rebuilding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self?.restartAfterWake() }
            }
        }
    }

    /// Stops every tap and engine; the owner's reconcile restarts the taps (and with them the engines).
    private func restartAfterWake() {
        log.notice("Wake from sleep: restarting taps and engines")
        for host in hosts.values {
            for chain in host.attached.values { chain.stopTap() }
            host.engine.stop()
            _ = host.rebuildIfNeeded()
        }
        onRebuild?()
    }

    private func makeHost(key: String) -> EngineHost {
        let host = EngineHost(key: key)
        host.onNeedsRebuild = { [weak self] host, reason in self?.scheduleRebuild(host, reason: reason) }
        host.master.apply(masterSettings)
        host.master.setVolume(masterVolume)
        host.settingsProvider = settingsProvider
        host.master.pluginSlot.onFailure = { [weak self] name in self?.onPluginFailure?(name) }
        host.applyDeviceSettings(settingsProvider?(host.uid) ?? DeviceSettings())
        if meteringOn { host.meter = masterMeter }
        host.bufferFrames = LatencySetting.deviceFrames(latency)
        hosts[key] = host
        return host
    }

    // MARK: Master FX ("Output" row)

    func applyMaster(_ settings: AppSettings) {
        masterSettings = settings
        for host in hosts.values { host.master.apply(settings) }
    }

    func setMetering(_ on: Bool) {
        guard on != meteringOn else { return }
        meteringOn = on
        for host in hosts.values { host.meter = on ? masterMeter : nil }
    }

    func refreshDeviceSettings() {
        for host in hosts.values {
            host.settingsProvider = settingsProvider
            host.applyDeviceSettings(settingsProvider?(host.uid) ?? DeviceSettings())
        }
    }

    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
        for host in hosts.values { host.master.setVolume(volume) }
    }

    /// Applies the Settings latency slider (0…1) to every output device and ring buffer.
    func setLatency(_ value: Double) {
        latency = value
        let ring = LatencySetting.ring(value)
        for host in hosts.values {
            host.bufferFrames = LatencySetting.deviceFrames(value)
            if host.engine.isRunning { host.applyBufferSize(host.bufferFrames) }
        }
        for chain in chains.values { chain.ring.setLatency(target: ring.target, max: ring.max) }
    }

    // MARK: Rebuild

    private func scheduleRebuild(_ host: EngineHost, reason: String) {
        guard !host.rebuildPending else { return }
        host.rebuildPending = true
        log.notice("Rebuild scheduled [\(host.key, privacy: .private)]: \(reason, privacy: .public)")
        // Coalesce bursts of notifications (device switches fire several).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.rebuild(host) }
        }
    }

    private func rebuild(_ host: EngineHost) {
        host.rebuildPending = false
        guard hosts[host.key] === host else { return }
        // A redirect target that disappeared: fall back to the default output.
        if !host.key.isEmpty, !host.resolveDevice().isValid {
            for chain in Array(host.attached.values) {
                chain.stopTap()
                host.detach(chain)
                chain.setSampleRate(defaultHost.sampleRate)
                defaultHost.attach(chain)
                hostKey[chain.id] = ""
            }
            pruneHosts()
            onRebuild?()
            return
        }
        if host.rebuildIfNeeded() { onRebuild?() }
    }

    private func pruneHosts() {
        for (key, host) in hosts where !key.isEmpty && host.attached.isEmpty {
            host.shutdown()
            hosts[key] = nil
        }
    }

    // MARK: Chains

    func chain(for id: String, label: String) -> AppAudioChain {
        if let existing = chains[id] { return existing }
        let host = defaultHost
        let chain = AppAudioChain(id: id, label: label, sampleRate: host.sampleRate)
        chain.pluginSlot.onFailure = { [weak self] name in self?.onPluginFailure?(name) }
        let ring = LatencySetting.ring(latency)
        chain.ring.setLatency(target: ring.target, max: ring.max)
        host.attach(chain)
        chains[id] = chain
        hostKey[id] = ""
        return chain
    }

    /// Host key for a requested device UID: "" for the system default (or when the device is gone).
    private func resolvedKey(_ uid: String?) -> String {
        guard let uid, !uid.isEmpty else { return "" }
        let device = AudioObjectID.device(forUID: uid)
        guard device.isValid else { return "" }
        return device.deviceUID == defaultHost.uid ? "" : uid
    }

    /// Moves `chain` to the engine host for `uid` (nil = system default). Stops its tap when it moves;
    /// the caller restarts the tap afterwards.
    func assign(_ chain: AppAudioChain, toDeviceUID uid: String?) {
        let desired = resolvedKey(uid)
        let current = hostKey[chain.id] ?? ""
        guard desired != current else { return }
        chain.stopTap()
        hosts[current]?.detach(chain)
        let host = hosts[desired] ?? makeHost(key: desired)
        chain.setSampleRate(host.sampleRate)
        host.attach(chain)
        hostKey[chain.id] = desired
        pruneHosts()
        for h in hosts.values { h.stopIfIdle() }
    }

    func removeChain(_ id: String) {
        guard let chain = chains.removeValue(forKey: id) else { return }
        chain.stopTap()
        hosts[hostKey[id] ?? ""]?.detach(chain)
        hostKey[id] = nil
        pruneHosts()
        stopIfIdle()
    }

    func stopIfIdle() {
        for host in hosts.values { host.stopIfIdle() }
    }

    // MARK: Audio Unit plug-ins

    private func slot(for id: String) -> PluginSlot? {
        id == MixerModel.masterID ? defaultHost.master.pluginSlot : chains[id]?.pluginSlot
    }

    /// The loaded plug-in instance for an app (or the master output), if it finished loading.
    func pluginUnit(for id: String) -> AVAudioUnit? { slot(for: id)?.unit }

    func pluginState(for id: String) -> Data? { slot(for: id)?.archivedState() }

    func startTap(for chain: AppAudioChain, processObjects: [AudioObjectID]) throws {
        guard let host = hosts[hostKey[chain.id] ?? ""], !host.uid.isEmpty else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "No output device")
        }
        try chain.startTap(processObjects: processObjects, outputUID: host.uid)
        host.startIfNeeded()
    }
}
