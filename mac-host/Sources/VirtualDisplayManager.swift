import Foundation
import VirtualDisplayBridge

struct VirtualDisplayConfig {
    let name: String
    let width: Int
    let height: Int
    let refreshRate: Int
    let ppi: Int
    let hiDPI: Bool
    let mirrorMain: Bool
}

enum VirtualDisplayManager {
    static func create(config: VirtualDisplayConfig) -> Bool {
        let width = max(config.width, 640)
        let height = max(config.height, 360)
        let refreshRate = max(config.refreshRate, 24)
        let ppi = max(config.ppi, 72)

        return config.name.withCString { cName in
            cc_create_virtual_display(
                UInt32(width),
                UInt32(height),
                UInt32(refreshRate),
                UInt32(ppi),
                config.hiDPI,
                config.mirrorMain,
                cName
            )
        }
    }

    static func destroy() -> Bool {
        cc_destroy_virtual_display()
    }

    static var isActive: Bool {
        cc_is_virtual_display_active()
    }

    static var displayID: UInt32 {
        cc_virtual_display_id()
    }
}
