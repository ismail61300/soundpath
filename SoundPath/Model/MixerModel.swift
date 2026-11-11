import AppKit
import AVFoundation
import CoreAudio
import Observation
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.soundpath.SoundPath", category: "Mixer")

/// Meter values for one row. Separate observable so the 12 FPS updates only redraw the meter view.
@MainActor @Observable
final class MeterState {
    var left: Float = 0
    var right: Float = 0
    var peakLeft: Float = 0
    var peakRight: Float = 0
    @ObservationIgnored fileprivate var peakHoldL = 0
    @ObservationIgnored fileprivate var peakHoldR = 0

    fileprivate func reset() {
        if left != 0 || right != 0 || peakLeft != 0 || peakRight != 0 {
            left = 0; right = 0; peakLeft = 0; peakRight = 0
        }
    }
}

@MainActor @Observable
final class AppRow: Identifiable {
    let id: String
    var name: String
    var icon: NSImage
    var isRunning = true
    var isPlaying = false
    var isTapped = false
    var isFavorite = false
    var settings: AppSettings
    let meter = MeterState()

    init(id: String, name: String, icon: NSImage, settings: AppSettings) {
        self.id = id
        self.name = name
        self.icon = icon
        self.settings = settings
    }
}

/// The UI-facing model. Owns the engine, process monitor and settings, and reconciles
/// which apps are tapped.
@MainActor @Observable
final class MixerModel {
    private(set) var rows: [AppRow] = []
    private(set) var permission: AudioCapturePermission.Status = MixerModel.resolvedPermission()
    private(set) var lastError: String?
    private(set) var presets: [EQPreset] = []
    /// Mac-wide output / input / system-sound controls.
    @ObservationIgnored let system = SystemAudio()
    /// Pseudo-row for the master "Output" effects (EQ / Boost / Overdrive on everything SoundPath routes).
    let masterRow: AppRow
    static let masterID = "__output__"
    private(set) var quickConfigs: [QuickConfig] = []
    /// Level of the mixed output, shown beside the Output row.
    let outputMeter = MeterState()
    @ObservationIgnored let pluginWindows = PluginWindowManager()
    /// Level of the default input device, shown beside the Input row while the menu panel is open.
    let inputMeter = MeterState()
    /// True while the input probe is delivering levels (false when mic access is missing).
    private(set) var inputMeterLive = false
    /// Names of the other apps currently capturing the microphone (refreshed while the panel is open).
    private(set) var inputUserNames: [String] = []
    @ObservationIgnored private let inputProbe = InputLevelProbe()
    @ObservationIgnored private var inputCheckTick = 0
    private(set) var excludedApps: [FavoriteApp] = []
    /// Software master volume for output devices without hardware volume (and Super Volume Keys).
    private(set) var softwareVolume: Float = 1
    private(set) var softwareMuted = false
    /// Header pin: keeps the panel open when clicking elsewhere.
    var panelPinned = false
    /// > 0 while a modal dialog (open panel / alert) is up, so the panel does not dismiss itself.
    @ObservationIgnored var modalDepth = 0

    @ObservationIgnored private let engine = AudioEngineController()
    @ObservationIgnored private let monitor = AudioProcessMonitor()
    @ObservationIgnored private let store = SettingsStore()
    @ObservationIgnored private var lastActive: [String: Date] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var processObjects: [String: [AudioObjectID]] = [:]
    @ObservationIgnored private var housekeeping: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var idleWatchdog: Timer?
    @ObservationIgnored private var reconcileQueued = false
    @ObservationIgnored private var visibleHosts: Set<String> = []

    /// How long a silent, untouched app keeps its tap (avoids churn on pause/resume).
    private let idleGrace: TimeInterval = 4
    /// Seconds of digital silence before the effect chain goes to sleep.
    private let idleBypassAfter: TimeInterval = 3
    static let meterFPS: Double = 12

    init() {
        masterRow = AppRow(id: Self.masterID, name: L("sys.output"),
                           icon: NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil) ?? NSImage(),
                           settings: store[Self.masterID])
        engine.applyMaster(masterRow.settings)
        let system = self.system
        engine.settingsProvider = { uid in system.deviceSettings[uid] }
        system.onDeviceSettingsChanged = { [weak self] in self?.engine.refreshDeviceSettings() }
        quickConfigs = store.quickConfigs
        excludedApps = store.excluded
        if UserDefaults.standard.object(forKey: PrefKey.softwareVolume) != nil {
            softwareVolume = UserDefaults.standard.float(forKey: PrefKey.softwareVolume)
        }
        engine.setMasterVolume(softwareVolume)
        presets = store.allPresets
        monitor.onChange = { [weak self] in self?.queueReconcile() }
        engine.onRebuild = { [weak self] in self?.reconcile() }
        engine.onPluginFailure = { [weak self] name in self?.pluginFailed(name) }
        housekeeping = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.flush() }
        }
        reconcile()
    }

    // MARK: Visibility (meters only run while some panel is on screen)

    func setVisible(_ visible: Bool, host: String) {
        let was = !visibleHosts.isEmpty
        if visible { visibleHosts.insert(host) } else { visibleHosts.remove(host) }
        if was != !visibleHosts.isEmpty {
            engine.setMetering(!visibleHosts.isEmpty)
            if visibleHosts.isEmpty { outputMeter.reset() }
            updateMeterTimer()
        }
        syncInputProbe()
    }

    /// SoundPath never turns the microphone on by itself: the probe runs only while the menu panel
    /// is open, access is already granted AND another app is capturing input. Otherwise the Input
    /// row keeps its hatched "inactive" look.
    private func syncInputProbe() {
        let menuOpen = visibleHosts.contains("menu")
        let users = menuOpen ? Self.inputUserNames() : []
        if users != inputUserNames { inputUserNames = users }
        let wanted = menuOpen
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && !users.isEmpty
        if wanted {
            if !inputProbe.isRunning || inputProbe.device != system.inputID {
                inputProbe.start(device: system.inputID, left: 1, right: 2)
            }
        } else if inputProbe.isRunning || inputMeterLive {
            inputProbe.stop()
            inputMeter.reset()
            if inputMeterLive { inputMeterLive = false }
        }
    }

    private static func inputUserNames() -> [String] {
        var names: [String] = []
        for user in AudioObjectID.inputUsers() {
            var name = NSRunningApplication(processIdentifier: user.pid)?.localizedName
            if name == nil, var id = user.bundleID {
                // Helper processes ("com.vendor.App.helper.Renderer"): resolve the parent app instead.
                if let r = id.range(of: ".helper", options: .caseInsensitive) { id = String(id[..<r.lowerBound]) }
                name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
                    ?? (id.hasPrefix("com.apple.") ? "macOS" : id.split(separator: ".").last.map(String.init))
            }
            if let name, !names.contains(name) { names.append(name) }
        }
        return names
    }

    // MARK: Permission

    var canTap: Bool { permission != .denied }

    /// The TCC preflight often answers "unknown" even after a grant, so a remembered grant fills that gap.
    /// An explicit denial from the system always wins.
    private static func resolvedPermission() -> AudioCapturePermission.Status {
        let status = AudioCapturePermission.status
        if status == .unknown, UserDefaults.standard.bool(forKey: PrefKey.audioPermissionGranted) { return .authorized }
        return status
    }

    private func markPermissionGranted() {
        permission = .authorized
        UserDefaults.standard.set(true, forKey: PrefKey.audioPermissionGranted)
    }

    /// Re-reads the permission (e.g. after the user changed it in System Settings).
    func refreshPermission() {
        let status = Self.resolvedPermission()
        // Keep an explicit denial sticky until the system says otherwise.
        if status == .unknown, permission == .denied { return }
        if status != permission { permission = status }
    }

    /// Asks for System Audio Recording; the first-launch tour also asks for the microphone (input level meter)
    /// so every permission is handled in one place.
    func requestPermission(includingMicrophone: Bool = false) {
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            if granted { markPermissionGranted() } else {
                permission = .denied
                UserDefaults.standard.set(false, forKey: PrefKey.audioPermissionGranted)
            }
            if includingMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            reconcile()
        }
    }

    // MARK: User actions

    /// Single entry point for every settings change coming from the UI.
    func update(_ row: AppRow, _ mutate: (inout AppSettings) -> Void) {
        var s = row.settings
        mutate(&s)
        guard s != row.settings else { return }
        row.settings = s
        store[row.id] = s
        engine.chains[row.id]?.apply(s)
        if row.id == Self.masterID { engine.applyMaster(s) }
        queueReconcile()
    }

    // MARK: Audio Unit plug-ins

    func setPlugin(_ plugin: AUPluginSettings?, for row: AppRow) {
        update(row) { $0.plugin = plugin }
    }

    /// Opens the plug-in's own window; its state is saved when the window closes.
    func openPlugin(for row: AppRow) {
        guard let plugin = row.settings.plugin, let unit = engine.pluginUnit(for: row.id) else {
            report(L("fx.plugin.loading"))
            return
        }
        pluginWindows.show(id: row.id, title: plugin.name, unit: unit) { [weak self] in
            guard let self else { return }
            let data = self.engine.pluginState(for: row.id)
            self.update(row) { $0.plugin?.state = data }
        }
    }

    private func pluginFailed(_ name: String) {
        for row in rows + [masterRow] where row.settings.plugin?.name == name {
            update(row) { $0.plugin = nil }
        }
        report(String(format: L("fx.plugin.failed"), name))
    }

    func row(withID id: String) -> AppRow? {
        id == Self.masterID ? masterRow : rows.first { $0.id == id }
    }

    /// Redirects an app's audio to another output device (`nil` = system default).
    func setOutputDevice(_ uid: String?, for row: AppRow) {
        update(row) { $0.outputDeviceUID = uid }
    }

    func setVolume(_ volume: Float, for row: AppRow) {
        update(row) {
            $0.volume = volume
            if volume > 0, $0.muted { $0.muted = false }
        }
    }

    func toggleMute(_ row: AppRow) {
        update(row) { $0.muted.toggle() }
    }

    func toggleMagicBoost(_ row: AppRow) {
        update(row) {
            if var b = $0.magicBoost { b.enabled.toggle(); $0.magicBoost = b } else { $0.magicBoost = MagicBoostSettings() }
        }
    }

    func resetEffects(_ row: AppRow) {
        update(row) {
            $0.overdrive = nil
            $0.eq = nil
            $0.magicBoost = nil
        }
    }

    func resetAll(_ row: AppRow) {
        update(row) { $0 = .default }
    }

    // MARK: Favorites

    func toggleFavorite(_ row: AppRow) {
        if store.isFavorite(row.id) {
            store.removeFavorite(row.id)
        } else {
            store.addFavorite(FavoriteApp(id: row.id, name: row.name))
        }
        reconcile()
    }

    func addFavorite(bundleID: String, name: String) {
        store.addFavorite(FavoriteApp(id: bundleID, name: name))
        reconcile()
    }

    func isFavorite(_ bundleID: String) -> Bool { store.isFavorite(bundleID) }

    // MARK: EQ presets

    func preset(id: String?) -> EQPreset? { store.preset(id: id) }

    func applyPreset(_ preset: EQPreset, to row: AppRow) {
        update(row) {
            var eq = $0.eq ?? EQSettings()
            eq.apply(preset)
            eq.enabled = true
            $0.eq = eq
        }
    }

    func saveCurrentEQ(of row: AppRow, as name: String) {
        guard let eq = row.settings.eq else { return }
        let preset = EQPreset(id: "user.\(UUID().uuidString)", name: name, preamp: eq.preamp, bands: eq.bands,
                              isBuiltIn: false)
        store.addPreset(preset)
        presets = store.allPresets
        update(row) { $0.eq?.presetID = preset.id }
    }

    func renamePreset(_ preset: EQPreset, to name: String) {
        store.renamePreset(preset.id, to: name)
        presets = store.allPresets
    }

    func deletePreset(_ preset: EQPreset) {
        store.deletePreset(preset.id)
        presets = store.allPresets
    }

    /// Imports AutoEQ / Equalizer APO parametric files and applies the first to `row` (if given).
    func importAutoEQ(applyingTo row: AppRow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "txt") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.message = L("eq.import.message")
        NSApp.activate(ignoringOtherApps: true)
        modalDepth += 1
        let response = panel.runModal()
        modalDepth -= 1
        guard response == .OK else { return }
        var imported: [EQPreset] = []
        for url in panel.urls {
            // Real exports are a few hundred bytes; refuse anything big instead of reading it into memory.
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 <= 256 * 1024,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let preset = AutoEQParser.parse(text, name: url.deletingPathExtension().lastPathComponent)
            else { continue }
            store.addPreset(preset)
            imported.append(preset)
        }
        presets = store.allPresets
        if imported.isEmpty {
            lastError = L("eq.import.failed")
        } else if let row, let first = imported.first {
            applyPreset(first, to: row)
        }
    }

    /// "Audio Processing" off for a device = leave audio going to it completely untouched.
    private func processingAllowed(for settings: AppSettings) -> Bool {
        let uid = settings.outputDeviceUID ?? system.outputUID
        return uid.isEmpty || system.deviceSettings[uid].processing
    }

    // MARK: Software volume (Super Volume Keys)

    func setSoftwareVolume(_ value: Float) {
        softwareVolume = max(0, min(1, value))
        if softwareVolume > 0 { softwareMuted = false }
        UserDefaults.standard.set(softwareVolume, forKey: PrefKey.softwareVolume)
        engine.setMasterVolume(softwareMuted ? 0 : softwareVolume)
    }

    func nudgeSoftwareVolume(by delta: Float) { setSoftwareVolume(softwareVolume + delta) }

    func toggleSoftwareMute() {
        softwareMuted.toggle()
        engine.setMasterVolume(softwareMuted ? 0 : softwareVolume)
    }

    func report(_ message: String) { lastError = message }

    func setLatency(_ value: Double) { engine.setLatency(value) }

    // MARK: Excluded apps

    func addExcluded(bundleID: String, name: String) {
        store.addExcluded(FavoriteApp(id: bundleID, name: name))
        excludedApps = store.excluded
        reconcile()
    }

    func removeExcluded(_ id: String) {
        store.removeExcluded(id)
        excludedApps = store.excluded
        reconcile()
    }

    // MARK: Quick configs

    func saveQuickConfig(named name: String) {
        var apps = store.allAppSettings
        apps[Self.masterID] = masterRow.settings
        store.addQuickConfig(QuickConfig(id: UUID().uuidString, name: name, apps: apps))
        quickConfigs = store.quickConfigs
    }

    func applyQuickConfig(_ config: QuickConfig) {
        store.replaceAppSettings(config.apps)
        for row in rows {
            let settings = store[row.id]
            row.settings = settings
            engine.chains[row.id]?.apply(settings)
        }
        masterRow.settings = store[Self.masterID]
        engine.applyMaster(masterRow.settings)
        queueReconcile()
    }

    func deleteQuickConfig(_ config: QuickConfig) {
        store.deleteQuickConfig(config.id)
        quickConfigs = store.quickConfigs
    }

    /// Modal text prompt; keeps the panel from auto-dismissing while it is up.
    func promptText(title: String, message: String = "", placeholder: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("common.save"))
        alert.addButton(withTitle: L("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        modalDepth += 1
        let response = alert.runModal()
        modalDepth -= 1
        guard response == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Reconciliation

    private func queueReconcile() {
        guard !reconcileQueued else { return }
        reconcileQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.reconcileQueued = false
                self?.reconcile()
            }
        }
    }

    private func reconcile() {
        let status = permission == .authorized ? .authorized : pollPermission()
        // TCC may report "unknown" until the user acts; keep an explicit denial sticky.
        if !(status == .unknown && permission == .denied) { permission = status }

        let excludedIDs = Set(excludedApps.map(\.id))
        let apps = monitor.snapshot().filter { !excludedIDs.contains($0.id) }
        let appsByID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()

        for app in apps {
            if app.isRunningOutput { lastActive[app.id] = now }
            let settings = store[app.id]
            let recentlyActive = lastActive[app.id].map { now.timeIntervalSince($0) < idleGrace } ?? false
            let wantsTap = canTap && processingAllowed(for: settings) && (app.isRunningOutput || recentlyActive || settings.needsPersistentTap)
            if wantsTap {
                ensureTap(app, settings: settings, now: now)
            } else if let chain = engine.chains[app.id], chain.isTapping {
                chain.stopTap()
                engine.stopIfIdle()
            }
        }

        // Rows: favorites first (in user order), then apps that played this session.
        var newRows: [AppRow] = []
        var used = Set<String>()
        for fav in store.favorites {
            newRows.append(row(for: fav.id, app: appsByID[fav.id], fallbackName: fav.name, favorite: true))
            used.insert(fav.id)
        }
        for app in apps where !used.contains(app.id) && (lastActive[app.id] != nil || app.isRunningOutput) {
            newRows.append(row(for: app.id, app: app, fallbackName: app.name, favorite: false))
        }

        // Drop chains of apps that went away.
        let liveIDs = Set(apps.map(\.id))
        for id in engine.chains.keys where !liveIDs.contains(id) {
            engine.removeChain(id)
            processObjects[id] = nil
        }
        for id in lastActive.keys where !liveIDs.contains(id) { lastActive[id] = nil }

        updateIdleState()
        logSignalChanges()
        if newRows.map(\.id) != rows.map(\.id) { rows = newRows }
    }

    private func row(for id: String, app: AudioAppInfo?, fallbackName: String, favorite: Bool) -> AppRow {
        let row = rows.first(where: { $0.id == id })
            ?? AppRow(id: id, name: app?.name ?? fallbackName,
                      icon: app.map(monitor.icon(for:)) ?? AudioProcessMonitor.icon(bundleID: id),
                      settings: store[id])
        if let app, row.name != app.name { row.name = app.name }
        if row.isRunning != (app != nil) { row.isRunning = app != nil }
        if row.isPlaying != (app?.isRunningOutput ?? false) { row.isPlaying = app?.isRunningOutput ?? false }
        if row.isFavorite != favorite { row.isFavorite = favorite }
        let tapped = engine.chains[id]?.isTapping == true
        if row.isTapped != tapped { row.isTapped = tapped }
        if !tapped { row.meter.reset() }
        return row
    }

    private func ensureTap(_ app: AudioAppInfo, settings: AppSettings, now: Date) {
        let chain = engine.chain(for: app.id, label: app.name)
        engine.assign(chain, toDeviceUID: settings.outputDeviceUID)
        if chain.settings != settings { chain.apply(settings) }
        if chain.isTapping, processObjects[app.id] == app.processObjects { return }
        if let retry = retryAfter[app.id], retry > now { return }
        do {
            try engine.startTap(for: chain, processObjects: app.processObjects)
            processObjects[app.id] = app.processObjects
            retryAfter[app.id] = nil
            lastError = nil
        } catch {
            retryAfter[app.id] = now.addingTimeInterval(5)
            lastError = "\(app.name): \(error)"
            log.error("Tap failed for \(app.name, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Idle bypass

    /// Puts effect chains to sleep after `idleBypassAfter` seconds of silence. Waking is handled by a
    /// fast (20 Hz) watchdog that only runs while at least one chain sleeps.
    private func updateIdleState() {
        var anyIdle = false
        for chain in engine.chains.values {
            let idle = chain.isTapping && chain.meter.secondsSinceSignal() > idleBypassAfter
            if idle != chain.isIdle {
                chain.setIdle(idle)
                log.notice("Idle bypass \(idle ? "on" : "off", privacy: .public): \(chain.id, privacy: .private)")
            }
            anyIdle = anyIdle || idle
        }
        if anyIdle, idleWatchdog == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeIdleChains() }
            }
            RunLoop.main.add(timer, forMode: .common)
            idleWatchdog = timer
        } else if !anyIdle, let timer = idleWatchdog {
            timer.invalidate()
            idleWatchdog = nil
        }
    }

    private func wakeIdleChains() {
        var anyIdle = false
        for chain in engine.chains.values where chain.isIdle {
            if !chain.isTapping || chain.meter.secondsSinceSignal() < 0.2 {
                chain.setIdle(false)
                log.notice("Idle bypass off: \(chain.id, privacy: .private)")
            } else {
                anyIdle = true
            }
        }
        if !anyIdle {
            idleWatchdog?.invalidate()
            idleWatchdog = nil
        }
    }

    // MARK: Diagnostics

    @ObservationIgnored private var lastPermissionPoll = Date.distantPast
    @ObservationIgnored private var signalState: [String: Bool] = [:]

    /// TCC preflight is an IPC round-trip; poll it at most every 3 s and only while not authorized.
    private func pollPermission() -> AudioCapturePermission.Status {
        let now = Date()
        guard now.timeIntervalSince(lastPermissionPoll) >= 3 else { return permission }
        lastPermissionPoll = now
        return Self.resolvedPermission()
    }

    /// Logs when a tapped app starts/stops delivering real (non-zero) audio.
    private func logSignalChanges() {
        for (id, chain) in engine.chains {
            let hasSignal = chain.isTapping && chain.meter.secondsSinceSignal() < 1.5
            // Real audio through a tap proves the permission (without it the tap delivers silence).
            if hasSignal, permission != .authorized { markPermissionGranted() }
            if signalState[id] != hasSignal {
                signalState[id] = hasSignal
                log.notice("Signal \(hasSignal ? "present" : "absent", privacy: .public): \(id, privacy: .private)")
            }
        }
        for id in signalState.keys where engine.chains[id] == nil { signalState[id] = nil }
    }

    // MARK: Meters (≈12 FPS, only while a panel is visible)

    private func updateMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        guard !visibleHosts.isEmpty else { return }
        let timer = Timer(timeInterval: 1 / Self.meterFPS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMeters() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func tickMeters() {
        update(outputMeter, reading: engine.masterMeter.consume(), gain: 1)
        if visibleHosts.contains("menu") {
            // Re-check about once a second whether another app is using the mic (and follow device changes).
            inputCheckTick += 1
            if inputCheckTick >= Int(Self.meterFPS) || (inputProbe.isRunning && inputProbe.device != system.inputID) {
                inputCheckTick = 0
                syncInputProbe()
            }
            if inputMeterLive != inputProbe.isRunning { inputMeterLive = inputProbe.isRunning }
            if inputProbe.isRunning {
                update(inputMeter, reading: inputProbe.consumeReading(), gain: system.inputMuted ? 0 : 1)
            }
        }
        for row in rows {
            guard row.isTapped, let chain = engine.chains[row.id] else { continue }
            let reading = chain.meter.consume()
            let s = row.settings
            let gain = s.muted ? 0 : s.volume * (s.overdriveActive ? Float(s.overdrive?.multiplier ?? 1) : 1)
            update(row.meter, reading: reading, gain: gain)
        }
    }

    private func update(_ m: MeterState, reading: LevelMeter.Reading, gain: Float) {
        let fall: Float = 0.72 // per frame release
        let l = Self.normalized(reading.rmsL * gain), r = Self.normalized(reading.rmsR * gain)
        let pl = Self.normalized(reading.peakL * gain), pr = Self.normalized(reading.peakR * gain)
        let newL = max(l, m.left * fall), newR = max(r, m.right * fall)
        if abs(newL - m.left) > 0.004 { m.left = newL < 0.005 ? 0 : newL }
        if abs(newR - m.right) > 0.004 { m.right = newR < 0.005 ? 0 : newR }

        let holdFrames = Int(Self.meterFPS) // ~1 s peak hold
        if pl >= m.peakLeft { m.peakLeft = pl; m.peakHoldL = holdFrames }
        else if m.peakHoldL > 0 { m.peakHoldL -= 1 }
        else if m.peakLeft > 0 { m.peakLeft = max(0, m.peakLeft - 0.05) }
        if pr >= m.peakRight { m.peakRight = pr; m.peakHoldR = holdFrames }
        else if m.peakHoldR > 0 { m.peakHoldR -= 1 }
        else if m.peakRight > 0 { m.peakRight = max(0, m.peakRight - 0.05) }
    }

    /// Maps linear amplitude to 0…1 on a -60…0 dBFS scale (limiter keeps real output ≤ 0 dBFS).
    static func normalized(_ amplitude: Float) -> Float {
        guard amplitude > 0.001 else { return 0 }
        let db = 20 * log10(amplitude)
        return max(0, min(1, (db + 60) / 60))
    }
}
