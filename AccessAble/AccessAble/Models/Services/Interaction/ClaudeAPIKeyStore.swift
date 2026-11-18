import Foundation
import Security

/// Owner: User Interaction (3.1). The Claude API key for the voice agent, kept in the
/// Keychain (entered in Settings). During development `ANTHROPIC_API_KEY` in the Xcode
/// scheme's environment is used when no key has been saved, so nobody has to commit one.
enum ClaudeAPIKeyStore {
    /// Posted on the main thread after the key is saved or removed.
    static let didChange = Notification.Name("ClaudeAPIKeyStore.didChange")

    private static let service = "AccessAble.ClaudeAPIKey"
    private static let account = "default"

    static var current: String? {
        if let saved = savedKey, !saved.isEmpty { return saved }
        let environment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return environment?.isEmpty == false ? environment : nil
    }

    static var hasSavedKey: Bool { savedKey?.isEmpty == false }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        if saved { NotificationCenter.default.post(name: didChange, object: nil) }
        return saved
    }

    static func remove() {
        SecItemDelete(baseQuery as CFDictionary)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static var savedKey: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
