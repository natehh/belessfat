import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case openai
    case anthropic
    case gemini
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .cursor: return "Cursor"
        }
    }

    var keychainAccount: KeychainStore.Account {
        switch self {
        case .openai: return .openAIAPIKey
        case .anthropic: return .anthropicAPIKey
        case .gemini: return .geminiAPIKey
        case .cursor: return .cursorAPIKey
        }
    }

    var keyPlaceholder: String {
        "\(displayName) API key"
    }

    var dashboardURL: URL? {
        switch self {
        case .openai:
            return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini:
            return URL(string: "https://aistudio.google.com/apikey")
        case .cursor:
            return URL(string: "https://cursor.com/dashboard/integrations")
        }
    }

    var dashboardLinkTitle: String {
        "Open \(displayName) API keys"
    }

    var settingsFooter: String {
        switch self {
        case .cursor:
            return "Stored in the Keychain on this device. Cursor uses a reused standing cloud agent so later runs skip cold start."
        case .openai, .anthropic, .gemini:
            return "Stored in the Keychain on this device. Used for in-app food photo estimates and recipe import."
        }
    }

    /// Default chat/vision model for direct providers.
    var defaultModelId: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-5"
        case .gemini: return "gemini-2.0-flash"
        case .cursor: return "composer-2.5"
        }
    }

    var usesStandingAgents: Bool { self == .cursor }
}

enum AIProviderStore {
    private static let selectedKey = "aiSelectedProvider"

    static var selected: AIProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: selectedKey),
               let provider = AIProvider(rawValue: raw) {
                return provider
            }
            // Migrate: if only a Cursor key exists from earlier builds, keep using Cursor.
            if KeychainStore.hasKey(for: .cursor),
               !KeychainStore.hasKey(for: .openai),
               !KeychainStore.hasKey(for: .anthropic),
               !KeychainStore.hasKey(for: .gemini) {
                return .cursor
            }
            return .openai
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedKey)
        }
    }

    static var hasConfiguredKey: Bool {
        KeychainStore.hasKey(for: selected)
    }

    static func apiKey(for provider: AIProvider = selected) -> String? {
        KeychainStore.get(provider.keychainAccount)
    }
}
