import XCTest
@testable import GhosttyConnect

@MainActor
final class TerminalInputSessionTests: XCTestCase {
    func testSearchForwardsToEngineWhileDisconnected() {
        let engine = InputTestEngine()
        engine.searchResult = true
        let session = TerminalSessionModel(engineFactory: { engine })

        XCTAssertTrue(session.search("needle", direction: .previous))
        XCTAssertEqual(engine.searchQuery, "needle")
        XCTAssertEqual(engine.searchDirection, .previous)
        XCTAssertNotNil(session.snapshot)
    }

    func testRapidInputWritesRemainOrdered() async throws {
        let recorder = InputRecorder()
        let transport = RecordingInputTransport(recorder: recorder)
        let session = TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { InputTestEngine() }
        )
        var host = Host()
        host.hostname = "example.com"
        host.username = "user"

        await session.connect(to: host, secret: "password")
        session.send(.text("1"))
        session.send(.text("2"))
        session.send(.text("3"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let values = await recorder.values()
        XCTAssertEqual(values, ["1", "2", "3"])
        await session.disconnect()
    }

    func testInputSequenceUsesOneOrderedTransportWrite() async throws {
        let recorder = InputRecorder()
        let transport = RecordingInputTransport(recorder: recorder)
        let session = TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { InputTestEngine() }
        )
        var host = Host()
        host.hostname = "example.com"
        host.username = "user"

        await session.connect(to: host, secret: "password")
        session.send([.text("prefix"), .text("command")])
        try? await Task.sleep(nanoseconds: 100_000_000)

        let values = await recorder.values()
        XCTAssertEqual(values, ["prefixcommand"])
        await session.disconnect()
    }

    func testPasteUsesTerminalEncodingAndOrderedWriteQueue() async throws {
        let recorder = InputRecorder()
        let transport = RecordingInputTransport(recorder: recorder)
        let session = TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { InputTestEngine() }
        )
        var host = Host()
        host.hostname = "example.com"
        host.username = "user"

        await session.connect(to: host, secret: "password")
        session.send(.text("1"))
        session.paste("two\nlines")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(session.isPasteSafe("two\nlines"))
        let values = await recorder.values()
        XCTAssertEqual(values, ["1", "paste:two\nlines"])
        await session.disconnect()
    }

    func testAllowedRemoteClipboardWriteAppliesImmediately() async throws {
        let transport = LifecycleTransport()
        let engine = InputTestEngine()
        var writes: [TerminalClipboardWrite] = []
        let session = TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { engine },
            clipboardWriter: { writes.append($0) }
        )
        var host = testHost()
        host.remoteClipboard = .allow
        await session.connect(to: host, secret: "password")

        engine.clipboardWrites = [.text("remote"), .clear]
        transport.yieldOutput(Data("output".utf8))

        let applied = await waitUntil { writes == [.text("remote"), .clear] }
        XCTAssertTrue(applied)
        XCTAssertNil(session.pendingClipboardWrite)
        await session.disconnect()
    }

    func testBlockedRemoteClipboardWriteIsDiscarded() async throws {
        let transport = LifecycleTransport()
        let engine = InputTestEngine()
        var writes: [TerminalClipboardWrite] = []
        let session = TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { engine },
            clipboardWriter: { writes.append($0) }
        )
        var host = testHost()
        host.remoteClipboard = .block
        await session.connect(to: host, secret: "password")

        engine.clipboardWrites = [.text("remote")]
        transport.yieldOutput(Data("output".utf8))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(session.pendingClipboardWrite)
        await session.disconnect()
    }

    func testRemoteClipboardPromptAllowsOneWrite() async throws {
        let transport = LifecycleTransport()
        let engine = InputTestEngine()
        var writes: [TerminalClipboardWrite] = []
        let session = TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { engine },
            clipboardWriter: { writes.append($0) }
        )
        var host = testHost()
        host.remoteClipboard = .ask
        await session.connect(to: host, secret: "password")

        engine.clipboardWrites = [.text("remote")]
        transport.yieldOutput(Data("output".utf8))

        let prompted = await waitUntil { session.pendingClipboardWrite != nil }
        XCTAssertTrue(prompted)
        let requestID = try XCTUnwrap(session.pendingClipboardWrite?.id)
        session.answerClipboardWrite(requestID: requestID, accepted: true)
        XCTAssertEqual(writes, [.text("remote")])
        XCTAssertNil(session.pendingClipboardWrite)
        await session.disconnect()
    }

    func testRemoteClipboardPromptCannotApplyAfterDisconnect() async throws {
        let transport = LifecycleTransport()
        let engine = InputTestEngine()
        var writes: [TerminalClipboardWrite] = []
        let session = TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { engine },
            clipboardWriter: { writes.append($0) }
        )
        var host = testHost()
        host.remoteClipboard = .ask
        await session.connect(to: host, secret: "password")

        engine.clipboardWrites = [.text("remote")]
        transport.yieldOutput(Data("output".utf8))
        let prompted = await waitUntil { session.pendingClipboardWrite != nil }
        XCTAssertTrue(prompted)
        let requestID = try XCTUnwrap(session.pendingClipboardWrite?.id)

        await session.disconnect()
        session.answerClipboardWrite(requestID: requestID, accepted: true)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(session.pendingClipboardWrite)
    }

    func testCleanRemoteCloseDisconnectsAndClosesTransport() async throws {
        let transport = LifecycleTransport()
        let session = makeSession(transport)
        await session.connect(to: testHost(), secret: "password")

        transport.finishOutput()

        let disconnected = await waitUntil { session.state == .disconnected }
        let transportClosed = await waitUntil { await transport.disconnectCount() == 1 }
        XCTAssertTrue(disconnected)
        XCTAssertTrue(transportClosed)
    }

    func testRemoteFailurePublishesNetworkFailureAndClosesTransport() async throws {
        let transport = LifecycleTransport()
        let session = makeSession(transport)
        await session.connect(to: testHost(), secret: "password")

        transport.finishOutput(throwing: SSHTransportError.sessionClosed)

        let failed = await waitUntil {
            guard case .failed(let failure) = session.state else { return false }
            return failure.kind == .network
        }
        let transportClosed = await waitUntil { await transport.disconnectCount() == 1 }
        XCTAssertTrue(failed)
        XCTAssertTrue(transportClosed)
    }

    func testNetworkFailureAutomaticallyReconnectsWithReusableKey() async throws {
        let first = LifecycleTransport()
        let second = LifecycleTransport()
        let factory = LifecycleTransportFactory([first, second])
        let key = StoredKey(name: "test", data: Data("key".utf8), requiresPassphrase: false)
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() },
            keyProvider: { id in id == key.id ? key : nil },
            retrySleep: { _ in }
        )
        var host = testHost()
        host.authenticationType = .sshKey
        await session.connect(to: host, secret: nil, key: key)

        first.finishOutput(throwing: SSHTransportError.sessionClosed)

        let reconnected = await waitUntil { session.state == .connected && factory.createdCount == 2 }
        XCTAssertTrue(reconnected)
        XCTAssertTrue(session.hasConnectedShell)
        await session.disconnect()
    }

    func testAutomaticReconnectWaitsForUsableNetwork() async throws {
        let first = LifecycleTransport()
        let second = LifecycleTransport()
        let factory = LifecycleTransportFactory([first, second])
        let key = StoredKey(name: "test", data: Data("key".utf8), requiresPassphrase: false)
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() },
            keyProvider: { id in id == key.id ? key : nil },
            retrySleep: { _ in }
        )
        var host = testHost()
        host.authenticationType = .sshKey
        await session.connect(to: host, secret: nil, key: key)
        session.setNetworkAvailability(.unavailable)

        first.finishOutput()

        let waiting = await waitUntil { session.state == .waitingForNetwork }
        XCTAssertTrue(waiting)
        XCTAssertEqual(factory.createdCount, 1)
        session.setNetworkAvailability(.usable)
        let reconnected = await waitUntil { session.state == .connected && factory.createdCount == 2 }
        XCTAssertTrue(reconnected)
        await session.disconnect()
    }

    func testAutomaticReconnectStopsAtConfiguredAttemptLimit() async throws {
        let first = LifecycleTransport()
        let failedRetry = LifecycleTransport(connectError: SSHTransportError.sessionClosed)
        let factory = LifecycleTransportFactory([first, failedRetry])
        let key = StoredKey(name: "test", data: Data("key".utf8), requiresPassphrase: false)
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() },
            keyProvider: { id in id == key.id ? key : nil },
            retrySleep: { _ in }
        )
        var host = testHost()
        host.authenticationType = .sshKey
        host.retryMaxAttempts = 1
        await session.connect(to: host, secret: nil, key: key)

        first.finishOutput(throwing: SSHTransportError.sessionClosed)

        let exhausted = await waitUntil {
            guard case .failed(let failure) = session.state else { return false }
            return failure.message.contains("stopped after 1 attempt")
        }
        XCTAssertTrue(exhausted)
        XCTAssertEqual(factory.createdCount, 2)
    }

    func testPasswordConnectionNeverRetriesWithoutReauthentication() async throws {
        let transport = LifecycleTransport()
        let factory = LifecycleTransportFactory([transport])
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() },
            retrySleep: { _ in }
        )
        await session.connect(to: testHost(), secret: "password")

        transport.finishOutput(throwing: SSHTransportError.sessionClosed)

        let failed = await waitUntil {
            guard case .failed(let failure) = session.state else { return false }
            return failure.kind == .network
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(factory.createdCount, 1)
    }

    func testPassphraseProtectedKeyNeverRetriesWithoutReauthentication() async throws {
        let transport = LifecycleTransport()
        let factory = LifecycleTransportFactory([transport])
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() },
            retrySleep: { _ in }
        )
        var host = testHost()
        host.authenticationType = .sshKey
        let key = StoredKey(name: "protected", data: Data("key".utf8), requiresPassphrase: true)
        await session.connect(to: host, secret: "passphrase", key: key)

        transport.finishOutput(throwing: SSHTransportError.sessionClosed)

        let failed = await waitUntil {
            guard case .failed(let failure) = session.state else { return false }
            return failure.kind == .network
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(factory.createdCount, 1)
    }

    func testExplicitDisconnectCancelsScheduledAutomaticReconnect() async throws {
        let first = LifecycleTransport()
        let second = LifecycleTransport()
        let factory = LifecycleTransportFactory([first, second])
        let key = StoredKey(name: "test", data: Data("key".utf8), requiresPassphrase: false)
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() },
            keyProvider: { id in id == key.id ? key : nil },
            retrySleep: { _ in try await Task.sleep(nanoseconds: 10_000_000_000) }
        )
        var host = testHost()
        host.authenticationType = .sshKey
        await session.connect(to: host, secret: nil, key: key)
        first.finishOutput(throwing: SSHTransportError.sessionClosed)
        let scheduled = await waitUntil {
            if case .retrying = session.state { return true }
            return false
        }
        XCTAssertTrue(scheduled)

        await session.disconnect()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(factory.createdCount, 1)
    }

    func testDeletedIdentityStopsScheduledAutomaticReconnect() async throws {
        let first = LifecycleTransport()
        let factory = LifecycleTransportFactory([first, LifecycleTransport()])
        let key = StoredKey(name: "test", data: Data("key".utf8), requiresPassphrase: false)
        var availableKey: StoredKey? = key
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() },
            keyProvider: { id in availableKey?.id == id ? availableKey : nil },
            retrySleep: { _ in try await Task.sleep(nanoseconds: 50_000_000) }
        )
        var host = testHost()
        host.authenticationType = .sshKey
        await session.connect(to: host, secret: nil, key: key)

        first.finishOutput(throwing: SSHTransportError.sessionClosed)
        let scheduled = await waitUntil {
            if case .retrying = session.state { return true }
            return false
        }
        XCTAssertTrue(scheduled)
        availableKey = nil

        let revoked = await waitUntil {
            guard case .failed(let failure) = session.state else { return false }
            return failure.kind == .configuration && failure.message.contains("no longer available")
        }
        XCTAssertTrue(revoked)
        XCTAssertEqual(factory.createdCount, 1)
    }

    func testRemoteCloseDoesNotWaitForHungWriteBeforeLeavingConnectedState() async throws {
        let transport = LifecycleTransport(hangWrites: true)
        let session = makeSession(transport)
        await session.connect(to: testHost(), secret: "password")
        session.send(.text("blocked"))
        await transport.waitForWriteStart()

        transport.finishOutput()

        let disconnected = await waitUntil { session.state == .disconnected }
        let transportClosed = await waitUntil { await transport.disconnectCount() == 1 }
        XCTAssertTrue(disconnected)
        XCTAssertTrue(transportClosed)
    }

    func testExplicitDisconnectClosesTransportBeforeWaitingForHungWrite() async throws {
        let transport = LifecycleTransport(hangWrites: true)
        let session = makeSession(transport)
        await session.connect(to: testHost(), secret: "password")
        session.send(.text("blocked"))
        await transport.waitForWriteStart()

        await session.disconnect()

        let disconnectCount = await transport.disconnectCount()
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testDisconnectPreventsReconnectWaitingForOldCleanup() async throws {
        let first = LifecycleTransport(delayDisconnect: true)
        let factory = LifecycleTransportFactory([first, LifecycleTransport()])
        let session = TerminalSessionModel(
            transportFactory: factory.make,
            engineFactory: { InputTestEngine() }
        )
        let host = testHost()
        await session.connect(to: host, secret: "password")
        first.finishOutput()
        await first.waitForDisconnectStart()

        let reconnect = Task { await session.connect(to: host, secret: "password", isReconnect: true) }
        await Task.yield()
        let disconnect = Task { await session.disconnect() }
        await Task.yield()
        await first.allowDisconnect()
        await reconnect.value
        await disconnect.value

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(factory.createdCount, 1)
    }

    private func makeSession(_ transport: LifecycleTransport) -> TerminalSessionModel {
        TerminalSessionModel(
            transportFactory: { transport },
            engineFactory: { InputTestEngine() }
        )
    }

    private func testHost() -> Host {
        var host = Host()
        host.hostname = "example.com"
        host.username = "user"
        return host
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private actor InputRecorder {
    private var recorded: [String] = []

    func append(_ data: Data) async {
        if data == Data("1".utf8) { try? await Task.sleep(nanoseconds: 40_000_000) }
        recorded.append(String(decoding: data, as: UTF8.self))
    }

    func values() -> [String] { recorded }
}

private final class RecordingInputTransport: SSHTransport {
    let output: AsyncThrowingStream<Data, Error>
    let hostTrustRequests: AsyncStream<HostTrustRequest>
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let trustContinuation: AsyncStream<HostTrustRequest>.Continuation
    private let recorder: InputRecorder

    init(recorder: InputRecorder) {
        self.recorder = recorder
        var outputContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { outputContinuation = $0 }
        self.outputContinuation = outputContinuation
        var trustContinuation: AsyncStream<HostTrustRequest>.Continuation!
        hostTrustRequests = AsyncStream { trustContinuation = $0 }
        self.trustContinuation = trustContinuation
    }

    func connect(to host: Host, credential: SSHCredential) async throws {}
    func write(_ data: Data) async throws { await recorder.append(data) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func disconnect() async {
        outputContinuation.finish()
        trustContinuation.finish()
    }
}

private final class LifecycleTransport: SSHTransport {
    let output: AsyncThrowingStream<Data, Error>
    let hostTrustRequests: AsyncStream<HostTrustRequest>
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let trustContinuation: AsyncStream<HostTrustRequest>.Continuation
    private let state: LifecycleTransportState
    private let connectError: Error?

    init(hangWrites: Bool = false, delayDisconnect: Bool = false, connectError: Error? = nil) {
        self.connectError = connectError
        state = LifecycleTransportState(hangWrites: hangWrites, delayDisconnect: delayDisconnect)
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
    func write(_ data: Data) async throws { try await state.write() }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}

    func disconnect() async {
        await state.disconnect()
        outputContinuation.finish()
        trustContinuation.finish()
    }

    func finishOutput(throwing error: Error? = nil) {
        if let error { outputContinuation.finish(throwing: error) }
        else { outputContinuation.finish() }
    }

    func yieldOutput(_ data: Data) {
        outputContinuation.yield(data)
    }

    func waitForWriteStart() async { await state.waitForWriteStart() }
    func waitForDisconnectStart() async { await state.waitForDisconnectStart() }
    func allowDisconnect() async { await state.allowDisconnect() }
    func disconnectCount() async -> Int { await state.disconnectCount }
}

private actor LifecycleTransportState {
    let hangWrites: Bool
    let delayDisconnect: Bool
    private var writeStarted = false
    private var disconnectStarted = false
    private var disconnected = false
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private(set) var disconnectCount = 0

    init(hangWrites: Bool, delayDisconnect: Bool) {
        self.hangWrites = hangWrites
        self.delayDisconnect = delayDisconnect
    }

    func write() async throws {
        guard !disconnected else { throw SSHTransportError.sessionClosed }
        guard hangWrites else { return }
        writeStarted = true
        try await withCheckedThrowingContinuation { writeContinuation = $0 }
    }

    func disconnect() async {
        disconnectCount += 1
        disconnectStarted = true
        disconnected = true
        writeContinuation?.resume(throwing: CancellationError())
        writeContinuation = nil
        if delayDisconnect {
            await withCheckedContinuation { disconnectContinuation = $0 }
        }
    }

    func waitForWriteStart() async {
        while !writeStarted { await Task.yield() }
    }

    func waitForDisconnectStart() async {
        while !disconnectStarted { await Task.yield() }
    }

    func allowDisconnect() {
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }
}

private final class LifecycleTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [LifecycleTransport]
    private(set) var createdCount = 0

    init(_ transports: [LifecycleTransport]) {
        self.transports = transports
    }

    func make() -> any SSHTransport {
        lock.lock()
        defer { lock.unlock() }
        createdCount += 1
        return transports.removeFirst()
    }
}

private final class InputTestEngine: TerminalEngine {
    var searchResult = false
    var clipboardWrites: [TerminalClipboardWrite] = []
    private(set) var searchQuery: String?
    private(set) var searchDirection: TerminalSearchDirection?

    func feed(_ data: Data) {}
    func drainClipboardWrites() -> [TerminalClipboardWrite] {
        defer { clipboardWrites.removeAll(keepingCapacity: true) }
        return clipboardWrites
    }
    func resize(columns: Int, rows: Int) {}

    func encode(event: TerminalInputEvent) throws -> Data {
        guard case .text(let text, _) = event else { return Data() }
        return Data(text.utf8)
    }

    func isPasteSafe(_ text: String) -> Bool { !text.contains("\n") }
    func encodePaste(_ text: String) throws -> Data { Data("paste:\(text)".utf8) }
    func scrollViewport(byRows rows: Int) {}
    func scrollToBottom() {}
    func search(_ query: String, direction: TerminalSearchDirection) -> Bool {
        searchQuery = query
        searchDirection = direction
        return searchResult
    }
    func selectWord(column: Int, row: Int) -> Bool { false }
    func setSelectionEndpoint(start: Bool, column: Int, row: Int) -> Bool { false }
    func selectRange(startColumn: Int, endColumn: Int, row: Int) -> Bool { false }
    func selectOutput(column: Int, row: Int) -> Bool { false }
    func hyperlink(column: Int, row: Int) -> String? { nil }
    func clearSelection() {}
    func selectedText() -> String { "" }

    func visibleText() -> String { "" }

    func snapshot() throws -> TerminalSnapshot {
        let color = TerminalColor(red: 0, green: 0, blue: 0)
        return TerminalSnapshot(
            columns: 1,
            rows: 1,
            foreground: color,
            background: color,
            cursorColor: color,
            cells: [TerminalCell(
                text: " ",
                foreground: color,
                background: color,
                bold: false,
                italic: false,
                faint: false,
                underline: .none,
                strikethrough: false,
                overline: false,
                blinking: false,
                invisible: false,
                selected: false
            )],
            cursor: nil,
            viewport: TerminalViewport(totalRows: 1, offset: 0, visibleRows: 1, isAtBottom: true),
            hasSelection: false
        )
    }
}
