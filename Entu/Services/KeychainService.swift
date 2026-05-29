import Foundation
import Security

/// Namespace for secure Keychain operations (token + database list).
enum KeychainService {
    private static let service = "entu.Entu"

    // MARK: - JWT token

    private static let tokenKey = "jwt-token"

    private static var tokenQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        // Delete any existing token before saving (keychain doesn't support upsert)
        SecItemDelete(tokenQuery as CFDictionary)

        var attributes = tokenQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadToken() -> String? {
        var query = tokenQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }

        return String(data: data, encoding: .utf8)
    }

    static func deleteToken() {
        SecItemDelete(tokenQuery as CFDictionary)
    }

    // MARK: - Token expiry (ISO 8601 string)

    private static let tokenExpiryKey = "jwt-token-expiry"

    private static var tokenExpiryQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenExpiryKey,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func saveTokenExpiry(_ expires: String) {
        guard let data = expires.data(using: .utf8) else { return }

        SecItemDelete(tokenExpiryQuery as CFDictionary)

        var attributes = tokenExpiryQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadTokenExpiry() -> String? {
        var query = tokenExpiryQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }

        return String(data: data, encoding: .utf8)
    }

    static func deleteTokenExpiry() {
        SecItemDelete(tokenExpiryQuery as CFDictionary)
    }

    // MARK: - Database list (JSON-encoded)

    /// Keychain key stays as `"accounts"` to avoid invalidating existing stored data.
    private static let databasesKey = "accounts"

    private static var databasesQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: databasesKey,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func saveDatabases(_ data: Data) {
        SecItemDelete(databasesQuery as CFDictionary)

        var attributes = databasesQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadDatabases() -> Data? {
        var query = databasesQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }

        return data
    }

    static func deleteDatabases() {
        SecItemDelete(databasesQuery as CFDictionary)
    }
}
