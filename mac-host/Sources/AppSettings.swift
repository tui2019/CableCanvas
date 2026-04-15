import Foundation

enum StreamSource: String, Codable, CaseIterable, Equatable {
    case jpegImage
    case mainDisplay
    case virtualDisplay

    var displayName: String {
        switch self {
        case .jpegImage: return "JPEG Image"
        case .mainDisplay: return "Main Display"
        case .virtualDisplay: return "Virtual Display"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var host: String = "127.0.0.1"
    var port: Int = 27183
    var fps: Double = 30.0
    var streamSource: StreamSource = .virtualDisplay
    var imagePath: String = ""
    var virtualDisplayEnabled: Bool = false
    var virtualDisplayName: String = "CableCanvas Virtual"
    var virtualDisplayWidth: Int = 1920
    var virtualDisplayHeight: Int = 1080
    var virtualDisplayRefreshRate: Int = 30
    var virtualDisplayHiDPI: Bool = true
    var virtualDisplayMirrorMain: Bool = false
    var autoConfigureAdbReverse: Bool = true
    var autoLaunchAndroidClient: Bool = true
    var androidLaunchActivity: String = "com.cablecanvas.client/.MainActivity"
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "cablecanvas.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return AppSettings()
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
