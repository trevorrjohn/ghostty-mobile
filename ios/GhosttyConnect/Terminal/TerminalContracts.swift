import Foundation

enum SessionState: Equatable {
    case disconnected
    case connecting
    case waitingForNetwork
    case retrying(attempt: Int, maxAttempts: Int, delaySeconds: Int)
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
        let supported = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 `-=[]\\;',./")
        guard value.unicodeScalars.allSatisfy(supported.contains) else { return nil }
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
        case "`": return "~"
        case "-": return "_"
        case "=": return "+"
        case "[": return "{"
        case "]": return "}"
        case "\\": return "|"
        case ";": return ":"
        case "'": return "\""
        case ",": return "<"
        case ".": return ">"
        case "/": return "?"
        default: return value.uppercased()
        }
    }
}

struct TerminalKeyModifiers: OptionSet, Equatable {
    let rawValue: UInt16

    static let shift = TerminalKeyModifiers(rawValue: 1 << 0)
    static let control = TerminalKeyModifiers(rawValue: 1 << 1)
    static let alt = TerminalKeyModifiers(rawValue: 1 << 2)
    static let meta = TerminalKeyModifiers(rawValue: 1 << 3)
    static let capsLock = TerminalKeyModifiers(rawValue: 1 << 4)
    static let numLock = TerminalKeyModifiers(rawValue: 1 << 5)

    init(rawValue: UInt16) { self.rawValue = rawValue }

    init(_ modifiers: Set<KeyboardModifier>) {
        var value: TerminalKeyModifiers = []
        if modifiers.contains(.shift) { value.insert(.shift) }
        if modifiers.contains(.control) { value.insert(.control) }
        if modifiers.contains(.alt) { value.insert(.alt) }
        if modifiers.contains(.meta) { value.insert(.meta) }
        if modifiers.contains(.capsLock) { value.insert(.capsLock) }
        if modifiers.contains(.numLock) { value.insert(.numLock) }
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

enum TerminalSearchDirection: Equatable {
    case previous
    case next
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
    func drainClipboardWrites() -> [TerminalClipboardWrite]
    func drainEffects() -> TerminalEffects
    func resize(columns: Int, rows: Int)
    func encode(event: TerminalInputEvent) throws -> Data
    func isPasteSafe(_ text: String) -> Bool
    func encodePaste(_ text: String) throws -> Data
    func scrollViewport(byRows rows: Int)
    func scrollToBottom()
    func search(_ query: String, direction: TerminalSearchDirection) -> Bool
    func selectWord(column: Int, row: Int) -> Bool
    func setSelectionEndpoint(start: Bool, column: Int, row: Int) -> Bool
    func selectRange(startColumn: Int, endColumn: Int, row: Int) -> Bool
    func selectOutput(column: Int, row: Int) -> Bool
    func hyperlink(column: Int, row: Int) -> String?
    func clearSelection()
    func selectedText() -> String
    func visibleText() -> String
    func snapshot() throws -> TerminalSnapshot
}

extension TerminalEngine {
    func drainClipboardWrites() -> [TerminalClipboardWrite] { [] }
    func drainEffects() -> TerminalEffects { TerminalEffects() }
}

struct TerminalEffects: Equatable {
    var clipboardWrites: [TerminalClipboardWrite] = []
    var bells = 0
    var notifications: [TerminalRemoteNotification] = []
    var progress: TerminalProgressReport?
    var ptyWrite = Data()
}

struct TerminalRemoteNotification: Equatable, Sendable {
    let title: String
    let body: String
}

struct TerminalRemoteNotificationRequest: Identifiable, Equatable {
    let id: UUID
    let notification: TerminalRemoteNotification
    let connectionAttemptID: UUID
}

struct TerminalProgressReport: Equatable, Sendable {
    let state: TerminalProgressState
    let percent: Int?
}

enum TerminalProgressState: Equatable, Sendable {
    case remove
    case set
    case error
    case indeterminate
    case paused
}

enum TerminalClipboardWrite: Equatable, Sendable {
    case text(String)
    case clear
}

struct TerminalClipboardWriteRequest: Identifiable, Equatable {
    let id: UUID
    let write: TerminalClipboardWrite
    let connectionAttemptID: UUID
}

struct TerminalViewport: Equatable {
    let totalRows: UInt64
    let offset: UInt64
    let visibleRows: UInt64
    let isAtBottom: Bool
}

struct TerminalSnapshot: Equatable {
    let columns: Int
    let rows: Int
    let foreground: TerminalColor
    let background: TerminalColor
    let cursorColor: TerminalColor
    let cells: [TerminalCell]
    let cursor: TerminalCursor?
    let viewport: TerminalViewport
    let hasSelection: Bool
    var title: String? = nil
    var workingDirectory: String? = nil
    var selectionEndpoints: TerminalSelectionEndpoints? = nil

    func cell(column: Int, row: Int) -> TerminalCell? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return cells[row * columns + column]
    }
}

struct TerminalSelectionPoint: Equatable {
    let column: Int
    let row: Int
}

struct TerminalSelectionEndpoints: Equatable {
    let start: TerminalSelectionPoint?
    let end: TerminalSelectionPoint?
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
    let selected: Bool
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
    case pasteEncodingFailed
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
        case .pasteEncodingFailed:
            "Ghostty could not encode the pasted text."
        case .snapshotFailed:
            "Ghostty could not create a terminal snapshot."
        }
    }
}
