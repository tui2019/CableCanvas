import Foundation
import os

final class FrameStreamer: @unchecked Sendable {
    private let transport: FrameTransportServer
    private var timer: DispatchSourceTimer?
    private let streamQueue = DispatchQueue(label: "com.cablecanvas.streamer.frames")
    private let controlQueue = DispatchQueue(label: "com.cablecanvas.streamer.control")
    private let logger = Logger(subsystem: "CableCanvasHost", category: "FrameStreamer")
    private var sentFrames: UInt64 = 0
    private var waitingForClientLogged = false

    private(set) var isRunning = false
    private var frameSource: FrameSource?

    init(transport: FrameTransportServer) {
        self.transport = transport
    }

    func start(settings: AppSettings, completion: @escaping @Sendable (Error?) -> Void) {
        controlQueue.async {
            guard !self.isRunning else {
                completion(nil)
                return
            }

            let frameSource = FrameSourceFactory.make(settings: settings)
            do {
                try frameSource.prepare()
                try self.transport.start(host: settings.host, port: UInt16(settings.port))
            } catch {
                frameSource.stop()
                completion(error)
                return
            }

            let fps = max(settings.fps, 0.1)
            let timer = DispatchSource.makeTimerSource(queue: self.streamQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(Int(1000.0 / fps)))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if !self.transport.hasClient {
                    if !self.waitingForClientLogged {
                        print("[streamer] waiting for Android client connection")
                        self.waitingForClientLogged = true
                    }
                    return
                }
                self.waitingForClientLogged = false
                do {
                    let frame = try frameSource.nextFrame()
                    let packet = FrameProtocol.encode(frame: frame)
                    self.transport.send(packet)
                    self.sentFrames += 1
                    if self.sentFrames <= 5 || self.sentFrames.isMultiple(of: 120) {
                        self.logger.info(
                            "sent frame #\(self.sentFrames) codec=\(frame.codec.rawValue) flags=\(frame.flags) size=\(frame.width)x\(frame.height) payload=\(frame.payload.count)"
                        )
                    }
                } catch {
                    print("[streamer] frame error: \(error.localizedDescription)")
                }
            }
            timer.resume()

            self.frameSource = frameSource
            self.timer = timer
            self.isRunning = true
            self.sentFrames = 0
            self.waitingForClientLogged = false
            completion(nil)
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        controlQueue.async {
            self.timer?.cancel()
            self.timer = nil
            self.frameSource?.stop()
            self.frameSource = nil
            self.transport.stop()
            self.isRunning = false
            completion?()
        }
    }
}
