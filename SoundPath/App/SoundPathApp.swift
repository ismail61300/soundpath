import SwiftUI
import AppKit

@main
struct SoundPathApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The UI lives in a status-item panel and a Settings window (see AppDelegate); no regular scenes are needed.
        Settings { EmptyView() }
    }
}

/// Owns the menu-bar status item, the panel anchored under it, the Settings window,
/// the global shortcut and the volume-key tap.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem?
    private var panel: MenuPanelController?
    private lazy var eqWindows = EQWindowManager(model: model)
    private lazy var settingsWindow = SettingsWindowController(model: model)
    private lazy var devicesWindow = AudioDevicesWindowController(system: model.system)
    private lazy var onboardingWindow = OnboardingWindowController(model: model) { [weak self] in
        self?.showPanelAfterOnboarding()
    }
    private let mediaKeys = MediaKeyTap()
    private var appliedSymbol = ""
    private var appliedTheme = ""
    private var appliedShortcut = ""
    private var appliedLatency = -1.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        statusItem = item

        let controller = MenuPanelController(autoHideAllowed: { [weak self] in
            guard let model = self?.model else { return true }
            return !model.panelPinned && model.modalDepth == 0
        }, rootView: PanelRoot(
            model: model,
            pin: { [weak self] in self?.eqWindows.open($0) },
            unpin: { [weak self] in self?.eqWindows.close($0) },
            openSettings: { [weak self] in self?.showSettings() },
            openDevices: { [weak self] in self?.showDevices() },
            onSize: { [weak self] in self?.panel?.contentSizeChanged($0) }))
        controller.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.model.setVisible(visible, host: "menu")
            if visible { self.model.system.refresh(); self.model.system.refreshAlertVolume() }
        }
        panel = controller


        // Super Volume Keys: software volume for devices without hardware volume.
        mediaKeys.shouldHandle = { [weak self] in
            guard let self else { return false }
            return UserDefaults.standard.bool(forKey: PrefKey.superKeys) && !self.model.system.outputHasVolume
        }
        mediaKeys.onKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case .up: self.model.nudgeSoftwareVolume(by: 1.0 / 16)
            case .down: self.model.nudgeSoftwareVolume(by: -1.0 / 16)
            case .mute: self.model.toggleSoftwareMute()
            }
        }

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        applyPreferences()
        trackVolumeIcon()

        if !UserDefaults.standard.bool(forKey: PrefKey.onboardingDone) { onboardingWindow.show() }
    }

    /// After the tour, point at where the app lives: open the panel under the menu bar icon.
    private func showPanelAfterOnboarding() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            self.panel?.toggle(relativeTo: button)
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panel?.toggle(relativeTo: sender)
    }

    private func showSettings() {
        panel?.hide()
        settingsWindow.show()
    }

    private func showDevices() {
        panel?.hide()
        devicesWindow.show()
    }

    /// Menu bar icon: the chosen symbol, or a speaker that follows the output volume.
    private func updateStatusIcon() {
        let choice = UserDefaults.standard.string(forKey: PrefKey.menuBarIcon) ?? MenuBarIconChoice.volume.rawValue
        let symbol: String
        if choice == MenuBarIconChoice.volume.rawValue {
            let system = model.system
            symbol = system.outputHasVolume
                ? MenuBarIconChoice.volumeSymbol(volume: system.outputVolume, muted: system.outputMuted)
                : MenuBarIconChoice.volumeSymbol(volume: model.softwareVolume, muted: model.softwareMuted)
        } else {
            symbol = choice
        }
        guard symbol != appliedSymbol, let button = statusItem?.button else { return }
        appliedSymbol = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SoundPath")
            ?? NSImage(systemSymbolName: MenuBarIconChoice.sliders.rawValue, accessibilityDescription: "SoundPath")
        image?.isTemplate = true
        button.image = image
    }

    /// Re-evaluates the icon whenever the volume state it depends on changes.
    private func trackVolumeIcon() {
        withObservationTracking {
            let system = model.system
            _ = (system.outputVolume, system.outputMuted, system.outputHasVolume, model.softwareVolume, model.softwareMuted)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateStatusIcon()
                    self?.trackVolumeIcon()
                }
            }
        }
    }

    /// Applies every Settings change that needs an AppKit side effect. Idempotent and cheap.
    private func applyPreferences() {
        let defaults = UserDefaults.standard

        updateStatusIcon()

        let theme = defaults.string(forKey: PrefKey.appearance) ?? ThemeChoice.system.rawValue
        if theme != appliedTheme {
            appliedTheme = theme
            NSApp.appearance = ThemeChoice(rawValue: theme)?.nsAppearance
        }

        let shortcutJSON = defaults.string(forKey: PrefKey.shortcut) ?? ""
        if shortcutJSON != appliedShortcut {
            appliedShortcut = shortcutJSON
            HotKeyCenter.shared.set("global", shortcut: Shortcut.load()) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.panel?.toggle(relativeTo: button)
            }
        }

        let superKeys = defaults.bool(forKey: PrefKey.superKeys)
        if superKeys, !mediaKeys.isRunning, MediaKeyTap.isTrusted { mediaKeys.start() }
        if !superKeys, mediaKeys.isRunning { mediaKeys.stop() }

        let latency = defaults.object(forKey: PrefKey.latency) as? Double ?? LatencySetting.defaultValue
        if latency != appliedLatency {
            appliedLatency = latency
            model.setLatency(latency)
        }
    }
}

/// The panel's translucent popover material.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Root of the panel; re-evaluates when the language changes.
private struct PanelRoot: View {
    let model: MixerModel
    let pin: @MainActor (String) -> Void
    let unpin: @MainActor (String) -> Void
    let openSettings: @MainActor () -> Void
    let openDevices: @MainActor () -> Void
    let onSize: @MainActor (CGSize) -> Void

    var body: some View {
        MenuContentView(model: model)
            .environment(\.pinEQ, pin)
            .environment(\.unpinEQ, unpin)
            .environment(\.openSettingsWindow, openSettings)
            .environment(\.openAudioDevicesWindow, openDevices)
            .localizedEnvironment()
            .appTheme()
            // Material background drawn here (clipped to the rounded panel shape) so it follows the content's
            // animated size exactly instead of the window's frame.
            .background {
                PanelBackground()
                    .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.panelRadius, style: .continuous))
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                MainActor.assumeIsolated { onSize(size) }
            }
            // The window is sized from the reported size; keep content pinned to the top edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The Settings window (General · Appearance · Audio).
@MainActor
final class SettingsWindowController: NSObject {
    private let model: MixerModel
    private var window: NSWindow?

    init(model: MixerModel) { self.model = model }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = SettingsView(model: model).localizedEnvironment()
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = L("set.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The first-launch tour window. Closing it (either way) marks the tour as seen.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: MixerModel
    private let onFinish: () -> Void
    private var window: NSWindow?

    init(model: MixerModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = OnboardingView(model: model, finish: { [weak self] in
            self?.window?.close()
            self?.onFinish()
        })
        .localizedEnvironment()
        .appTheme()
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [] // the window size is fixed below, not derived from the content
        let window = NSWindow(contentViewController: hosting)
        window.title = L("onb.window")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height))
        // Exactly centred (NSWindow.center() sits above the middle).
        if let frame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: PrefKey.onboardingDone)
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
    }
}

/// The Audio Devices window (device list, nicknames, volumes, shortcuts …).
@MainActor
final class AudioDevicesWindowController: NSObject, NSWindowDelegate {
    private let system: SystemAudio
    private var window: NSWindow?

    init(system: SystemAudio) { self.system = system }

    func show() {
        system.refresh()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = AudioDevicesView(system: system).localizedEnvironment()
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = L("dev.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 780, height: 520))
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closing tears the content down so the live input meter stops and the microphone is released.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.contentViewController = nil
        closing.delegate = nil
        window = nil
    }
}

/// Pinned (always-available) EQ windows, one per app.
@MainActor
final class EQWindowManager: NSObject, NSWindowDelegate {
    private let model: MixerModel
    private var windows: [String: NSWindow] = [:]

    init(model: MixerModel) { self.model = model }

    func open(_ rowID: String) {
        if let existing = windows[rowID] { existing.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        guard let row = model.row(withID: rowID) else { return }
        let root = EQPanelView(row: row, model: model, pinned: true)
            .environment(\.unpinEQ, { [weak self] in self?.close($0) })
            .localizedEnvironment()
            .appTheme()
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "\(L("eq.title")) – \(row.name)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(rowID)
        windows[rowID] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.setVisible(true, host: "eq.\(rowID)")
    }

    func close(_ rowID: String) { windows[rowID]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        model.setVisible(false, host: "eq.\(id)")
    }
}
