import SwiftUI
import AppKit
import ServiceManagement

/// Settings window in the standard macOS style: one page of grouped forms (no tabs).
struct SettingsView: View {
    let model: MixerModel

    var body: some View {
        GeneralTab(model: model)
            .padding(EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20))
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true) // no scrolling: the window is as tall as the form
            .appTheme()
    }
}

// MARK: - General

private struct GeneralTab: View {
    let model: MixerModel
    @AppStorage(PrefKey.appearance) private var theme = ThemeChoice.system.rawValue
    @AppStorage(PrefKey.accent) private var accent = AccentChoice.system.rawValue
    @AppStorage(PrefKey.menuBarIcon) private var icon = MenuBarIconChoice.volume.rawValue
    @AppStorage(PrefKey.superKeys) private var superKeys = false
    @AppStorage(PrefKey.stripColumns) private var columns = 4
    @AppStorage(PrefKey.shortcut) private var shortcutJSON = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = MediaKeyTap.isTrusted

    var body: some View {
        Form {
            Section {
                Toggle(L("set.login"), isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            }

            Section {
                LabeledContent(L("set.version")) {
                    Text(Self.versionText).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent(L("set.built")) {
                    Text(Self.buildDate).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section(L("set.shortcut")) {
                LabeledContent(L("set.showHide")) { ShortcutRecorder(json: $shortcutJSON) }
            }

            Section {
                Toggle(L("set.superKeys"), isOn: Binding(get: { superKeys }, set: setSuperKeys))
                if superKeys && !trusted {
                    LabeledContent {
                        Button(L("set.openAccessibility")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    } label: {
                        Label(L("set.accessibility"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text(L("set.kbd"))
            } footer: {
                Text(L("set.superKeys.desc"))
            }

            Section(L("set.tab.appearance")) {
                Picker(L("set.theme"), selection: $theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Label(L(choice.titleKey), systemImage: choice.symbol).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Picker(L("set.accent"), selection: $accent) {
                    ForEach(AccentChoice.allCases) { choice in
                        Label {
                            Text(L(choice.titleKey))
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(choice.color ?? .accentColor)
                        }
                        .tag(choice.rawValue)
                    }
                }

                Picker(L("set.columns"), selection: $columns) {
                    ForEach([3, 4, 5], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)

                Picker(L("set.menuIcon"), selection: $icon) {
                    ForEach(MenuBarIconChoice.allCases) { choice in
                        Label(L(choice.titleKey), systemImage: choice.previewSymbol).tag(choice.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            trusted = MediaKeyTap.isTrusted
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// When this binary was linked: lets you tell a fresh build from an old one at a glance.
    private static var buildDate: String {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "?" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // The system refuses (EINVAL) for builds that don't live in /Applications, e.g. Xcode's DerivedData.
            model.report(Bundle.main.bundlePath.hasPrefix("/Applications/") ? error.localizedDescription : L("set.login.failed"))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setSuperKeys(_ on: Bool) {
        superKeys = on
        if on, !MediaKeyTap.isTrusted { MediaKeyTap.requestTrust() }
        trusted = MediaKeyTap.isTrusted
    }
}

/// Click-to-record shortcut field (needs at least one of ⌘ ⌃ ⌥). Delete clears, Esc cancels.
struct ShortcutRecorder: View {
    @Binding var json: String
    @State private var recording = false
    @State private var monitor: Any?

    private var shortcut: Shortcut? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? L("set.recording") : (shortcut?.display ?? L("set.record")))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            // Any click ends recording so key presses are never swallowed for long.
            if event.type != .keyDown { MainActor.assumeIsolated { stop() }; return event }
            MainActor.assumeIsolated {
                switch event.keyCode {
                case 53: stop() // Esc
                case 51: json = ""; stop() // Delete
                default:
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return }
                    var carbon: UInt32 = 0
                    var symbols = ""
                    if flags.contains(.control) { carbon |= 4096; symbols += "⌃" }
                    if flags.contains(.option) { carbon |= 2048; symbols += "⌥" }
                    if flags.contains(.shift) { carbon |= 512; symbols += "⇧" }
                    if flags.contains(.command) { carbon |= 256; symbols += "⌘" }
                    let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
                    json = Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key).json
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
