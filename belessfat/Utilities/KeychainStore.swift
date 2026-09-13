import Foundation
import Security

enum KeychainStore {
    private static let service = "com.belessfat.app"

    enum Account: String {
        case cursorAPIKey = "cursor_api_key"
        case openAIAPIKey = "openai_api_key"
        case anthropicAPIKey = "anthropic_api_key"
        case geminiAPIKey = "gemini_api_key"
    }

    static func set(_ value: String, account: Account) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func get(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasKey(for provider: AIProvider) -> Bool {
        guard let value = get(provider.keychainAccount) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return "Keychain error (\(status))"
            }
        }
    }
}

enum FoodEstimateAgentStore {
    private static let agentIdKey = "cursorFoodEstimateAgentIdV2"

    static var agentId: String? {
        get { UserDefaults.standard.string(forKey: agentIdKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: agentIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: agentIdKey)
            }
        }
    }
}

enum RecipeImportAgentStore {
    private static let agentIdKey = "cursorRecipeImportAgentId"

    static var agentId: String? {
        get { UserDefaults.standard.string(forKey: agentIdKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: agentIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: agentIdKey)
            }
        }
    }
}

enum BodyFatEstimateAgentStore {
    private static let agentIdKey = "cursorBodyFatEstimateAgentId"

    static var agentId: String? {
        get { UserDefaults.standard.string(forKey: agentIdKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: agentIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: agentIdKey)
            }
        }
    }
}

enum CursorStandingAgents {
    static func clearAll() {
        FoodEstimateAgentStore.agentId = nil
        RecipeImportAgentStore.agentId = nil
        BodyFatEstimateAgentStore.agentId = nil
    }
}
