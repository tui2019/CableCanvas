import Foundation

enum FrameCodec: UInt8 {
    case jpeg = 1
    case h264 = 2
}

struct EncodedFrame {
    let codec: FrameCodec
    let flags: UInt8
    let width: Int
    let height: Int
    let payload: Data
}

enum FrameProtocol {
    private static let magic = Data("CCF2".utf8)

    static func encode(frame: EncodedFrame) -> Data {
        var header = magic
        header.append(frame.codec.rawValue)
        header.append(frame.flags)
        var reserved: UInt16 = 0
        withUnsafeBytes(of: &reserved) { bytes in
            header.append(contentsOf: bytes)
        }
        var width = UInt32(max(frame.width, 0)).bigEndian
        withUnsafeBytes(of: &width) { bytes in
            header.append(contentsOf: bytes)
        }
        var height = UInt32(max(frame.height, 0)).bigEndian
        withUnsafeBytes(of: &height) { bytes in
            header.append(contentsOf: bytes)
        }
        var length = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            header.append(contentsOf: bytes)
        }
        header.append(frame.payload)
        return header
    }
}
