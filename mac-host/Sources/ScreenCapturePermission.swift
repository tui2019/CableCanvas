import CoreGraphics
import Foundation

@MainActor
enum ScreenCapturePermission {
    private static var promptedThisLaunch = false

    static func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func requestAccessOncePerLaunchIfNeeded() -> Bool {
        if isAuthorized() {
            return true
        }
        guard !promptedThisLaunch else {
            return false
        }
        promptedThisLaunch = true
        return requestAccess()
    }
}
