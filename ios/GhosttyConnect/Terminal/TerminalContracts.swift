import Foundation

enum SessionState: Equatable {
    case disconnected
    case connecting
    case verifyingHost
    case authenticating
    case connected
    case failed(String)
}

protocol SSHTransport: AnyObject {
    var output: AsyncThrowingStream<Data, Error> { get }
    var hostTrustRequests: AsyncStream<HostTrustRequest> { get }
    func connect(to host: Host, credential: SSHCredential) async throws
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws
    func disconnect() async
}

enum HostTrustStatus: Equatable, Sendable {
    case unknown
    case changed
}

struct HostTrustRequest: Identifiable, Sendable {
    let id: UUID
    let destination: String
    let algorithm: String
    let fingerprint: String
    let previousFingerprint: String?
    let status: HostTrustStatus
    private let response: HostTrustResponse

    init(
        id: UUID = UUID(),
        destination: String,
        algorithm: String,
        fingerprint: String,
        previousFingerprint: String?,
        status: HostTrustStatus,
        response: @escaping @Sendable (Bool) -> Void
    ) {
        self.id = id
        self.destination = destination
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.previousFingerprint = previousFingerprint
        self.status = status
        self.response = HostTrustResponse(response)
    }

    func answer(accepted: Bool) {
        response.answer(accepted)
    }
}

private final class HostTrustResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var response: (@Sendable (Bool) -> Void)?

    init(_ response: @escaping @Sendable (Bool) -> Void) {
        self.response = response
    }

    func answer(_ accepted: Bool) {
        lock.lock()
        let response = self.response
        self.response = nil
        lock.unlock()
        response?(accepted)
    }
}

enum SSHCredential {
    case password(String)
    case privateKey(Data, passphrase: String?)
}

protocol TerminalEngine: AnyObject {
    func feed(_ data: Data)
    func resize(columns: Int, rows: Int)
    func encode(text: String) -> Data
    func visibleText() -> String
    func snapshot() throws -> TerminalSnapshot
}

struct TerminalSnapshot: Equatable {
    let columns: Int
    let rows: Int
    let foreground: TerminalColor
    let background: TerminalColor
    let cursorColor: TerminalColor
    let cells: [TerminalCell]
    let cursor: TerminalCursor?

    func cell(column: Int, row: Int) -> TerminalCell? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return cells[row * columns + column]
    }
}

struct TerminalCell: Equatable {
    let text: String
    let foreground: TerminalColor
    let background: TerminalColor
    let bold: Bool
    let italic: Bool
    let faint: Bool
    let underline: TerminalUnderline
    let strikethrough: Bool
    let overline: Bool
    let blinking: Bool
    let invisible: Bool
}

struct TerminalColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

enum TerminalUnderline: Equatable {
    case none
    case single
    case double
    case curly
    case dotted
    case dashed
}

struct TerminalCursor: Equatable {
    let column: Int
    let row: Int
    let visible: Bool
    let blinking: Bool
    let style: TerminalCursorStyle
}

enum TerminalCursorStyle: Equatable {
    case bar
    case block
    case underline
    case hollowBlock
}

enum TerminalEngineFactory {
    static var isAvailable: Bool {
#if canImport(GhosttyVt)
        true
#else
        false
#endif
    }

    static func make(columns: Int = 80, rows: Int = 24) throws -> any TerminalEngine {
#if canImport(GhosttyVt)
        try GhosttyTerminalEngine(columns: columns, rows: rows)
#else
        throw TerminalEngineError.frameworkUnavailable
#endif
    }
}

enum TerminalEngineError: LocalizedError {
    case frameworkUnavailable
    case initializationFailed
    case formatterInitializationFailed
    case renderStateInitializationFailed
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            "GhosttyVt is not linked. Build the pinned XCFramework first."
        case .initializationFailed:
            "Ghostty could not create the terminal."
        case .formatterInitializationFailed:
            "Ghostty could not create the terminal formatter."
        case .renderStateInitializationFailed:
            "Ghostty could not create the render state."
        case .snapshotFailed:
            "Ghostty could not create a terminal snapshot."
        }
    }
}
