import CoreAudio
import Foundation

/// Error type wrapping a CoreAudio `OSStatus`.
struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    var description: String {
        "\(context) failed: \(status) (\(fourCC(status)))"
    }

    private func fourCC(_ value: OSStatus) -> String {
        let n = UInt32(bitPattern: value)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(bytes: bytes, encoding: .ascii) ?? "?"
        }
        return "\(value)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    // MARK: Generic property access (never call from a realtime thread)

    func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(self, &addr)
    }

    func read<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, default value: T) throws -> T {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &result),
                  "AudioObjectGetPropertyData(\(addr.mSelector))")
        return result
    }

    func readArray<T>(_ address: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var addr = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "GetPropertyDataSize(\(addr.mSelector))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer), "GetPropertyData(\(addr.mSelector))")
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ address: AudioObjectPropertyAddress) -> String? {
        var addr = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    func write<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, value: T) throws {
        var addr = address
        var v = value
        try check(AudioObjectSetPropertyData(self, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v),
                  "AudioObjectSetPropertyData(\(addr.mSelector))")
    }

    // MARK: Device helpers

    static func defaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
                                      default: AudioObjectID.unknown)
    }

    /// Device with the given UID, or `.unknown` when it is not (or no longer) present.
    static func device(forUID uid: String) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID.system, &address, UInt32(MemoryLayout<CFString>.size),
                                       qualifier, &size, &device)
        }
        return status == noErr ? device : .unknown
    }

    var deviceUID: String? {
        readString(AudioObjectPropertyAddress(kAudioDevicePropertyDeviceUID))
    }

    var name: String? {
        readString(AudioObjectPropertyAddress(kAudioObjectPropertyName))
    }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        (try? readArray(AudioObjectPropertyAddress(kAudioDevicePropertyStreams, scope: scope),
                        of: AudioStreamID.self).count) ?? 0
    }

    /// Total channels the device exposes in `scope` (sum over its streams).
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    var nominalSampleRate: Double {
        (try? read(AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate), default: Float64(0))) ?? 0
    }

    // MARK: Process object helpers (macOS 14.2+)

    static func processObjectList() -> [AudioObjectID] {
        (try? AudioObjectID.system.readArray(AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList),
                                             of: AudioObjectID.self)) ?? []
    }

    var processPID: pid_t {
        (try? read(AudioObjectPropertyAddress(kAudioProcessPropertyPID), default: pid_t(-1))) ?? -1
    }

    var processBundleID: String? {
        readString(AudioObjectPropertyAddress(kAudioProcessPropertyBundleID))
    }

    var processIsRunningOutput: Bool {
        ((try? read(AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0) != 0
    }

    var processIsRunningInput: Bool {
        ((try? read(AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningInput), default: UInt32(0))) ?? 0) != 0
    }

    /// True when some other process (not SoundPath) is currently capturing audio input.
    static func inputUsedByOtherProcess() -> Bool {
        let me = getpid()
        return processObjectList().contains { $0.processIsRunningInput && $0.processPID != me }
    }

    private static let ignoredInputUsers = ["com.rogueamoeba.arkaudiod", "com.apple.CoreSpeech"]

    /// Bundle IDs (or PIDs when there is none) of other processes currently capturing audio input.
    static func inputUsers() -> [(pid: pid_t, bundleID: String?)] {
        let me = getpid()
        return processObjectList().compactMap { object in
            guard object.processIsRunningInput else { return nil }
            let pid = object.processPID
            let bundleID = object.processBundleID
            // shortcut: background services hold input open without a real mic user (audio drivers, "Hey Siri"
            // listening); extend this prefix list if more show up.
            if let id = bundleID, Self.ignoredInputUsers.contains(where: id.hasPrefix) { return nil }
            return pid == me ? nil : (pid, bundleID)
        }
    }

    var transportType: UInt32 {
        (try? read(AudioObjectPropertyAddress(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
    }

    var tapFormat: AudioStreamBasicDescription? {
        try? read(AudioObjectPropertyAddress(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
    }
}

/// Owns a CoreAudio property listener block and removes it on `invalidate()` / deinit.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init(object: AudioObjectID, address: AudioObjectPropertyAddress,
         queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        active = AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block) == noErr
    }

    func invalidate() {
        guard active else { return }
        active = false
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { invalidate() }
}
