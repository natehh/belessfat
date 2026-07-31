import Foundation

enum AppConfig {
    static var usdaAPIKey: String {
        if let key = Bundle.main.object(forInfoDictionaryKey: "USDA_API_KEY") as? String, !key.isEmpty, key != "YOUR_KEY_HERE" {
            return key
        }
        if let key = ProcessInfo.processInfo.environment["USDA_API_KEY"], !key.isEmpty {
            return key
        }
        return "DEMO_KEY"
    }

    static let offUserAgent = "belessfat/1.0 (iOS; local-only macro tracker)"
    static let usdaBaseURL = "https://api.nal.usda.gov/fdc/v1"
    static let offBaseURL = "https://world.openfoodfacts.org/api/v2"
    static let wgerBaseURL = "https://wger.de/api/v2"
}
