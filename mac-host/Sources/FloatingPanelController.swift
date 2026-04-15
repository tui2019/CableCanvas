import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let panel: NSPanel

    init(viewModel: AppViewModel) {
        let rootView = ControlPanelView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: rootView)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "CableCanvas"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

