import XCTest
@testable import GhosttyConnect

final class TrustedHostStoreTests: XCTestCase {
    func testEnumeratesLegacyPinsWithoutChangingThem() throws {
        let persistence = InMemoryKnownHostPersistence()
        try persistence.write(JSONEncoder().encode(testHostKey), account: "known-host:server.example.com:22")
        let store = KeychainKnownHostStore(persistence: persistence)

        let records = try store.records()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].destination, "server.example.com:22")
        XCTAssertEqual(records[0].algorithm, "ssh-ed25519")
        XCTAssertTrue(records[0].fingerprint?.hasPrefix("SHA256:") == true)
        XCTAssertEqual(try store.read(account: records[0].id), testHostKey)
        XCTAssertNotNil(try persistence.read(account: records[0].id))
    }

    func testTrustWritesExactLegacyPinAndDerivesIPv6Metadata() throws {
        let persistence = InMemoryKnownHostPersistence()
        let store = KeychainKnownHostStore(persistence: persistence)

        try store.write(testHostKey, account: "known-host:2001:db8::1:2222")

        XCTAssertEqual(try JSONDecoder().decode(
            String.self,
            from: XCTUnwrap(try persistence.read(account: "known-host:2001:db8::1:2222"))
        ), testHostKey)
        XCTAssertEqual(try store.records().single?.destination, "[2001:db8::1]:2222")
    }

    func testRemovalDeletesAuthoritativePin() throws {
        let persistence = InMemoryKnownHostPersistence()
        let store = KeychainKnownHostStore(persistence: persistence)
        let account = "known-host:server.example.com:22"
        try store.write(testHostKey, account: account)

        try store.remove(account: account)

        XCTAssertNil(try persistence.read(account: account))
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertNil(try store.read(account: account))
    }

    func testCorruptRecordRemainsRemovableAndDoesNotBlockValidHost() throws {
        let persistence = InMemoryKnownHostPersistence()
        let corruptData = Data("{not-json".utf8)
        try persistence.write(corruptData, account: "known-host:broken.example.com:22")
        try persistence.write(JSONEncoder().encode(testHostKey), account: "known-host:server.example.com:22")
        let store = KeychainKnownHostStore(persistence: persistence)

        let records = try store.records()

        XCTAssertEqual(records.count, 2)
        XCTAssertNotNil(records.first { $0.id.contains("broken") }?.error)
        XCTAssertEqual(try store.read(account: "known-host:server.example.com:22"), testHostKey)
        try store.remove(account: "known-host:broken.example.com:22")
        XCTAssertNil(try persistence.read(account: "known-host:broken.example.com:22"))
    }

    func testExternalRemovalAndReplacementAreImmediatelyAuthoritative() throws {
        let persistence = InMemoryKnownHostPersistence()
        let account = "known-host:server.example.com:22"
        let replacement = "ssh-ed25519 BQYHCA=="
        try persistence.write(JSONEncoder().encode(testHostKey), account: account)
        let store = KeychainKnownHostStore(persistence: persistence)

        XCTAssertEqual(try store.read(account: account), testHostKey)
        try persistence.delete(account: account)
        XCTAssertNil(try store.read(account: account))
        try persistence.write(JSONEncoder().encode(replacement), account: account)
        XCTAssertEqual(try store.read(account: account), replacement)
    }
}

private let testHostKey = "ssh-ed25519 AQIDBA=="

private final class InMemoryKnownHostPersistence: KnownHostPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func write(_ data: Data, account: String) throws {
        lock.lock()
        values[account] = data
        lock.unlock()
    }

    func delete(account: String) throws {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }

    func accounts(prefix: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
