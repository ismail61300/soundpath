import AppKit
import SwiftUI

/// Reports whether the hosting window (the MenuBarExtra panel) is actually on screen.
/// Uses window occlusion state, which flips when the panel opens/closes.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        nsView.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { publish(false); return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        if note.name == NSWindow.willCloseNotification { self?.publish(false) } else { self?.evaluate() }
                    }
                })
            }
            evaluate()
        }

        private func evaluate() {
            guard let window else { publish(false); return }
            publish(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func publish(_ value: Bool) {
            guard value != lastValue else { return }
            lastValue = value
            onChange?(value)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
