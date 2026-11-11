import AVFoundation
import AppKit
import AudioToolbox
import CoreAudioKit
import OSLog

private let log = Logger(subsystem: "com.soundpath.SoundPath", category: "Plugin")

/// A third-party Audio Unit effect chosen for an app (or the master output).
struct AUPluginSettings: Codable, Equatable {
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var name: String
    var enabled = true
    /// Archived `fullState` of the plug-in (presets / parameters), saved when its window closes.
    var state: Data?

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    /// Same plug-in (ignores name / enabled / state).
    func isSamePlugin(as other: AUPluginSettings) -> Bool {
        type == other.type && subType == other.subType && manufacturer == other.manufacturer
    }
}

/// Lists the installed Audio Unit effects.
enum AUPluginCatalog {
    static func effects() -> [AUPluginSettings] {
        let wildcard = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0,
                                                 componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: wildcard)
            // Apple's own effects are already covered by the built-in EQ / Boost / Overdrive.
            .filter { $0.audioComponentDescription.componentManufacturer != kAudioUnitManufacturer_Apple }
            .map { c in
                let d = c.audioComponentDescription
                let vendor = c.manufacturerName.isEmpty ? "" : "\(c.manufacturerName): "
                return AUPluginSettings(type: d.componentType, subType: d.componentSubType,
                                        manufacturer: d.componentManufacturer, name: vendor + c.name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// One Audio Unit insert point: `head → [plug-in] → tail`. Without a plug-in `head` feeds `tail` directly.
/// Main-actor only. The wiring is changed while the engine may be running (AVAudioEngine allows it).
@MainActor
final class PluginSlot {
    private(set) var unit: AVAudioUnit?
    private(set) var current: AUPluginSettings?
    private weak var engine: AVAudioEngine?
    private var head: AVAudioNode?
    private var tail: AVAudioNode?
    private var format: AVAudioFormat?
    private var token = 0
    private var appliedState: Data?
    /// Called when a plug-in could not be loaded (the owner reports it to the user).
    var onFailure: ((String) -> Void)?

    // MARK: Binding to an engine graph

    /// Call after `head → tail` was connected normally. Re-inserts an already loaded plug-in.
    func bind(engine: AVAudioEngine, head: AVAudioNode, tail: AVAudioNode, format: AVAudioFormat) {
        self.engine = engine; self.head = head; self.tail = tail; self.format = format
        if let unit { insert(unit) }
    }

    /// Call before the owning nodes are detached.
    func unbind() {
        if let unit, let engine, engine.attachedNodes.contains(unit) {
            engine.disconnectNodeOutput(unit)
            engine.detach(unit)
        }
        engine = nil; head = nil; tail = nil
    }

    // MARK: Settings

    func apply(_ settings: AUPluginSettings?) {
        guard let settings else {
            current = nil
            token += 1
            removeUnit()
            return
        }
        if let current, current.isSamePlugin(as: settings) {
            self.current = settings
            if let unit {
                unit.auAudioUnit.shouldBypassEffect = !settings.enabled
                if settings.state != appliedState { restoreState(settings.state, into: unit) }
            }
            return
        }
        // A different plug-in: drop the old one, load the new one asynchronously.
        current = settings
        token += 1
        let myToken = token
        removeUnit()
        AVAudioUnit.instantiate(with: settings.description, options: [.loadOutOfProcess]) { [weak self] loaded, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.token == myToken else { return }
                    guard let loaded, error == nil else {
                        log.error("Plug-in load failed: \(error?.localizedDescription ?? "?", privacy: .public)")
                        self.current = nil
                        self.onFailure?(settings.name)
                        return
                    }
                    self.finishLoading(loaded, settings: settings)
                }
            }
        }
    }

    private func finishLoading(_ loaded: AVAudioUnit, settings: AUPluginSettings) {
        // Reject plug-ins that cannot run on our stereo float format instead of crashing in connect().
        if let format {
            do {
                try loaded.auAudioUnit.inputBusses[0].setFormat(format)
                try loaded.auAudioUnit.outputBusses[0].setFormat(format)
            } catch {
                log.error("Plug-in format rejected: \(error.localizedDescription, privacy: .public)")
                current = nil
                onFailure?(settings.name)
                return
            }
        }
        unit = loaded
        loaded.auAudioUnit.shouldBypassEffect = !settings.enabled
        restoreState(settings.state, into: loaded)
        if engine != nil { insert(loaded) }
    }

    // MARK: Wiring

    private func insert(_ unit: AVAudioUnit) {
        guard let engine, let head, let tail, let format else { return }
        if !engine.attachedNodes.contains(unit) { engine.attach(unit) }
        engine.disconnectNodeOutput(head)
        engine.connect(head, to: unit, format: format)
        engine.connect(unit, to: tail, format: format)
    }

    private func removeUnit() {
        guard let unit else { return }
        self.unit = nil
        appliedState = nil
        guard let engine, let head, let tail, let format else { return }
        if engine.attachedNodes.contains(unit) {
            engine.disconnectNodeOutput(unit)
            engine.disconnectNodeOutput(head)
            engine.detach(unit)
        } else {
            engine.disconnectNodeOutput(head)
        }
        engine.connect(head, to: tail, format: format)
    }

    // MARK: State

    private func restoreState(_ data: Data?, into unit: AVAudioUnit) {
        appliedState = data
        guard let data,
              let dict = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSDate.self],
                from: data) as? [String: Any] else { return }
        unit.auAudioUnit.fullState = dict
    }

    /// Archived current state of the loaded plug-in (nil when none / unsupported).
    func archivedState() -> Data? {
        guard let dict = unit?.auAudioUnit.fullState else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: dict, requiringSecureCoding: false)
    }
}

/// Shows an Audio Unit's own interface in a window; saves the plug-in state when it closes.
@MainActor
final class PluginWindowManager: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var onClose: [ObjectIdentifier: () -> Void] = [:]

    func show(id: String, title: String, unit: AVAudioUnit, onClose: @escaping () -> Void) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        unit.auAudioUnit.requestViewController { [weak self] (controller: NSViewController?) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let content = controller ?? NSViewController()
                    if controller == nil {
                        // No custom UI: fall back to a plain notice.
                        let label = NSTextField(labelWithString: title)
                        label.frame = NSRect(x: 20, y: 20, width: 260, height: 20)
                        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
                        content.view.addSubview(label)
                    }
                    let window = NSWindow(contentViewController: content)
                    window.title = title
                    window.styleMask = [.titled, .closable, .miniaturizable]
                    window.isReleasedWhenClosed = false
                    window.delegate = self
                    window.center()
                    self.windows[id] = window
                    self.onClose[ObjectIdentifier(window)] = onClose
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose.removeValue(forKey: ObjectIdentifier(window))?()
        windows = windows.filter { $0.value !== window }
        window.contentViewController = nil
        window.delegate = nil
    }
}
