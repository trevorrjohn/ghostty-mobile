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

private final class InputTestEngine: TerminalEngine {
    func feed(_ data: Data) {}
    func resize(columns: Int, rows: Int) {}

    func encode(event: TerminalInputEvent) throws -> Data {
        guard case .text(let text, _) = event else { return Data() }
        return Data(text.utf8)
    }

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
                invisible: false
            )],
            cursor: nil
        )
    }
}
