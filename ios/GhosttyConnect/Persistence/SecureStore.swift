import Foundation
import Security

enum SecureStoreError: LocalizedError {
    case keychain(OSStatus)
    case oversizedData

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain error \(status)"
        case .oversizedData: "Stored data exceeds the supported size."
        }
    }
}

struct SecureStore {
    private let service = "fail.founder.terminal"

    func read<T: Decodable>(
        _ type: T.Type,
        account: String,
        default defaultValue: T,
        maximumBytes: Int? = nil
    ) throws -> T {
        guard let data = try readData(account: account) else { return defaultValue }
        if let maximumBytes, data.count > maximumBytes { throw SecureStoreError.oversizedData }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func readData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecureStoreError.keychain(status) }
        return data
    }

    func write<T: Encodable>(_ value: T, account: String) throws {
        try writeData(JSONEncoder().encode(value), account: account)
    }

    func writeData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecureStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw SecureStoreError.keychain(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychain(status)
        }
    }

    func accounts(prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        let items = result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
