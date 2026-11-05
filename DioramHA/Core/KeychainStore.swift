import Foundation
import Security

enum KeychainStore {
    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.codeorbita.dioramha.connection",
            kSecAttrAccount as String: "default",
        ]
    }

    static func load() -> ConnectionSettings? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ConnectionSettings.self, from: data)
    }

    static func save(_ settings: ConnectionSettings) throws {
        let data = try JSONEncoder().encode(settings)
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
