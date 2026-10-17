import Foundation
import Security
import Synchronization

/// Minimal generic-password storage for daemon passwords and relay pairing keys.
/// With `LaunchOptions.isEphemeral`, secrets stay in memory instead.
enum Keychain {
    private static let service = "Garbeo.daemon-password"
    private static let ephemeral = Mutex<[String: String]>([:])

    static func password(for account: String) -> String? {
        secret(service: service, account: account)
    }

    static func setPassword(_ password: String?, for account: String) {
        setSecret(password, service: service, account: account)
    }

    static func secret(service: String, account: String) -> String? {
        if LaunchOptions.isEphemeral { return ephemeral.withLock { $0["\(service)/\(account)"] } }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ value: String?, service: String, account: String) {
        if LaunchOptions.isEphemeral {
            ephemeral.withLock { $0["\(service)/\(account)"] = value?.isEmpty == false ? value : nil }
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
