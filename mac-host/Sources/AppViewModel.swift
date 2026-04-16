import AppKit
import Foundation
import os

@MainActor
final class AppViewModel: ObservableObject {
    static let connectionStateDidChangeNotification = Notification.Name("AppViewModel.connectionStateDidChange")
    static let deviceConnectedNotification = Notification.Name("AppViewModel.deviceConnected")
    @Published var settings: AppSettings
    @Published var statusText: String = "Idle"
    @Published var clientConnected: Bool = false
    @Published var isStreaming: Bool = false
    @Published var isVirtualDisplayActive: Bool = false
    @Published var hasConnectedAdbDevice: Bool = false
    @Published var isInstallingAndroidClient: Bool = false
    @Published var connectedDeviceLabel: String = "No device connected"
    @Published var connectedDeviceSerial: String?

    private let settingsStore: SettingsStore
    private let streamer: FrameStreamer
    private let transport: FrameTransportServer
    private let adbService: AdbService
    private var lastDetectedSerial: String?
    private var deviceNameBySerial: [String: String] = [:]
    private var deviceLabelFetchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "CableCanvasHost", category: "AppViewModel")
    private let androidClientPackage = "com.cablecanvas.client"

    init() {
        let settingsStore = SettingsStore()
        var loadedSettings = settingsStore.load()
        if loadedSettings.fps != 30.0 {
            loadedSettings.fps = 30.0
            settingsStore.save(loadedSettings)
        }
        if loadedSettings.virtualDisplayRefreshRate != 30 {
            loadedSettings.virtualDisplayRefreshRate = 30
            settingsStore.save(loadedSettings)
        }
        if loadedSettings.virtualDisplayPpi <= 0 {
            loadedSettings.virtualDisplayPpi = 110
            settingsStore.save(loadedSettings)
        }
        if loadedSettings.streamSource != .virtualDisplay {
            loadedSettings.streamSource = .virtualDisplay
            settingsStore.save(loadedSettings)
        }
        if loadedSettings.virtualDisplayHiDPI || loadedSettings.virtualDisplayMirrorMain {
            loadedSettings.virtualDisplayHiDPI = false
            loadedSettings.virtualDisplayMirrorMain = false
            settingsStore.save(loadedSettings)
        }
        self.settingsStore = settingsStore

        let transport = TcpFrameTransportServer()
        self.transport = transport
        streamer = FrameStreamer(transport: transport)
        adbService = AdbService()
        settings = loadedSettings

        transport.onClientConnectionChanged = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.clientConnected = connected
            }
        }
    }

    func startBackgroundServices() {
        isVirtualDisplayActive = VirtualDisplayManager.isActive
        Task { [weak self] in
            guard let self else { return }
            let adbService = self.adbService
            let serials = await self.runBlocking {
                adbService.connectedDeviceSerialsSnapshot()
            }
            await MainActor.run {
                self.handleDeviceListChanged(serials: serials)
            }
        }
        adbService.startMonitoring(
            onNewDevice: { [weak self] serial in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let settingsSnapshot = self.settings
                    self.adbService.handleDetectedDevice(serial: serial, settings: settingsSnapshot)
                    self.lastDetectedSerial = serial
                    self.statusText = "Detected device \(serial)"
                    self.notifyDeviceConnected(serial: serial)
                }
            },
            onDisconnectedDevice: { [weak self] serial in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleDeviceDisconnected(serial: serial)
                }
            },
            onDeviceListChanged: { [weak self] serials in
                Task { @MainActor [weak self] in
                    self?.handleDeviceListChanged(serials: serials)
                }
            }
        )
    }

    func stopBackgroundServices() {
        adbService.stopMonitoring()
        deviceLabelFetchTask?.cancel()
        deviceLabelFetchTask = nil
        adbService.stopAndroidClientOnConnectedDevices(packageName: androidClientPackage)
        stopStreaming()
        _ = VirtualDisplayManager.destroy()
        isVirtualDisplayActive = false
        hasConnectedAdbDevice = false
        lastDetectedSerial = nil
        connectedDeviceLabel = "No device connected"
        connectedDeviceSerial = nil
        deviceNameBySerial.removeAll()
        notifyConnectionStateChanged()
    }

    func saveSettings() {
        settingsStore.save(settings)
    }

    func startStreaming() {
        guard !isStreaming else { return }
        Task { @MainActor [weak self] in
            await self?.startStreamingFlow(createVirtualDisplayIfNeeded: false)
        }
    }

    func createVirtualDisplayAndStartStreaming() {
        guard !isStreaming else { return }
        Task { @MainActor [weak self] in
            await self?.startStreamingFlow(createVirtualDisplayIfNeeded: true)
        }
    }

    func requestScreenCapturePermission() {
        let granted = ScreenCapturePermission.requestAccess()
        statusText = granted
            ? "Screen Recording permission granted."
            : "Screen Recording permission denied."
    }

    func createVirtualDisplay() {
        settings.virtualDisplayHiDPI = false
        settings.virtualDisplayMirrorMain = false
        settings.virtualDisplayRefreshRate = 30

        let serial = lastDetectedSerial ?? adbService.firstConnectedDeviceSerial()
        guard let serial else {
            statusText = "No connected tablet found."
            logger.error("createVirtualDisplay aborted: no connected serial")
            return
        }
        guard let deviceResolution = adbService.queryStreamingResolution(serial: serial) else {
            statusText = "Could not read tablet resolution from \(serial)."
            logger.error("createVirtualDisplay failed resolution query for serial=\(serial, privacy: .public)")
            return
        }
        settings.virtualDisplayWidth = deviceResolution.width
        settings.virtualDisplayHeight = deviceResolution.height
        if let deviceDensityDpi = adbService.queryDeviceDensityDpi(serial: serial) {
            settings.virtualDisplayPpi = deviceDensityDpi
            statusText = "Using tablet profile \(settings.virtualDisplayWidth)x\(settings.virtualDisplayHeight) @ \(deviceDensityDpi)dpi."
            logger.info(
                "dpi profile serial=\(serial, privacy: .public) dpi=\(deviceDensityDpi) resolution=\(self.settings.virtualDisplayWidth)x\(self.settings.virtualDisplayHeight)"
            )
        } else {
            statusText = "Using tablet resolution \(deviceResolution.width)x\(deviceResolution.height)."
        }
        logger.info(
            "createVirtualDisplay serial=\(serial, privacy: .public) resolved=\(deviceResolution.width)x\(deviceResolution.height) hidpi=\(self.settings.virtualDisplayHiDPI) mirror=\(self.settings.virtualDisplayMirrorMain)"
        )

        saveSettings()
            let config = VirtualDisplayConfig(
                name: settings.virtualDisplayName,
                width: settings.virtualDisplayWidth,
                height: settings.virtualDisplayHeight,
                refreshRate: settings.virtualDisplayRefreshRate,
                ppi: settings.virtualDisplayPpi,
                hiDPI: settings.virtualDisplayHiDPI,
                mirrorMain: settings.virtualDisplayMirrorMain
            )

        let ok = VirtualDisplayManager.create(config: config)
        isVirtualDisplayActive = VirtualDisplayManager.isActive
        if ok {
            let id = VirtualDisplayManager.displayID
            statusText = "Virtual monitor created at \(settings.virtualDisplayWidth)x\(settings.virtualDisplayHeight) (ID: \(id))."
            settings.virtualDisplayEnabled = true
            settings.streamSource = .virtualDisplay
            logger.info(
                "virtual display created id=\(id) requested=\(self.settings.virtualDisplayWidth)x\(self.settings.virtualDisplayHeight) online=\(self.onlineDisplaySummary(), privacy: .public)"
            )
        } else {
            statusText = "Failed to create virtual monitor."
            settings.virtualDisplayEnabled = false
            logger.error(
                "virtual display creation failed requested=\(self.settings.virtualDisplayWidth)x\(self.settings.virtualDisplayHeight) online=\(self.onlineDisplaySummary(), privacy: .public)"
            )
        }
        saveSettings()
    }

    func destroyVirtualDisplay() {
        let removed = VirtualDisplayManager.destroy()
        isVirtualDisplayActive = VirtualDisplayManager.isActive
        settings.virtualDisplayEnabled = false
        settings.streamSource = .virtualDisplay
        statusText = removed ? "Virtual monitor removed." : "No virtual monitor to remove."
        saveSettings()
    }

    func stopStreaming() {
        guard isStreaming else { return }
        statusText = "Stopping stream..."
        adbService.stopAndroidClientOnConnectedDevices(packageName: androidClientPackage)
        streamer.stop { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isStreaming = false
                self.statusText = "Idle"
            }
        }
    }

    func stopSecondDisplay() {
        if isStreaming {
            statusText = "Stopping stream..."
            adbService.stopAndroidClientOnConnectedDevices(packageName: androidClientPackage)
            streamer.stop { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isStreaming = false
                    self.destroyVirtualDisplay()
                    self.statusText = "Idle"
                }
            }
            return
        }

        destroyVirtualDisplay()
        statusText = "Idle"
    }

    private func onlineDisplaySummary() -> String {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return "none"
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return "unavailable"
        }
        return displays.prefix(Int(count)).map { id in
            let w = CGDisplayPixelsWide(id)
            let h = CGDisplayPixelsHigh(id)
            return "\(id):\(w)x\(h)"
        }.joined(separator: ",")
    }

    private func handleDeviceListChanged(serials: [String]) {
        hasConnectedAdbDevice = !serials.isEmpty
        let validSerials = Set(serials)
        deviceNameBySerial = deviceNameBySerial.filter { validSerials.contains($0.key) }

        if let lastDetectedSerial, serials.contains(lastDetectedSerial) {
            if let cachedName = deviceNameBySerial[lastDetectedSerial] {
                connectedDeviceSerial = lastDetectedSerial
                connectedDeviceLabel = "Connected: \(cachedName)"
                notifyConnectionStateChanged()
                return
            }
            refreshConnectedDeviceLabel(for: lastDetectedSerial)
            notifyConnectionStateChanged()
            return
        }
        lastDetectedSerial = serials.first
        refreshConnectedDeviceLabel(for: serials.first)
        notifyConnectionStateChanged()
    }

    private func ensureAndroidClientInstalledIfNeeded(serial: String) async -> Bool {
        if adbService.isAndroidClientInstalled(serial: serial, packageName: androidClientPackage) {
            return true
        }

        let deviceDisplayName = displayName(for: serial)

        let alert = NSAlert()
        alert.messageText = "Android client is missing"
        alert.informativeText = "CableCanvas needs to install the Android app on \(deviceDisplayName) before streaming can start. Continue?"
        alert.alertStyle = .warning
        if let icon = NSImage(systemSymbolName: "display.2", accessibilityDescription: "CableCanvas") {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            statusText = "Install cancelled."
            return false
        }

        isInstallingAndroidClient = true
        defer { isInstallingAndroidClient = false }

        guard let androidClientDir = resolveAndroidClientDirectory() else {
            statusText = "Could not find android-client project directory."
            return false
        }
        let adbService = self.adbService
        guard let apkPath = resolveExistingAndroidClientApk(androidClientDir: androidClientDir) else {
            statusText = "Android client APK not found. Put a prebuilt APK in mac-host/prebuilt/app-debug.apk."
            return false
        }

        statusText = "Using existing Android client APK..."

        statusText = "Installing Android client on \(deviceDisplayName)..."
        let installSucceeded = await runBlocking {
            adbService.installAndroidClient(serial: serial, apkPath: apkPath)
        }
        guard installSucceeded else {
            statusText = "Failed to install Android client on \(deviceDisplayName)."
            return false
        }

        statusText = "Android client installed on \(deviceDisplayName)."
        return true
    }

    private func resolveAndroidClientDirectory() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let sourceBase = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let candidates = [
            (cwd as NSString).appendingPathComponent("android-client"),
            (cwd as NSString).appendingPathComponent("../android-client"),
            (sourceBase as NSString).appendingPathComponent("android-client"),
        ]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: candidate).standardized.path
            }
        }
        return nil
    }

    private func resolveExistingAndroidClientApk(androidClientDir: String) -> String? {
        let sourceBase = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            (cwd as NSString).appendingPathComponent("prebuilt/app-debug.apk"),
            (cwd as NSString).appendingPathComponent("mac-host/prebuilt/app-debug.apk"),
            (sourceBase as NSString).appendingPathComponent("mac-host/prebuilt/app-debug.apk"),
            (sourceBase as NSString).appendingPathComponent("mac-host/prebuilt/CableCanvas.apk"),
            (androidClientDir as NSString).appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk"),
            (androidClientDir as NSString).appendingPathComponent("app-debug.apk"),
            (androidClientDir as NSString).appendingPathComponent("prebuilt/app-debug.apk"),
            (androidClientDir as NSString).appendingPathComponent("prebuilt/CableCanvas.apk"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func startStreamingFlow(createVirtualDisplayIfNeeded: Bool) async {
        settings.fps = 30.0
        settings.virtualDisplayRefreshRate = 30
        let adbService = self.adbService
        let serials = await runBlocking {
            adbService.connectedDeviceSerialsSnapshot()
        }
        hasConnectedAdbDevice = !serials.isEmpty
        let serial = serials.contains(lastDetectedSerial ?? "") ? lastDetectedSerial : serials.first
        lastDetectedSerial = serial
        guard let serial else {
            statusText = "Connect an ADB device before starting stream."
            return
        }

        if !adbService.isAndroidClientInstalled(serial: serial, packageName: androidClientPackage) {
            guard await ensureAndroidClientInstalledIfNeeded(serial: serial) else { return }
        }

        let launchSettingsSnapshot = settings
        adbService.prepareForStreaming(serial: serial, settings: launchSettingsSnapshot)

        settings.streamSource = .virtualDisplay

        if createVirtualDisplayIfNeeded {
            createVirtualDisplay()
            guard isVirtualDisplayActive else { return }
            statusText = "Waiting 5 seconds before starting stream..."
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        if !VirtualDisplayManager.isActive {
            statusText = "Create a virtual monitor first, then start streaming."
            return
        }

        if !ScreenCapturePermission.isAuthorized() {
            let granted = ScreenCapturePermission.requestAccess()
            guard granted else {
                statusText = "Screen Recording permission is required for display streaming."
                return
            }
        }

        let settingsSnapshot = settings
        saveSettings()
        statusText = "Starting stream..."
        streamer.start(settings: settingsSnapshot) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.statusText = "Failed to start: \(error.localizedDescription)"
                    self.isStreaming = false
                    return
                }
                self.isStreaming = true
                self.statusText = "Streaming on \(settingsSnapshot.host):\(settingsSnapshot.port)"
            }
        }
    }

    func canStartSecondDisplayNow() -> Bool {
        isStreaming || connectedDeviceSerial != nil
    }

    private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private func handleDeviceDisconnected(serial: String) {
        if lastDetectedSerial == serial {
            lastDetectedSerial = nil
        }

        refreshConnectedDeviceLabel(for: lastDetectedSerial)

        guard isStreaming || isVirtualDisplayActive else {
            statusText = "Device disconnected: \(serial)"
            return
        }

        if isStreaming {
            statusText = "Device disconnected; stopping stream..."
            streamer.stop { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isStreaming = false
                    _ = VirtualDisplayManager.destroy()
                    self.isVirtualDisplayActive = VirtualDisplayManager.isActive
                    self.settings.virtualDisplayEnabled = false
                    self.settings.streamSource = .virtualDisplay
                    self.saveSettings()
                    self.statusText = "Device disconnected: stream stopped and virtual monitor removed."
                }
            }
            return
        }

        _ = VirtualDisplayManager.destroy()
        isVirtualDisplayActive = VirtualDisplayManager.isActive
        settings.virtualDisplayEnabled = false
        settings.streamSource = .virtualDisplay
        saveSettings()
        statusText = "Device disconnected: virtual monitor removed."
    }

    private func refreshConnectedDeviceLabel(for serial: String?) {
        deviceLabelFetchTask?.cancel()
        guard let serial else {
            hasConnectedAdbDevice = false
            connectedDeviceLabel = "No device connected"
            connectedDeviceSerial = nil
            notifyConnectionStateChanged()
            return
        }

        hasConnectedAdbDevice = true
        connectedDeviceSerial = serial
        if let cachedName = deviceNameBySerial[serial] {
            connectedDeviceLabel = "Connected: \(cachedName)"
            notifyConnectionStateChanged()
            return
        }

        connectedDeviceLabel = "Connected: \(serial)"
        notifyConnectionStateChanged()
        let adbService = self.adbService
        deviceLabelFetchTask = Task { [weak self] in
            let label = await self?.runBlocking {
                adbService.queryDeviceDisplayName(serial: serial)
            }
            await MainActor.run {
                guard let self else { return }
                if self.lastDetectedSerial == serial {
                    let resolvedName = (label ?? serial).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.deviceNameBySerial[serial] = resolvedName
                    self.connectedDeviceLabel = "Connected: \(resolvedName)"
                    self.notifyConnectionStateChanged()
                }
            }
        }
    }

    private func displayName(for serial: String) -> String {
        deviceNameBySerial[serial] ?? serial
    }

    private func notifyConnectionStateChanged() {
        NotificationCenter.default.post(name: Self.connectionStateDidChangeNotification, object: self)
    }

    private func notifyDeviceConnected(serial: String) {
        if let cachedName = deviceNameBySerial[serial] {
            NotificationCenter.default.post(
                name: Self.deviceConnectedNotification,
                object: self,
                userInfo: [
                    "serial": serial,
                    "name": cachedName,
                ]
            )
            return
        }

        let adbService = self.adbService
        Task { [weak self] in
            guard let self else { return }
            let rawName = await self.runBlocking {
                adbService.queryDeviceDisplayName(serial: serial)
            }
            await MainActor.run {
                let resolvedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = resolvedName.isEmpty ? serial : resolvedName
                self.deviceNameBySerial[serial] = displayName
                if self.lastDetectedSerial == serial {
                    self.connectedDeviceLabel = "Connected: \(displayName)"
                    self.notifyConnectionStateChanged()
                }
                NotificationCenter.default.post(
                    name: Self.deviceConnectedNotification,
                    object: self,
                    userInfo: [
                        "serial": serial,
                        "name": displayName,
                    ]
                )
            }
        }
    }

}
