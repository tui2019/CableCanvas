import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let viewModel = AppViewModel()
    private var primaryActionItem: NSMenuItem?
    private var deviceItem: NSMenuItem?
    private var viewModelObserver: NSObjectProtocol?
    private var deviceConnectedObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "display.2",
                accessibilityDescription: "CableCanvas"
            )
        }

        let menu = NSMenu()
        menu.delegate = self
        let deviceItem = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)
        self.deviceItem = deviceItem
        menu.addItem(NSMenuItem.separator())
        let primaryActionItem = NSMenuItem(title: "Start Second Display", action: #selector(toggleSecondDisplay), keyEquivalent: "")
        primaryActionItem.target = self
        primaryActionItem.isEnabled = false
        primaryActionItem.isHidden = true
        menu.addItem(primaryActionItem)
        self.primaryActionItem = primaryActionItem
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit CableCanvas", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        self.statusItem = statusItem

        viewModelObserver = NotificationCenter.default.addObserver(
            forName: AppViewModel.connectionStateDidChangeNotification,
            object: viewModel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePrimaryActionTitle()
            }
        }
        deviceConnectedObserver = NotificationCenter.default.addObserver(
            forName: AppViewModel.deviceConnectedNotification,
            object: viewModel,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let name = (notification.userInfo?["name"] as? String) ?? "Android device"
            Task { @MainActor [weak self] in
                self?.showDeviceConnectedPrompt(deviceName: name)
            }
        }

        updatePrimaryActionTitle()

        viewModel.startBackgroundServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let viewModelObserver {
            NotificationCenter.default.removeObserver(viewModelObserver)
            self.viewModelObserver = nil
        }
        if let deviceConnectedObserver {
            NotificationCenter.default.removeObserver(deviceConnectedObserver)
            self.deviceConnectedObserver = nil
        }
        viewModel.stopBackgroundServices()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePrimaryActionTitle()
    }

    private func updatePrimaryActionTitle() {
        primaryActionItem?.title = viewModel.isStreaming ? "Stop Second Display" : "Start Second Display"
        let shouldShowStartAction = viewModel.isStreaming || viewModel.connectedDeviceSerial != nil
        primaryActionItem?.isHidden = !shouldShowStartAction
        primaryActionItem?.isEnabled = shouldShowStartAction && !viewModel.isInstallingAndroidClient && viewModel.canStartSecondDisplayNow()
        deviceItem?.title = viewModel.connectedDeviceLabel
    }

    @objc private func toggleSecondDisplay() {
        if viewModel.isInstallingAndroidClient || !viewModel.canStartSecondDisplayNow() {
            return
        }
        if viewModel.isStreaming {
            viewModel.stopSecondDisplay()
        } else {
            viewModel.createVirtualDisplayAndStartStreaming()
        }
        updatePrimaryActionTitle()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func showDeviceConnectedPrompt(deviceName: String) {
        guard !viewModel.isInstallingAndroidClient else { return }
        let alert = NSAlert()
        alert.messageText = "Device Connected"
        alert.informativeText = "\(deviceName) is ready. Start streaming now?"
        alert.alertStyle = .informational
        if let icon = NSImage(systemSymbolName: "display.2", accessibilityDescription: "CableCanvas") {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.addButton(withTitle: "Start Stream")
        alert.addButton(withTitle: "Later")

        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return }
        if viewModel.canStartSecondDisplayNow(), !viewModel.isInstallingAndroidClient {
            viewModel.createVirtualDisplayAndStartStreaming()
            updatePrimaryActionTitle()
        }
    }
}
