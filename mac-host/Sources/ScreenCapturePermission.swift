import CoreGraphics
import Foundation

enum ScreenCapturePermission {
    static func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

