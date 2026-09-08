import XCTest
@testable import GhosttyConnect

@MainActor
final class TerminalSessionRegistryTests: XCTestCase {
    func testSameHostCreatesIsolatedRuntimeSessions() {
        let registry = TerminalSessionRegistry(networkMonitor: nil)
        let host = Host(alias: "Production", hostname: "example.com", username: "tj")

        let firstID = registry.create(for: host)
        let secondID = registry.create(for: host)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(registry.records.map(\.host.id), [host.id, host.id])
        XCTAssertFalse(registry.record(id: firstID)?.session === registry.record(id: secondID)?.session)
    }

    func testClosingOneSessionLeavesOtherSessionOwned() async {
        let registry = TerminalSessionRegistry(networkMonitor: nil)
        let host = Host(hostname: "example.com", username: "tj")
        let firstID = registry.create(for: host)
        let secondID = registry.create(for: host)

        await registry.close(id: firstID)

        XCTAssertNil(registry.record(id: firstID))
        XCTAssertNotNil(registry.record(id: secondID))
        XCTAssertEqual(registry.records.count, 1)
    }

    func testBackgroundDisconnectRetainsSessionRecordsForManualReconnect() async {
        let registry = TerminalSessionRegistry(networkMonitor: nil)
        let sessionID = registry.create(for: Host(hostname: "example.com", username: "tj"))

        await registry.disconnectForBackground().value

        XCTAssertNotNil(registry.record(id: sessionID))
        XCTAssertEqual(registry.record(id: sessionID)?.session.state, .disconnected)
    }

    func testForegroundActivationCancelsQueuedBackgroundDisconnect() async {
        let transport = RegistryTestTransport()
        let session = TerminalSessionModel(transportFactory: { transport })
        let registry = TerminalSessionRegistry(sessionFactory: { session }, networkMonitor: nil)
        let host = Host(hostname: "example.com", username: "tj")
        registry.create(for: host)
        await session.connect(to: host, secret: "password")

        let task = registry.disconnectForBackground()
        registry.cancelBackgroundDisconnect()
        await task.value

        XCTAssertEqual(session.state, .connected)
        let disconnectCount = await transport.disconnectCount()
        XCTAssertEqual(disconnectCount, 0)
        await session.disconnect()
    }

    func testBackgroundDisconnectStartsAllSessionTeardownsConcurrently() async {
        let firstTransport = BlockingRegistryTestTransport()
        let secondTransport = BlockingRegistryTestTransport()
        let firstSession = TerminalSessionModel(transportFactory: { firstTransport })
        let secondSession = TerminalSessionModel(transportFactory: { secondTransport })
        var queuedSessions = [firstSession, secondSession]
        let registry = TerminalSessionRegistry(
            sessionFactory: { queuedSessions.removeFirst() },
            networkMonitor: nil
        )
        let host = Host(hostname: "example.com", username: "tj")
        registry.create(for: host)
        registry.create(for: host)
        await firstSession.connect(to: host, secret: "password")
        await secondSession.connect(to: host, secret: "password")

        let task = registry.disconnectForBackground()
        await firstTransport.waitForDisconnectStart()
        await secondTransport.waitForDisconnectStart()

        XCTAssertEqual(firstSession.state, .disconnected)
        XCTAssertEqual(secondSession.state, .disconnected)
        await firstTransport.allowDisconnect()
        await secondTransport.allowDisconnect()
        await task.value
    }

    func testIdentityRemainsInUseUntilSessionResourcesClose() async {
        let identityID = UUID()
        let key = StoredKey(id: identityID, name: "test", data: Data("key".utf8), requiresPassphrase: false)
        let transport = RegistryTestTransport()
        let session = TerminalSessionModel(transportFactory: { transport })
        let registry = TerminalSessionRegistry(sessionFactory: { session }, networkMonitor: nil)
        let host = Host(
            hostname: "example.com",
            username: "tj",
            authenticationType: .sshKey,
            identityID: identityID
        )
        registry.create(for: host)

        XCTAssertFalse(registry.isIdentityInUse(identityID))
        await session.connect(to: host, secret: nil, key: key)
        XCTAssertTrue(registry.isIdentityInUse(identityID))

        await session.disconnect()
        XCTAssertFalse(registry.isIdentityInUse(identityID))
    }
}

private final class RegistryTestTransport: SSHTransport {
    let output: AsyncThrowingStream<Data, Error>
    let hostTrustRequests: AsyncStream<HostTrustRequest>
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let trustContinuation: AsyncStream<HostTrustRequest>.Continuation
    private let state = RegistryTestTransportState()

    init() {
        var outputContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { outputContinuation = $0 }
        self.outputContinuation = outputContinuation
        var trustContinuation: AsyncStream<HostTrustRequest>.Continuation!
        hostTrustRequests = AsyncStream { trustContinuation = $0 }
        self.trustContinuation = trustContinuation
    }

    func connect(to host: Host, credential: SSHCredential) async throws {}
    func write(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}

    func disconnect() async {
        await state.disconnect()
        outputContinuation.finish()
        trustContinuation.finish()
    }

    func disconnectCount() async -> Int { await state.disconnectCount }
}

private actor RegistryTestTransportState {
    private(set) var disconnectCount = 0

    func disconnect() {
        disconnectCount += 1
    }
}

private final class BlockingRegistryTestTransport: SSHTransport {
    let output: AsyncThrowingStream<Data, Error>
    let hostTrustRequests: AsyncStream<HostTrustRequest>
    private let state = BlockingRegistryTestTransportState()

    init() {
        output = AsyncThrowingStream { _ in }
        hostTrustRequests = AsyncStream { _ in }
    }

    func connect(to host: Host, credential: SSHCredential) async throws {}
    func write(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func disconnect() async { await state.disconnect() }
    func waitForDisconnectStart() async { await state.waitForDisconnectStart() }
    func allowDisconnect() async { await state.allowDisconnect() }
}

private actor BlockingRegistryTestTransportState {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func disconnect() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForDisconnectStart() async {
        while !started { await Task.yield() }
    }

    func allowDisconnect() {
        continuation?.resume()
        continuation = nil
    }
}
