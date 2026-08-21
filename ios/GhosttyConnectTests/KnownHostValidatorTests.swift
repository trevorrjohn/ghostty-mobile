import XCTest
@testable import GhosttyConnect

final class KnownHostValidatorTests: XCTestCase {
    func testRequestsApprovalOnFirstUse() {
        XCTAssertEqual(KnownHostDecision.decide(stored: nil, presented: "key-a"), .unknown)
        XCTAssertEqual(KnownHostDecision.decide(stored: "", presented: "key-a"), .unknown)
    }

    func testAcceptsMatchingKey() {
        XCTAssertEqual(KnownHostDecision.decide(stored: "key-a", presented: "key-a"), .trusted)
    }

    func testRejectsChangedKey() {
        XCTAssertEqual(KnownHostDecision.decide(stored: "key-a", presented: "key-b"), .changed)
    }

    func testComputesFullSHA256Fingerprint() throws {
        let details = try SSHHostKeyDetails.inspect(openSSHKey: "ssh-ed25519 AQIDBA== comment")

        XCTAssertEqual(details.algorithm, "ssh-ed25519")
        XCTAssertEqual(details.fingerprint, "SHA256:n2SnR+G5fxMfq7a0Rylsm28CAeefs8U1bmx36JtqgGo")
    }

    func testTrustResponseIsDeliveredExactlyOnce() {
        let answers = LockedValues<Bool>()
        let request = HostTrustRequest(
            destination: "example.com:22",
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:test",
            previousFingerprint: nil,
            status: .unknown,
            response: { answer in answers.append(answer) }
        )

        request.answer(accepted: true)
        request.answer(accepted: false)

        XCTAssertEqual(answers.values, [true])
    }

    func testUnknownKeyIsStoredOnlyAfterApproval() throws {
        let store = InMemoryKnownHostStore()
        let requests = LockedValues<HostTrustRequest>()
        let results = LockedValues<Result<Void, Error>>()
        let validator = KeychainHostKeyValidator(
            host: "example.com",
            port: 22,
            store: store,
            requestApproval: { request in requests.append(request) }
        )

        validator.validate(presented: testKeyA) { result in results.append(result) }

        XCTAssertNil(try store.read(account: "known-host:example.com:22"))
        XCTAssertEqual(requests.values.single?.status, .unknown)
        requests.values.single?.answer(accepted: true)
        XCTAssertEqual(try store.read(account: "known-host:example.com:22"), testKeyA)
        XCTAssertTrue(results.values.single?.isSuccess == true)
    }

    func testChangedKeyRejectionPreservesStoredKey() throws {
        let store = InMemoryKnownHostStore()
        try store.write(testKeyA, account: "known-host:example.com:22")
        let requests = LockedValues<HostTrustRequest>()
        let results = LockedValues<Result<Void, Error>>()
        let validator = KeychainHostKeyValidator(
            host: "example.com",
            port: 22,
            store: store,
            requestApproval: { request in requests.append(request) }
        )

        validator.validate(presented: testKeyB) { result in results.append(result) }
        XCTAssertEqual(requests.values.single?.status, .changed)
        requests.values.single?.answer(accepted: false)

        XCTAssertEqual(try store.read(account: "known-host:example.com:22"), testKeyA)
        XCTAssertTrue(results.values.single?.isFailure == true)
    }

    func testChangedKeyApprovalReplacesStoredKey() throws {
        let store = InMemoryKnownHostStore()
        try store.write(testKeyA, account: "known-host:example.com:22")
        let requests = LockedValues<HostTrustRequest>()
        let results = LockedValues<Result<Void, Error>>()
        let validator = KeychainHostKeyValidator(
            host: "example.com",
            port: 22,
            store: store,
            requestApproval: { request in requests.append(request) }
        )

        validator.validate(presented: testKeyB) { result in results.append(result) }
        requests.values.single?.answer(accepted: true)

        XCTAssertEqual(try store.read(account: "known-host:example.com:22"), testKeyB)
        XCTAssertTrue(results.values.single?.isSuccess == true)
    }

    func testCancellationRejectsPendingApprovalWithoutWriting() throws {
        let store = InMemoryKnownHostStore()
        let requests = LockedValues<HostTrustRequest>()
        let results = LockedValues<Result<Void, Error>>()
        let validator = KeychainHostKeyValidator(
            host: "example.com",
            port: 22,
            store: store,
            requestApproval: { request in requests.append(request) }
        )

        validator.validate(presented: testKeyA) { result in results.append(result) }
        validator.cancelPendingRequest()

        XCTAssertNil(try store.read(account: "known-host:example.com:22"))
        XCTAssertTrue(results.values.single?.isFailure == true)
        requests.values.single?.answer(accepted: true)
        XCTAssertNil(try store.read(account: "known-host:example.com:22"))
    }

    func testCancelledValidatorRejectsPreviouslyTrustedKey() throws {
        let store = InMemoryKnownHostStore()
        try store.write(testKeyA, account: "known-host:example.com:22")
        let requests = LockedValues<HostTrustRequest>()
        let results = LockedValues<Result<Void, Error>>()
        let validator = KeychainHostKeyValidator(
            host: "example.com",
            port: 22,
            store: store,
            requestApproval: { request in requests.append(request) }
        )

        validator.cancelPendingRequest()
        validator.validate(presented: testKeyA) { result in results.append(result) }

        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertTrue(results.values.single?.isFailure == true)
    }
}

private let testKeyA = "ssh-ed25519 AQIDBA=="
private let testKeyB = "ssh-ed25519 BQYHCA=="

private final class InMemoryKnownHostStore: KnownHostStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func write(_ key: String, account: String) throws {
        lock.lock()
        values[account] = key
        lock.unlock()
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool { !isSuccess }
}
