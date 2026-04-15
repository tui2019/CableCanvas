import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

protocol FrameSource: AnyObject {
    func prepare() throws
    func nextFrame() throws -> EncodedFrame
    func stop()
}

enum FrameSourceFactory {
    static func make(settings: AppSettings) -> FrameSource {
        switch settings.streamSource {
        case .jpegImage:
            return StaticJpegFrameSource(imagePath: settings.imagePath)
        case .mainDisplay:
            return DisplayFrameSource(
                targetFps: max(settings.fps, 1.0),
                sourceName: "main display",
                targetDisplayID: { CGMainDisplayID() }
            )
        case .virtualDisplay:
            return DisplayFrameSource(
                targetFps: max(settings.fps, 1.0),
                sourceName: "virtual display",
                targetDisplayID: { CGDirectDisplayID(VirtualDisplayManager.displayID) }
            )
        }
    }
}

private final class StaticJpegFrameSource: FrameSource {
    private let imagePath: String
    private var cachedJpeg: Data?

    init(imagePath: String) {
        self.imagePath = imagePath
    }

    func prepare() throws {
        let imageURL = URL(fileURLWithPath: imagePath)
        let jpeg = try Data(contentsOf: imageURL)
        guard jpeg.count >= 2, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3001,
                userInfo: [NSLocalizedDescriptionKey: "Selected file is not a JPEG image."]
            )
        }
        cachedJpeg = jpeg
    }

    private func loadJpeg() throws -> Data {
        if let cachedJpeg {
            return cachedJpeg
        }
        try prepare()
        return cachedJpeg ?? Data()
    }

    func nextFrame() throws -> EncodedFrame {
        let payload = try loadJpeg()
        return EncodedFrame(codec: .jpeg, flags: 0, width: 0, height: 0, payload: payload)
    }

    func stop() {}
}

private final class DisplayFrameSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let targetFps: Double
    private let sourceName: String
    private let targetDisplayID: () -> CGDirectDisplayID
    private let outputQueue = DispatchQueue(label: "com.cablecanvas.screencapture.output")
    private let stateQueue = DispatchQueue(label: "com.cablecanvas.screencapture.state")
    private let logger = Logger(subsystem: "CableCanvasHost", category: "FrameSource")
    private let codec = H264Encoder()

    private var stream: SCStream?
    private var latestPixelBuffer: CVPixelBuffer?
    private var lastStreamError: Error?
    private var captureWidth = 0
    private var captureHeight = 0

    init(targetFps: Double, sourceName: String, targetDisplayID: @escaping () -> CGDirectDisplayID) {
        self.targetFps = targetFps
        self.sourceName = sourceName
        self.targetDisplayID = targetDisplayID
        super.init()
    }

    func prepare() throws {
        let setupSemaphore = DispatchSemaphore(value: 0)
        var setupError: Error?

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error {
                setupError = error
                setupSemaphore.signal()
                return
            }

            guard let content else {
                setupError = NSError(
                    domain: "CableCanvas.FrameSource",
                    code: 3007,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to query shareable display content."]
                )
                setupSemaphore.signal()
                return
            }

            let displayID = self.targetDisplayID()
            let shareableSummary = content.displays
                .map { "\($0.displayID):\($0.width)x\($0.height)" }
                .joined(separator: ",")
            self.logger.info(
                "prepare source=\(self.sourceName, privacy: .public) targetID=\(displayID) shareable=[\(shareableSummary, privacy: .public)]"
            )
            guard displayID != 0 else {
                setupError = NSError(
                    domain: "CableCanvas.FrameSource",
                    code: 3002,
                    userInfo: [NSLocalizedDescriptionKey: "Requested \(self.sourceName) is not available."]
                )
                setupSemaphore.signal()
                return
            }

            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                self.logger.error(
                    "target display missing source=\(self.sourceName, privacy: .public) targetID=\(displayID) shareable=[\(shareableSummary, privacy: .public)]"
                )
                setupError = NSError(
                    domain: "CableCanvas.FrameSource",
                    code: 3002,
                    userInfo: [NSLocalizedDescriptionKey: "Requested \(self.sourceName) is not available."]
                )
                setupSemaphore.signal()
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            self.captureWidth = display.width
            self.captureHeight = display.height
            do {
                try self.codec.prepare(width: display.width, height: display.height, fps: self.targetFps)
            } catch {
                setupError = error
                setupSemaphore.signal()
                return
            }
            self.logger.info(
                "starting capture source=\(self.sourceName, privacy: .public) displayID=\(display.displayID) size=\(display.width)x\(display.height)"
            )
            config.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(Int32(max(self.targetFps, 1)))
            )
            config.showsCursor = true
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
            } catch {
                setupError = error
                setupSemaphore.signal()
                return
            }

            stream.startCapture { error in
                if let error {
                    setupError = error
                } else {
                    self.stateQueue.sync {
                        self.stream = stream
                        self.lastStreamError = nil
                    }
                }
                setupSemaphore.signal()
            }
        }

        setupSemaphore.wait()
        if let setupError {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3005,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to start ScreenCaptureKit stream. Check Screen Recording permission.",
                    NSUnderlyingErrorKey: setupError,
                ]
            )
        }
    }

    func nextFrame() throws -> EncodedFrame {
        if let streamError = stateQueue.sync(execute: { lastStreamError }) {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3011,
                userInfo: [
                    NSLocalizedDescriptionKey: "Screen capture stream stopped unexpectedly.",
                    NSUnderlyingErrorKey: streamError,
                ]
            )
        }

        guard let pixelBuffer = stateQueue.sync(execute: { latestPixelBuffer }) else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3006,
                userInfo: [NSLocalizedDescriptionKey: "Waiting for first captured frame..."]
            )
        }

        let encoded = try codec.encode(pixelBuffer: pixelBuffer)
        return EncodedFrame(
            codec: .h264,
            flags: encoded.isKeyFrame ? 1 : 0,
            width: max(captureWidth, CVPixelBufferGetWidth(pixelBuffer)),
            height: max(captureHeight, CVPixelBufferGetHeight(pixelBuffer)),
            payload: encoded.payload
        )
    }

    func stop() {
        let stream = stateQueue.sync { self.stream }
        if let stream {
            let stopSemaphore = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in
                stopSemaphore.signal()
            }
            stopSemaphore.wait()
        }

        stateQueue.sync {
            self.stream = nil
            self.lastStreamError = nil
            self.latestPixelBuffer = nil
        }
        codec.stop()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        stateQueue.sync {
            latestPixelBuffer = imageBuffer
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateQueue.sync {
            self.lastStreamError = error
        }
    }

}

private struct H264EncodedUnit {
    let payload: Data
    let isKeyFrame: Bool
}

private final class H264Encoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var pending: H264EncodedUnit?
    private var pendingError: Error?
    private var waitingSemaphore: DispatchSemaphore?
    private var frameIndex: Int64 = 0
    private var frameTimescale: Int32 = 30

    func prepare(width: Int, height: Int, fps: Double) throws {
        stop()
        var session: VTCompressionSession?
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: h264CompressionOutputCallback,
            refcon: refcon,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3021,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create H.264 encoder session."]
            )
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let maxKeyInterval = max(1, Int32(round(max(fps, 1.0))))
        var keyInterval = maxKeyInterval
        withUnsafePointer(to: &keyInterval) { ptr in
            let cf = CFNumberCreate(nil, .sInt32Type, ptr)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: cf)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        frameIndex = 0
        frameTimescale = max(1, Int32(round(max(fps, 1.0))))
    }

    func encode(pixelBuffer: CVPixelBuffer) throws -> H264EncodedUnit {
        guard let session else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3022,
                userInfo: [NSLocalizedDescriptionKey: "H.264 encoder is not prepared."]
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        pending = nil
        pendingError = nil
        waitingSemaphore = semaphore
        lock.unlock()

        var infoFlags = VTEncodeInfoFlags()
        let pts = CMTime(value: frameIndex, timescale: frameTimescale)
        let duration = CMTime(value: 1, timescale: frameTimescale)
        let forceKeyFrame = frameIndex == 0
        let frameProps: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        frameIndex += 1

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            lock.lock()
            waitingSemaphore = nil
            lock.unlock()
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3025,
                userInfo: [NSLocalizedDescriptionKey: "H.264 encode request failed (status=\(status))."]
            )
        }
        let waitResult = semaphore.wait(timeout: .now() + 1.0)
        if waitResult == .timedOut {
            lock.lock()
            waitingSemaphore = nil
            pending = nil
            pendingError = nil
            lock.unlock()
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3030,
                userInfo: [NSLocalizedDescriptionKey: "H.264 encoder callback timed out."]
            )
        }
        lock.lock()
        let callbackError = pendingError
        let produced = pending
        pendingError = nil
        pending = nil
        lock.unlock()
        if let callbackError {
            throw callbackError
        }
        guard let produced else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3026,
                userInfo: [NSLocalizedDescriptionKey: "H.264 encoder produced no output."]
            )
        }
        return produced
    }

    func stop() {
        lock.lock()
        waitingSemaphore?.signal()
        waitingSemaphore = nil
        pending = nil
        pendingError = nil
        lock.unlock()
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    fileprivate func handleEncodedSample(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        defer {
            let semaphore = waitingSemaphore
            waitingSemaphore = nil
            lock.unlock()
            semaphore?.signal()
        }
        if status != noErr || flags.contains(.frameDropped) {
            pendingError = NSError(
                domain: "CableCanvas.FrameSource",
                code: 3023,
                userInfo: [NSLocalizedDescriptionKey: "H.264 frame encode failed (status=\(status))."]
            )
            return
        }
        guard let sampleBuffer else {
            pendingError = NSError(
                domain: "CableCanvas.FrameSource",
                code: 3024,
                userInfo: [NSLocalizedDescriptionKey: "H.264 encoder returned empty sample."]
            )
            return
        }
        do {
            pending = try extract(sampleBuffer: sampleBuffer)
        } catch {
            pendingError = error
        }
    }

    private func extract(sampleBuffer: CMSampleBuffer) throws -> H264EncodedUnit {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3027,
                userInfo: [NSLocalizedDescriptionKey: "H.264 sample has no data buffer."]
            )
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let isKeyFrame = !notSync

        var totalLength = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: nil
        )
        guard status == kCMBlockBufferNoErr else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3028,
                userInfo: [NSLocalizedDescriptionKey: "Unable to read H.264 block buffer."]
            )
        }

        var output = Data()
        if isKeyFrame, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if let sps = copyParameterSet(format: format, index: 0) {
                appendLengthPrefixed(nalu: sps, to: &output)
            }
            if let pps = copyParameterSet(format: format, index: 1) {
                appendLengthPrefixed(nalu: pps, to: &output)
            }
        }
        var encodedData = Data(count: totalLength)
        encodedData.withUnsafeMutableBytes { dstBytes in
            guard let dst = dstBytes.baseAddress else { return }
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: dst)
        }
        output.append(encodedData)

        guard !output.isEmpty else {
            throw NSError(
                domain: "CableCanvas.FrameSource",
                code: 3029,
                userInfo: [NSLocalizedDescriptionKey: "H.264 encoder output was empty."]
            )
        }
        return H264EncodedUnit(payload: output, isKeyFrame: isKeyFrame)
    }

    private func appendLengthPrefixed(nalu: Data, to output: inout Data) {
        var length = UInt32(nalu.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            output.append(contentsOf: bytes)
        }
        output.append(nalu)
    }

    private func copyParameterSet(format: CMFormatDescription, index: Int) -> Data? {
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetLength = 0
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: index,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetLength,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard status == noErr, let parameterSetPointer, parameterSetLength > 0 else {
            return nil
        }
        return Data(bytes: parameterSetPointer, count: parameterSetLength)
    }
}

private let h264CompressionOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    infoFlags,
    sampleBuffer
in
    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    encoder.handleEncodedSample(status: status, flags: infoFlags, sampleBuffer: sampleBuffer)
}
