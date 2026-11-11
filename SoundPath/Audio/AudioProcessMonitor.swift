import AppKit
import CoreAudio
import Darwin

/// A user-facing application grouping one or more audio process objects
/// (e.g. Safari + its WebContent helpers, Chrome + its renderer helpers).
struct AudioAppInfo: Identifiable, Equatable {
    /// Stable key used for settings persistence: bundle ID of the responsible app, or `pid:<n>`.
    let id: String
    let name: String
    let bundleID: String?
    let primaryPID: pid_t
    var processObjects: [AudioObjectID]
    var isRunningOutput: Bool

    static func == (a: AudioAppInfo, b: AudioAppInfo) -> Bool {
        a.id == b.id && a.name == b.name && a.processObjects == b.processObjects
            && a.isRunningOutput == b.isRunningOutput
    }
}

/// Observes CoreAudio's process object list and groups processes into apps.
@MainActor
final class AudioProcessMonitor {
    private var listListener: PropertyListener?
    private var runningListeners: [AudioObjectID: PropertyListener] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var iconCache: [String: NSImage] = [:]

    var onChange: (() -> Void)?

    init() {
        listListener = PropertyListener(
            object: .system, address: AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        ) { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    /// Reads the current process list and returns app groups (excluding SoundPath itself).
    func snapshot() -> [AudioAppInfo] {
        let objects = AudioObjectID.processObjectList()
        syncListeners(objects)

        var groups: [String: AudioAppInfo] = [:]
        var order: [String] = []
        for object in objects {
            let pid = object.processPID
            guard pid > 0, pid != ownPID else { continue }
            let running = object.processIsRunningOutput
            let owner = Self.responsiblePID(for: pid)
            guard owner != ownPID else { continue }
            let app = NSRunningApplication(processIdentifier: owner) ?? NSRunningApplication(processIdentifier: pid)
            let bundleID = app?.bundleIdentifier ?? object.processBundleID
            // System processes (daemons, Siri, Control Center …) are not user apps; the "System" card covers them.
            if Self.isSystemProcess(owner) { continue }
            let key = bundleID ?? "pid:\(owner)"

            if var group = groups[key] {
                group.processObjects.append(object)
                group.isRunningOutput = group.isRunningOutput || running
                groups[key] = group
            } else {
                let name = Self.firstNonEmpty(app?.localizedName, Self.processName(owner), Self.processName(pid),
                                              bundleID?.split(separator: ".").last.map(String.init)) ?? "PID \(pid)"
                groups[key] = AudioAppInfo(id: key, name: name, bundleID: bundleID,
                                           primaryPID: app?.processIdentifier ?? owner,
                                           processObjects: [object], isRunningOutput: running)
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }.map {
            var g = $0
            g.processObjects.sort()
            return g
        }
    }

    func icon(for app: AudioAppInfo) -> NSImage {
        if let cached = iconCache[app.id] { return cached }
        let image: NSImage
        if let running = NSRunningApplication(processIdentifier: app.primaryPID), let icon = running.icon {
            image = icon
        } else if let bundleID = app.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        iconCache[app.id] = image
        return image
    }

    /// Icon for an app that may not be running (favorites).
    static func icon(bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    /// Keeps one `IsRunningOutput` listener per process object so play/pause is noticed instantly.
    private func syncListeners(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        for (object, listener) in runningListeners where !current.contains(object) {
            listener.invalidate()
            runningListeners[object] = nil
        }
        for object in current where runningListeners[object] == nil {
            runningListeners[object] = PropertyListener(
                object: object, address: AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningOutput)
            ) { [weak self] in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
    }

    // MARK: Process helpers

    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t
    private static let responsibilityFn: ResponsibilityFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    /// Returns the "responsible" process (e.g. Safari for a WebContent helper).
    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibilityFn else { return pid }
        let owner = fn(pid)
        return owner > 0 ? owner : pid
    }

    /// Executable locations that belong to macOS itself. `/System/Applications` (Music, QuickTime …) and the
    /// Safari cryptex (`…/Cryptexes/App/…`) are deliberately *not* listed: those are real apps people want to control.
    /// Only the OS cryptex (system frameworks) counts as system.
    private static let systemPrefixes = ["/usr/", "/sbin/", "/bin/", "/System/Library/", "/System/iOSSupport/",
                                         "/System/Volumes/Preboot/Cryptexes/OS/", "/private/"]

    static func isSystemProcess(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let p = String(cString: path)
        return systemPrefixes.contains { p.hasPrefix($0) }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 4)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 { return String(cString: buffer) }
        // proc_name can fail for other users' processes; the executable path is more permissive.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).lastPathComponent

    }
}
