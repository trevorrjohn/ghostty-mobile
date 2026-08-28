import XCTest
@testable import GhosttyConnect

@MainActor
final class TerminalInputSessionTests: XCTestCase {
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

    init(hangWrites: Bool = false, delayDisconnect: Bool = false) {
        state = LifecycleTransportState(hangWrites: hangWrites, delayDisconnect: delayDisconnect)
        var outputContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { outputContinuation = $0 }
        self.outputContinuation = outputContinuation
        var trustContinuation: AsyncStream<HostTrustRequest>.Continuation!
        hostTrustRequests = AsyncStream { trustContinuation = $0 }
        self.trustContinuation = trustContinuation
    }

    func connect(to host: Host, credential: SSHCredential) async throws {}
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
    func feed(_ data: Data) {}
    func resize(columns: Int, rows: Int) {}

    func encode(event: TerminalInputEvent) throws -> Data {
        guard case .text(let text, _) = event else { return Data() }
        return Data(text.utf8)
    }

    func isPasteSafe(_ text: String) -> Bool { !text.contains("\n") }
    func encodePaste(_ text: String) throws -> Data { Data("paste:\(text)".utf8) }
    func scrollViewport(byRows rows: Int) {}
    func scrollToBottom() {}
    func selectWord(column: Int, row: Int) -> Bool { false }
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
