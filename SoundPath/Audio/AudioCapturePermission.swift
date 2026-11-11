import AppKit
import Darwin

/// Wraps the "System Audio Recording" (kTCCServiceAudioCapture) permission.
///
/// There is no public API to query this permission, so we use the TCC framework's
/// `TCCAccessPreflight` / `TCCAccessRequest` via `dlsym` when available. If those symbols
/// are missing we report `.unknown` and the system prompt appears on the first tap.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFn: PreflightFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    private static let requestFn: RequestFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()

    static var status: Status {
        guard let preflightFn else { return .unknown }
        switch preflightFn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let requestFn else {
            Task { @MainActor in completion(false) }
            return
        }
        requestFn(service, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
