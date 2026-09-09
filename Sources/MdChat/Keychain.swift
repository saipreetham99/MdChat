import Foundation
import Security

enum Keychain {
    private static let service = "MdChat"
    /// Pre-provider builds stored one key under its own service.
    private static let legacyService = "MdChat.gemini"

    static func read(_ account: String) -> String? {
        if let value = read(service: service, account: account) { return value }
        if account == Provider.gemini.rawValue,
           let migrated = read(service: legacyService, account: "api-key") {
            write(migrated, account: account)
            return migrated
        }
        return nil
    }

    static func write(_ value: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query(service: service, account: account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(service: String, account: String) -> String? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
