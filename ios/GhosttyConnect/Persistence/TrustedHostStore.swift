import Foundation

struct TrustedHost: Equatable, Identifiable, Sendable {
    let id: String
    let hostname: String?
    let port: Int?
    let algorithm: String?
    let fingerprint: String?
    let error: String?

    var destination: String {
        guard let hostname, let port else { return id }
        return hostname.contains(":") ? "[\(hostname)]:\(port)" : "\(hostname):\(port)"
    }
}

protocol KnownHostPersistence: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
    func accounts(prefix: String) throws -> [String]
}

struct KeychainKnownHostPersistence: KnownHostPersistence {
    private let store: SecureStore

    init(store: SecureStore = SecureStore()) {
        self.store = store
    }

    func read(account: String) throws -> Data? { try store.readData(account: account) }
    func write(_ data: Data, account: String) throws { try store.writeData(data, account: account) }
    func delete(account: String) throws { try store.delete(account: account) }
    func accounts(prefix: String) throws -> [String] { try store.accounts(prefix: prefix) }
}

struct KeychainKnownHostStore: KnownHostStore {
    private let persistence: any KnownHostPersistence

    init(persistence: any KnownHostPersistence = KeychainKnownHostPersistence()) {
        self.persistence = persistence
    }

    func read(account: String) throws -> String? {
        try Self.withLock {
            guard let data = try persistence.read(account: account) else { return nil }
            return try JSONDecoder().decode(String.self, from: data)
        }
    }

    func write(_ key: String, account: String) throws {
        try Self.withLock {
            _ = try parseKnownHostAccount(account)
            _ = try SSHHostKeyDetails.inspect(openSSHKey: key)
            try persistence.write(JSONEncoder().encode(key), account: account)
        }
    }

    func records() throws -> [TrustedHost] {
        try Self.withLock {
            try persistence.accounts(prefix: Self.accountPrefix).map { account in
                let destination = try? parseKnownHostAccount(account)
                do {
                    guard let data = try persistence.read(account: account) else {
                        return invalidRecord(account: account, destination: destination, message: "Key data is missing.")
                    }
                    let key = try JSONDecoder().decode(String.self, from: data)
                    let details = try SSHHostKeyDetails.inspect(openSSHKey: key)
                    return TrustedHost(
                        id: account,
                        hostname: destination?.hostname,
                        port: destination?.port,
                        algorithm: details.algorithm,
                        fingerprint: details.fingerprint,
                        error: destination == nil ? "The saved destination is invalid." : nil
                    )
                } catch {
                    return invalidRecord(
                        account: account,
                        destination: destination,
                        message: error.localizedDescription
                    )
                }
            }.sorted {
                $0.destination.localizedCaseInsensitiveCompare($1.destination) == .orderedAscending
            }
        }
    }

    func remove(account: String) throws {
        try Self.withLock {
            try persistence.delete(account: account)
        }
    }

    private func invalidRecord(
        account: String,
        destination: KnownHostDestination?,
        message: String
    ) -> TrustedHost {
        TrustedHost(
            id: account,
            hostname: destination?.hostname,
            port: destination?.port,
            algorithm: nil,
            fingerprint: nil,
            error: message
        )
    }

    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static let lock = NSLock()
    private static let accountPrefix = "known-host:"
}

private struct KnownHostDestination {
    let hostname: String
    let port: Int
}

private struct TrustedHostAccountError: LocalizedError {
    var errorDescription: String? { "A trusted-host record has an invalid destination." }
}

private func parseKnownHostAccount(_ account: String) throws -> KnownHostDestination {
    let prefix = "known-host:"
    guard account.hasPrefix(prefix),
          let separator = account.lastIndex(of: ":"),
          separator > account.index(account.startIndex, offsetBy: prefix.count),
          let port = Int(account[account.index(after: separator)...]),
          (1...65535).contains(port) else {
        throw TrustedHostAccountError()
    }
    return KnownHostDestination(
        hostname: String(account[account.index(account.startIndex, offsetBy: prefix.count)..<separator]),
        port: port
    )
}
