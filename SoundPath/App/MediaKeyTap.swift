import AppKit
import ApplicationServices
import CoreGraphics

/// Intercepts the keyboard volume keys (needs Accessibility permission). Used for "Super Volume Keys":
/// devices without hardware volume (HDMI / DAC) get a software volume instead.
@MainActor
final class MediaKeyTap {
    enum Key { case up, down, mute }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Whether the key should be swallowed (and `onKey` fired) right now.
    var shouldHandle: () -> Bool = { false }
    var onKey: (Key) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { me.reenable() }
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { me.handle(event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
        let keyCode = (ns.data1 & 0xFFFF0000) >> 16
        let flags = ns.data1 & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let key: Key
        switch keyCode {
        case 0: key = .up      // NX_KEYTYPE_SOUND_UP
        case 1: key = .down    // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute    // NX_KEYTYPE_MUTE
        default: return false
        }
        guard shouldHandle() else { return false }
        if isDown { onKey(key) }
        return true
    }
}
