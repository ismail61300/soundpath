import AppKit
import SwiftUI

/// Borderless panel that must be able to become key so sliders / menus inside it behave normally.
private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Menu-bar panel anchored centred under the status item. Unlike NSPopover it keeps its top edge and
/// horizontal centre fixed when the content size changes (apps come and go, FX opens), so it never drifts.
@MainActor
final class MenuPanelController: NSObject {
    var onVisibilityChange: ((Bool) -> Void)?
    /// False while the panel is pinned or a modal dialog is up: outside clicks / app switches must not close it.
    private let autoHideAllowed: () -> Bool

    private let panel: PanelWindow
    private let host: NSHostingController<AnyView>
    private weak var button: NSStatusBarButton?
    private var anchorMidX: CGFloat = 0
    private var anchorTopY: CGFloat = 0
    private var contentSize = CGSize(width: 380, height: 300)
    private var framePending = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }

    init(autoHideAllowed: @escaping () -> Bool, rootView: some View) {
        self.autoHideAllowed = autoHideAllowed
        host = NSHostingController(rootView: AnyView(rootView))
        host.sizingOptions = [] // the panel is sized explicitly from the size SwiftUI reports
        panel = PanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        super.init()

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The rounded material background is drawn by SwiftUI (see PanelRoot), so it animates together
        // with the content. The window itself is transparent and may be larger than the content while an
        // expand / collapse animation runs, which keeps the window edge from lagging behind the content.
        let container = NSView()
        container.wantsLayer = true
        panel.contentView = container
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)
    }

    /// When the panel was last closed by an outside click / app deactivation (not by the toggle itself).
    private var lastAutoHide = Date.distantPast

    func toggle(relativeTo button: NSStatusBarButton) {
        if isVisible { hide(); return }
        // The same click that deactivated the app / hit the status icon may already have closed the panel
        // a moment ago; don't let its toggle action reopen it straight away.
        if Date().timeIntervalSince(lastAutoHide) < 0.35 { return }
        show(relativeTo: button)
    }

    private func autoHide() {
        lastAutoHide = Date()
        hide()
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        self.button = button
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorMidX = rect.midX
        anchorTopY = rect.minY - 4

        host.view.layoutSubtreeIfNeeded()
        let fit = host.view.fittingSize
        if fit.width > 1, fit.height > 1 { contentSize = fit }
        applyFrame(animated: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        installMonitors()
        onVisibilityChange?(true)
    }

    func hide() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    /// Called by SwiftUI whenever the panel content's natural size changes (every frame of an animation).
    func contentSizeChanged(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1,
              size.width < 4000, size.height < 4000, size != contentSize else { return }
        contentSize = size
        guard isVisible else { return }
        // Deferred: this is called from inside a SwiftUI layout pass, and changing the window frame
        // there re-enters layout ("layoutSubtreeIfNeeded on a view which is already being laid out").
        if !framePending {
            framePending = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.framePending = false
                    guard self.isVisible else { return }
                    // Grow the window ahead of the content (with slack); shrinking waits for `settle`, so the
                    // window never cuts into content that is still animating.
                    let window = self.panel.frame.size
                    if self.contentSize.width + 4 > window.width || self.contentSize.height + 4 > window.height {
                        self.applyFrame(animated: false, slack: Self.animationSlack)
                    }
                }
            }
        }
        // Once the size stops changing, fit the window exactly.
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.applyFrame(animated: false, slack: .zero)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static let animationSlack = CGSize(width: 80, height: 200)
    private var settleWork: DispatchWorkItem?

    /// Keeps the top edge and horizontal centre fixed; clamps to the screen. `slack` adds transparent room
    /// (split evenly left / right, added at the bottom) around the content.
    private func applyFrame(animated: Bool, slack: CGSize = .zero) {
        let size = CGSize(width: contentSize.width + slack.width, height: contentSize.height + slack.height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorMidX, y: anchorTopY)) } ?? NSScreen.main
        var x = anchorMidX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8 - slack.width / 2), visible.maxX - size.width - 8 + slack.width / 2)
        }
        let frame = NSRect(x: x, y: anchorTopY - size.height, width: size.width, height: size.height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
        }
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak panel] in
            MainActor.assumeIsolated { panel?.invalidateShadow() }
        }
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] _ in
            MainActor.assumeIsolated {
                // A click on the status icon is handled by its action (toggle); don't close-then-reopen.
                guard let self, self.autoHideAllowed() else { return }
                if !self.isOverStatusButton(NSEvent.mouseLocation) { self.autoHide() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouse.union(.keyDown)) { [weak self] event in
            // Only Sendable values cross into the main-actor closure (NSEvent itself is not Sendable).
            let isKeyDown = event.type == .keyDown
            // keyCode is only valid on key events; reading it on a mouse event raises NSInternalInconsistencyException.
            let keyCode: UInt16 = isKeyDown ? event.keyCode : 0
            let window = event.window
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if isKeyDown {
                    if keyCode == 53, self.autoHideAllowed() { self.hide(); return true } // Escape
                    return false
                }
                let inside = window === self.panel || window === self.button?.window
                    || self.isOverStatusButton(NSEvent.mouseLocation)
                    || (self.panel.childWindows?.contains { $0 === window } ?? false)
                    || window?.parent === self.panel
                if !inside, self.autoHideAllowed() { self.autoHide() }
                return false
            }
            return swallow ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.autoHideAllowed() else { return }
                self.autoHide()
            }
        }
    }

    private func isOverStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -2, dy: -2).contains(screenPoint)
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        globalMonitor = nil; localMonitor = nil; resignObserver = nil
    }
}
