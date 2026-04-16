import Foundation
import os

final class AdbService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cablecanvas.adb.monitor")
    private var timer: DispatchSourceTimer?
    private var knownDevices = Set<String>()
    private let logger = Logger(subsystem: "CableCanvasHost", category: "AdbService")

    func startMonitoring(
        onNewDevice: @escaping @Sendable (String) -> Void,
        onDisconnectedDevice: @escaping @Sendable (String) -> Void = { _ in },
        onDeviceListChanged: @escaping @Sendable ([String]) -> Void = { _ in }
    ) {
        run(["start-server"])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = Set(self.connectedDeviceSerials())
            let newDevices = current.subtracting(self.knownDevices)
            let removedDevices = self.knownDevices.subtracting(current)
            self.knownDevices = current
            for serial in newDevices {
                onNewDevice(serial)
            }
            for serial in removedDevices {
                onDisconnectedDevice(serial)
            }
            onDeviceListChanged(current.sorted())
        }
        timer.resume()
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
    }

    func configureReverse(serial: String, port: Int) {
        _ = run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], timeout: 3)
    }

    func launchAndroidClient(serial: String, activity: String) {
        _ = run(["-s", serial, "shell", "am", "start", "-n", activity], timeout: 3)
    }

    func stopAndroidClientOnConnectedDevices(packageName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for serial in self.connectedDeviceSerials() {
                _ = self.run(["-s", serial, "shell", "am", "force-stop", packageName], timeout: 3)
            }
        }
    }

    func handleDetectedDevice(serial: String, settings: AppSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            if settings.autoConfigureAdbReverse {
                self.configureReverse(serial: serial, port: settings.port)
            }
        }
    }

    func prepareForStreaming(serial: String, settings: AppSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            if settings.autoConfigureAdbReverse {
                self.configureReverse(serial: serial, port: settings.port)
            }
            if settings.autoLaunchAndroidClient {
                self.launchAndroidClient(serial: serial, activity: settings.androidLaunchActivity)
            }
        }
    }

    func firstConnectedDeviceSerial() -> String? {
        connectedDeviceSerials().first
    }

    func connectedDeviceSerialsSnapshot() -> [String] {
        connectedDeviceSerials()
    }

    func hasConnectedDevice() -> Bool {
        !connectedDeviceSerials().isEmpty
    }

    func isAndroidClientInstalled(serial: String, packageName: String) -> Bool {
        let output = run(["-s", serial, "shell", "pm", "path", packageName], timeout: 4)
        return output.contains("package:")
    }

    func queryDeviceDisplayName(serial: String) -> String {
        let manufacturer = run(["-s", serial, "shell", "getprop", "ro.product.manufacturer"], timeout: 3)
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = run(["-s", serial, "shell", "getprop", "ro.product.model"], timeout: 3)
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let compact = [manufacturer, model]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !compact.isEmpty {
            return compact
        }
        return serial
    }

    func installAndroidClient(serial: String, apkPath: String) -> Bool {
        let output = run(["-s", serial, "install", "-r", apkPath], timeout: 120)
        return output.contains("Success")
    }

    func buildAndroidDebugApk(androidClientDir: String, javaHome: String) -> Bool {
        let output = runProcess(
            executable: "/usr/bin/env",
            arguments: ["./gradlew", ":app:assembleDebug"],
            workingDirectory: androidClientDir,
            environment: ["JAVA_HOME": javaHome],
            timeout: 600
        )
        return output.contains("BUILD SUCCESSFUL")
    }

    func queryStreamingResolution(serial: String) -> (width: Int, height: Int)? {
        let inputDump = run(["-s", serial, "shell", "dumpsys", "input"], timeout: 4)
        let displayDump = run(["-s", serial, "shell", "dumpsys", "display"], timeout: 4)
        let orientationFromDisplay = parseCurrentOrientation(from: displayDump)
        let orientationFromInput = parseCurrentOrientation(from: inputDump)
        let orientation = orientationFromDisplay ?? orientationFromInput
        let physical = parseResolution(from: run(["-s", serial, "shell", "wm", "size"], timeout: 2))

        let viewport = parseActiveViewportResolution(from: inputDump)
        let logical = parseLogicalFrameResolution(from: displayDump)

        let resolved: (width: Int, height: Int)?
        if let viewport {
            resolved = normalizeForOrientation(viewport, orientation: orientation)
        } else if let logical {
            resolved = normalizeForOrientation(logical, orientation: orientation)
        } else if let physical {
            resolved = normalizeForOrientation(physical, orientation: orientation)
        } else {
            resolved = nil
        }

        logger.info(
            "resolution probe serial=\(serial, privacy: .public) orientation(display)=\(self.describeOrientation(orientationFromDisplay), privacy: .public) orientation(input)=\(self.describeOrientation(orientationFromInput), privacy: .public) chosen=\(self.describeOrientation(orientation), privacy: .public) viewport=\(self.describeResolution(viewport), privacy: .public) logical=\(self.describeResolution(logical), privacy: .public) wmSize=\(self.describeResolution(physical), privacy: .public) resolved=\(self.describeResolution(resolved), privacy: .public)"
        )

        return resolved
    }

    func queryDeviceDensityDpi(serial: String) -> Int? {
        let densityOutput = run(["-s", serial, "shell", "wm", "density"], timeout: 2)
        if let parsed = parseDensityDpi(from: densityOutput) {
            logger.info("density probe serial=\(serial, privacy: .public) wmDensity=\(parsed)")
            return parsed
        }
        return nil
    }

    private func describeResolution(_ value: (width: Int, height: Int)?) -> String {
        guard let value else { return "n/a" }
        return "\(value.width)x\(value.height)"
    }

    private func describeOrientation(_ value: Int?) -> String {
        guard let value else { return "n/a" }
        switch value {
        case 0: return "0(portrait)"
        case 1: return "1(landscape)"
        case 2: return "2(reverse-portrait)"
        case 3: return "3(reverse-landscape)"
        default: return "\(value)(unknown)"
        }
    }

    private func connectedDeviceSerials() -> [String] {
        let output = run(["devices"], timeout: 2)
        return output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let parts = line.split(separator: "\t")
                guard parts.count >= 2, parts[1] == "device" else { return nil }
                return String(parts[0])
            }
    }

    private func parseResolution(from output: String) -> (width: Int, height: Int)? {
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: #"(\d+)\s*x\s*(\d+)"#, options: .regularExpression) else {
                continue
            }
            let token = String(line[range])
            let parts = token.split(separator: "x")
            guard parts.count == 2,
                  let width = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let height = Int(parts[1].trimmingCharacters(in: .whitespaces))
            else {
                continue
            }
            return (width, height)
        }
        return nil
    }

    private func parseLogicalFrameResolution(from output: String) -> (width: Int, height: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"logicalFrame=Rect\(\d+,\s*\d+\s*-\s*(\d+),\s*(\d+)\)"#) else {
            return nil
        }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        var best: (Int, Int)?
        var bestArea = 0
        for match in matches where match.numberOfRanges >= 3 {
            guard
                let width = Int(nsOutput.substring(with: match.range(at: 1))),
                let height = Int(nsOutput.substring(with: match.range(at: 2)))
            else { continue }
            let area = width * height
            if area > bestArea {
                bestArea = area
                best = (width, height)
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    private func parseActiveViewportResolution(from output: String) -> (width: Int, height: Int)? {
        let lines = output.split(separator: "\n").map(String.init)
        for line in lines {
            guard line.contains("Viewport"), line.contains("isActive=[1]") else { continue }
            guard
                let range = line.range(
                    of: #"logicalFrame=\[(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\]"#,
                    options: .regularExpression
                )
            else {
                continue
            }
            let token = String(line[range])
                .replacingOccurrences(of: "logicalFrame=[", with: "")
                .replacingOccurrences(of: "]", with: "")
            let parts = token.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard
                parts.count == 4,
                let x0 = Int(parts[0]),
                let y0 = Int(parts[1]),
                let x1 = Int(parts[2]),
                let y1 = Int(parts[3]),
                x1 > x0,
                y1 > y0
            else {
                continue
            }
            return (x1 - x0, y1 - y0)
        }
        return nil
    }

    private func parseCurrentOrientation(from output: String) -> Int? {
        let patterns = [
            #"mCurrentOrientation=(\d+)"#,
            #"\borientation=(\d+)\b"#,
            #"\bmRotation=(\d+)\b"#,
            #"\brotation=(\d+)\b"#,
        ]
        for pattern in patterns {
            guard let range = output.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let token = String(output[range])
            if let value = token.split(separator: "=").last.flatMap({ Int($0) }), (0...3).contains(value) {
                return value
            }
        }
        return nil
    }

    private func normalizeForOrientation(
        _ resolution: (width: Int, height: Int),
        orientation: Int?
    ) -> (width: Int, height: Int) {
        guard let orientation else { return resolution }
        let shouldBeLandscape = (orientation == 1 || orientation == 3)
        if shouldBeLandscape && resolution.width < resolution.height {
            return (resolution.height, resolution.width)
        }
        if !shouldBeLandscape && resolution.width > resolution.height {
            return (resolution.height, resolution.width)
        }
        return resolution
    }

    private func parseDensityDpi(from output: String) -> Int? {
        var parsed: Int?
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: #"(\d+)"#, options: .regularExpression) else {
                continue
            }
            let token = String(line[range])
            guard let value = Int(token), value >= 72, value <= 1000 else {
                continue
            }
            parsed = value
            if line.lowercased().contains("override") {
                return value
            }
        }
        return parsed
    }

    @discardableResult
    private func run(_ arguments: [String], timeout: TimeInterval = 5) -> String {
        runProcess(
            executable: "/usr/bin/env",
            arguments: ["adb"] + arguments,
            timeout: timeout
        )
    }

    @discardableResult
    private func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval = 5
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        let tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cablecanvas-process-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        guard let outputHandle = FileHandle(forWritingAtPath: tempFileURL.path) else {
            return ""
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
            let waitResult = done.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
                process.terminate()
                _ = done.wait(timeout: .now() + 1)
                try? outputHandle.close()
                try? FileManager.default.removeItem(at: tempFileURL)
                return ""
            }
            try? outputHandle.close()
            let data = (try? Data(contentsOf: tempFileURL)) ?? Data()
            try? FileManager.default.removeItem(at: tempFileURL)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: tempFileURL)
            return ""
        }
    }
}
