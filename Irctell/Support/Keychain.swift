import Foundation
import Security

/// Network passwords live in the login keychain, never in the networks file.
enum Keychain {
    private static let service = "dev.verhas.Irctell"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the password, or deletes it when nil or empty.
    static func setPassword(_ password: String?, for account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let password, !password.isEmpty else {
            SecItemDelete(match as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Irctell: \(account)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
