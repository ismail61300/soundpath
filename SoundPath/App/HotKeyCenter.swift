import AppKit
import Carbon.HIToolbox

private func hotKeyCallback(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    let id = hotKeyID.id
    DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
    return noErr
}

/// System-wide hot keys (Carbon `RegisterEventHotKey` – needs no Accessibility permission).
/// Each hot key has a name ("global", "dev.<uid>.<action>") so it can be replaced or removed individually.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        var id: UInt32
        var ref: EventHotKeyRef?
        var shortcut: Shortcut
        var action: () -> Void
    }

    private var entries: [String: Entry] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    /// Registers, replaces or (with `shortcut == nil`) removes the hot key called `name`.
    func set(_ name: String, shortcut: Shortcut?, action: @escaping () -> Void = {}) {
        if let old = entries[name] {
            if old.shortcut == shortcut {
                entries[name]?.action = action
                return
            }
            if let ref = old.ref { UnregisterEventHotKey(ref) }
            entries[name] = nil
        }
        guard let shortcut else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53504854), id: id) // 'SPHT'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return } // e.g. already taken by another app
        entries[name] = Entry(id: id, ref: ref, shortcut: shortcut, action: action)
    }

    func names(withPrefix prefix: String) -> [String] {
        entries.keys.filter { $0.hasPrefix(prefix) }
    }

    func fire(_ id: UInt32) {
        entries.values.first { $0.id == id }?.action()
    }
}
