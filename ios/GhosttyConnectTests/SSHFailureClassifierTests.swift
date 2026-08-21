import XCTest
@testable import GhosttyConnect

final class SSHFailureClassifierTests: XCTestCase {
    func testClassifiesAuthenticationFailures() {
        let failure = SSHFailureClassifier.classify(
            SSHConnectionError.authenticationFailed("user@example.com:22"),
            destination: "user@example.com:22"
        )

        XCTAssertEqual(failure.kind, .authentication)
        XCTAssertTrue(failure.canRetry)
        XCTAssertTrue(failure.message.contains("Authentication failed"))
    }

    func testClassifiesInvalidKeysAsConfigurationFailures() {
        let failure = SSHFailureClassifier.classify(
            SSHTransportError.invalidPrivateKey,
            destination: "user@example.com:22"
        )

        XCTAssertEqual(failure.kind, .configuration)
        XCTAssertFalse(failure.canRetry)
    }

    func testAllowsFreshCredentialAfterMissingPasswordOrWrongPassphrase() {
        let missingPassword = SSHFailureClassifier.classify(
            SSHTransportError.missingPassword,
            destination: "user@example.com:22"
        )
        let wrongPassphrase = SSHFailureClassifier.classify(
            SSHTransportError.keyDecryptionFailed,
            destination: "user@example.com:22"
        )

        XCTAssertEqual(missingPassword.kind, .authentication)
        XCTAssertTrue(missingPassword.canRetry)
        XCTAssertEqual(wrongPassphrase.kind, .authentication)
        XCTAssertTrue(wrongPassphrase.canRetry)
    }

    func testMethodIncompatibilityRequiresProfileEdit() {
        let failure = SSHFailureClassifier.classify(
            SSHConnectionError.passwordNotSupported("user@example.com:22"),
            destination: "user@example.com:22"
        )

        XCTAssertEqual(failure.kind, .configuration)
        XCTAssertFalse(failure.canRetry)
    }

    func testSanitizesUnknownConnectionErrors() {
        let failure = SSHFailureClassifier.classify(
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret implementation detail"]),
            destination: "user@example.com:22"
        )

        XCTAssertEqual(failure.kind, .network)
        XCTAssertFalse(failure.message.contains("secret implementation detail"))
        XCTAssertTrue(failure.message.contains("user@example.com:22"))
    }
}

@MainActor
final class TerminalSessionRetryTests: XCTestCase {
    func testRetryBeforeFirstShellUsesFreshTransportWithoutReconnectMarker() async {
        let factory = StubTransportFactory(errors: [
            SSHConnectionError.authenticationFailed("user@example.com:22"),
            nil,
        ])
        let session = TerminalSessionModel { factory.make() }
        var host = Host()
        host.hostname = "example.com"
        host.username = "user"

        await session.connect(to: host, secret: "wrong")
        guard case .failed(let failure) = session.state else {
            return XCTFail("Expected the first attempt to fail")
        }
        XCTAssertEqual(failure.kind, .authentication)

        await session.connect(to: host, secret: "fresh", isReconnect: true)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(factory.createdCount, 2)
        let visibleText = session.snapshot?.cells.map(\.text).joined() ?? ""
        XCTAssertFalse(visibleText.contains("new SSH shell"))
        await session.disconnect()
    }

    func testReconnectAfterEstablishedShellMarksNewShell() async {
        let factory = StubTransportFactory(errors: [nil, nil])
        let session = TerminalSessionModel { factory.make() }
        var host = Host()
        host.hostname = "example.com"
        host.username = "user"

        await session.connect(to: host, secret: "first")
        await session.disconnect()
        await session.connect(to: host, secret: "fresh", isReconnect: true)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(factory.createdCount, 2)
        let visibleText = session.snapshot?.cells.map(\.text).joined() ?? ""
        XCTAssertTrue(visibleText.contains("new SSH shell"))
        await session.disconnect()
    }
}

private final class StubTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error?]
    private(set) var createdCount = 0

    init(errors: [Error?]) {
        self.errors = errors
    }

    func make() -> any SSHTransport {
        lock.lock()
        let error = errors.isEmpty ? nil : errors.removeFirst()
        createdCount += 1
        lock.unlock()
        return StubTransport(connectError: error)
    }
}

private final class StubTransport: SSHTransport {
    let output: AsyncThrowingStream<Data, Error>
    let hostTrustRequests: AsyncStream<HostTrustRequest>
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let trustContinuation: AsyncStream<HostTrustRequest>.Continuation
    private let connectError: Error?

    init(connectError: Error?) {
        self.connectError = connectError
        var outputContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { outputContinuation = $0 }
        self.outputContinuation = outputContinuation
        var trustContinuation: AsyncStream<HostTrustRequest>.Continuation!
        hostTrustRequests = AsyncStream { trustContinuation = $0 }
        self.trustContinuation = trustContinuation
    }

    func connect(to host: Host, credential: SSHCredential) async throws {
        if let connectError { throw connectError }
    }

    func write(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}

    func disconnect() async {
        outputContinuation.finish()
        trustContinuation.finish()
    }
}
