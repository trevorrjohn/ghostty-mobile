import Foundation

enum SessionState: Equatable {
    case disconnected
    case connecting
    case verifyingHost
    case authenticating
    case connected
    case failed(SessionFailure)
}

extension SessionState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum SessionFailureKind: Equatable {
    case authentication
    case hostTrust
    case network
    case protocolFailure
    case configuration
}

struct SessionFailure: Equatable {
    let kind: SessionFailureKind
    let message: String

    var canRetry: Bool { kind != .configuration }
}

enum TerminalKey: Equatable {
    case escape
    case tab
    case enter
    case backspace
    case delete
    case insert
    case home
    case end
    case pageUp
    case pageDown
    case up
    case down
    case left
    case right
    case function(Int)
    case character(String)

    static func fromCommittedText(_ text: String) -> TerminalKey? {
        guard text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first,
              scalar.isASCII else { return nil }
        let value = text.uppercased()
        guard value.range(of: #"^[A-Z0-9 ]$"#, options: .regularExpression) != nil else { return nil }
        return .character(value)
    }

    func generatedText(shifted: Bool) -> String? {
        guard case .character(let value) = self else { return nil }
        guard shifted else { return value.lowercased() }
        switch value {
        case "0": return ")"
        case "1": return "!"
        case "2": return "@"
        case "3": return "#"
        case "4": return "$"
        case "5": return "%"
        case "6": return "^"
        case "7": return "&"
        case "8": return "*"
        case "9": return "("
        default: return value.uppercased()
        }
    }
}

struct TerminalKeyModifiers: OptionSet, Equatable {
    let rawValue: UInt16

    static let shift = TerminalKeyModifiers(rawValue: 1 << 0)
    static let control = TerminalKeyModifiers(rawValue: 1 << 1)
    static let alt = TerminalKeyModifiers(rawValue: 1 << 2)

    init(rawValue: UInt16) { self.rawValue = rawValue }

    init(_ modifiers: Set<KeyboardModifier>) {
        var value: TerminalKeyModifiers = []
        if modifiers.contains(.shift) { value.insert(.shift) }
        if modifiers.contains(.control) { value.insert(.control) }
        if modifiers.contains(.alt) { value.insert(.alt) }
        self = value
    }
}

enum TerminalInputEvent: Equatable {
    case text(String, modifiers: TerminalKeyModifiers = [])
    case key(TerminalKey, text: String = "", modifiers: TerminalKeyModifiers = [])

    func adding(_ additionalModifiers: TerminalKeyModifiers) -> TerminalInputEvent {
        switch self {
        case .text(let text, let modifiers):
            return .text(text, modifiers: modifiers.union(additionalModifiers))
        case .key(let key, let text, let modifiers):
            let combined = modifiers.union(additionalModifiers)
            let output = text.isEmpty ? text : (key.generatedText(shifted: combined.contains(.shift)) ?? text)
            return .key(key, text: output, modifiers: combined)
        }
    }
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
    func encode(event: TerminalInputEvent) throws -> Data
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
    case keyEncoderInitializationFailed
    case keyEncodingFailed
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
        case .keyEncoderInitializationFailed:
            "Ghostty could not create the keyboard encoder."
        case .keyEncodingFailed:
            "Ghostty could not encode the keyboard input."
        case .snapshotFailed:
            "Ghostty could not create a terminal snapshot."
        }
    }
}
