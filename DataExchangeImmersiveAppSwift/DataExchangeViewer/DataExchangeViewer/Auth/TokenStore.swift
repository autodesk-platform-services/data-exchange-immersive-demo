//
//  TokenStore.swift
//  DataExchangeViewer
//

import Foundation
import Security

struct TokenStore {
    private let service = "PetrBroz.DataExchangeViewer.tokens"
    private let account = "aps"

    /// Identifies the one item this store owns. Deliberately free of `kSecAttrAccessible`: in a
    /// *search* dictionary that key is a filter, so including it would stop `load` and `clear`
    /// from finding the item unless its accessibility class matched exactly.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Opts into the data protection keychain explicitly rather than relying on it being
            // the only keychain on this platform.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // A refresh token is long-lived, so the two properties worth pinning down are that it
        // never leaves this device (`ThisDeviceOnly` also keeps it out of backups) and that a
        // token refresh still works when the app is resumed before the device has been unlocked.
        // The default, `WhenUnlocked`, is both device-transferable and backup-eligible.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func load() -> StoredTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
