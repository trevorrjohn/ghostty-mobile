#if canImport(GhosttyVt)
import Foundation
import GhosttyVt

private final class GhosttyEffectQueue {
    private static let maximumPendingWrites = 8
    private static let maximumPendingNotifications = 8
    private static let maximumTextBytes = 1_048_576
    private static let maximumNotificationTitleBytes = 256
    private static let maximumNotificationBodyBytes = 4_096
    private static let maximumPtyWriteBytes = 65_536
    private let lock = NSLock()
    private var writes: [TerminalClipboardWrite] = []
    private var bells = 0
    private var notifications: [TerminalRemoteNotification] = []
    private var progress: TerminalProgressReport?
    private var ptyWrite = Data()

    func capture(_ request: UnsafePointer<GhosttyClipboardWrite>) -> GhosttyClipboardWriteResult {
        guard request.pointee.size >= MemoryLayout<GhosttyClipboardWrite>.size else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
        }
        let request = request.pointee
        guard request.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
        }
        if request.contents_len == 0 {
            return append(.clear)
        }
        guard let contents = request.contents else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
        }
        for index in 0..<request.contents_len {
            let content = contents[index]
            guard let mimeData = Self.data(content.mime),
                  let mime = String(data: mimeData, encoding: .utf8) else {
                return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
            }
            guard mime == "text/plain" || mime == "text/plain;charset=utf-8" else { continue }
            guard content.data.len <= Self.maximumTextBytes,
                  let data = Self.data(content.data),
                  let text = String(data: data, encoding: .utf8) else {
                return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
            }
            return append(.text(text))
        }
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
    }

    func drain() -> [TerminalClipboardWrite] {
        lock.lock()
        defer { lock.unlock() }
        let result = writes
        writes.removeAll(keepingCapacity: true)
        return result
    }

    func captureBell() {
        lock.lock()
        defer { lock.unlock() }
        bells = min(10, bells + 1)
    }

    func captureNotification(_ request: UnsafePointer<GhosttyTerminalDesktopNotification>) {
        guard request.pointee.size >= MemoryLayout<GhosttyTerminalDesktopNotification>.size,
              let title = Self.string(request.pointee.title, maximumBytes: Self.maximumNotificationTitleBytes),
              let body = Self.string(request.pointee.body, maximumBytes: Self.maximumNotificationBodyBytes) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard notifications.count < Self.maximumPendingNotifications else { return }
        notifications.append(TerminalRemoteNotification(title: title, body: body))
    }

    func captureProgress(_ request: UnsafePointer<GhosttyTerminalProgressReport>) {
        guard request.pointee.size >= MemoryLayout<GhosttyTerminalProgressReport>.size else { return }
        let state: TerminalProgressState
        switch request.pointee.state {
        case GHOSTTY_TERMINAL_PROGRESS_STATE_REMOVE: state = .remove
        case GHOSTTY_TERMINAL_PROGRESS_STATE_SET: state = .set
        case GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR: state = .error
        case GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE: state = .indeterminate
        case GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE: state = .paused
        default: return
        }
        let value = Int(request.pointee.progress)
        lock.lock()
        progress = TerminalProgressReport(state: state, percent: (0...100).contains(value) ? value : nil)
        lock.unlock()
    }

    func capturePtyWrite(_ bytes: UnsafePointer<UInt8>?, count: Int) {
        guard count > 0, let bytes else { return }
        lock.lock()
        defer { lock.unlock() }
        guard count <= Self.maximumPtyWriteBytes - ptyWrite.count else { return }
        ptyWrite.append(bytes, count: count)
    }

    func drainEffects() -> TerminalEffects {
        lock.lock()
        defer { lock.unlock() }
        let result = TerminalEffects(
            clipboardWrites: writes,
            bells: bells,
            notifications: notifications,
            progress: progress,
            ptyWrite: ptyWrite
        )
        writes.removeAll(keepingCapacity: true)
        bells = 0
        notifications.removeAll(keepingCapacity: true)
        progress = nil
        ptyWrite.removeAll(keepingCapacity: true)
        return result
    }

    private func append(_ write: TerminalClipboardWrite) -> GhosttyClipboardWriteResult {
        lock.lock()
        defer { lock.unlock() }
        guard writes.count < Self.maximumPendingWrites else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY
        }
        writes.append(write)
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
    }

    private static func data(_ value: GhosttyString) -> Data? {
        guard value.len == 0 || value.ptr != nil else { return nil }
        guard let pointer = value.ptr else { return Data() }
        return Data(bytes: pointer, count: value.len)
    }

    private static func string(_ value: GhosttyString, maximumBytes: Int) -> String? {
        guard value.len <= maximumBytes, let data = data(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private let ghosttyClipboardWriteCallback: GhosttyTerminalClipboardWriteFn = { _, userdata, request in
    guard let userdata, let request else { return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA }
    return Unmanaged<GhosttyEffectQueue>.fromOpaque(userdata).takeUnretainedValue().capture(request)
}

private let ghosttyBellCallback: GhosttyTerminalBellFn = { _, userdata in
    guard let userdata else { return }
    Unmanaged<GhosttyEffectQueue>.fromOpaque(userdata).takeUnretainedValue().captureBell()
}

private let ghosttyNotificationCallback: GhosttyTerminalDesktopNotificationFn = { _, userdata, request in
    guard let userdata, let request else { return }
    Unmanaged<GhosttyEffectQueue>.fromOpaque(userdata).takeUnretainedValue().captureNotification(request)
}

private let ghosttyProgressCallback: GhosttyTerminalProgressReportFn = { _, userdata, request in
    guard let userdata, let request else { return }
    Unmanaged<GhosttyEffectQueue>.fromOpaque(userdata).takeUnretainedValue().captureProgress(request)
}

private let ghosttyWritePtyCallback: GhosttyTerminalWritePtyFn = { _, userdata, bytes, count in
    guard let userdata else { return }
    Unmanaged<GhosttyEffectQueue>.fromOpaque(userdata).takeUnretainedValue().capturePtyWrite(bytes, count: count)
}

final class GhosttyTerminalEngine: TerminalEngine {
    private static let maximumMetadataBytes = 4_096
    private let terminal: GhosttyTerminal
    private let formatter: GhosttyFormatter
    private let renderState: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    private let effects: GhosttyEffectQueue
    private let lock = NSLock()
    private var searchState: SearchState?

    private struct SearchPosition: Equatable {
        let row: Int
        let column: Int
    }

    private struct SearchMatch: Equatable {
        let start: SearchPosition
        let end: SearchPosition
    }

    private struct SearchState {
        let query: String
        let match: SearchMatch
    }

    private struct SearchableLine {
        var text = ""
        var utf16Cells: [SearchPosition] = []

        mutating func append(_ value: String, at position: SearchPosition) {
            text.append(value)
            utf16Cells.append(contentsOf: repeatElement(position, count: value.utf16.count))
        }
    }

    init(columns: Int, rows: Int) throws {
        let effects = GhosttyEffectQueue()
        var terminal: GhosttyTerminal?
        let result = ghostty_terminal_new(
            nil,
            &terminal,
            Self.dimension(columns),
            Self.dimension(rows)
        )
        guard result == GHOSTTY_SUCCESS, let terminal else {
            throw TerminalEngineError.initializationFailed
        }

        let clipboardCallback = unsafeBitCast(ghosttyClipboardWriteCallback, to: UnsafeRawPointer.self)
        let bellCallback = unsafeBitCast(ghosttyBellCallback, to: UnsafeRawPointer.self)
        let notificationCallback = unsafeBitCast(ghosttyNotificationCallback, to: UnsafeRawPointer.self)
        let progressCallback = unsafeBitCast(ghosttyProgressCallback, to: UnsafeRawPointer.self)
        let writePtyCallback = unsafeBitCast(ghosttyWritePtyCallback, to: UnsafeRawPointer.self)
        guard ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_USERDATA,
            Unmanaged.passUnretained(effects).toOpaque()
        ) == GHOSTTY_SUCCESS,
        ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
            clipboardCallback
        ) == GHOSTTY_SUCCESS,
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, bellCallback) == GHOSTTY_SUCCESS,
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, notificationCallback) == GHOSTTY_SUCCESS,
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, progressCallback) == GHOSTTY_SUCCESS,
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, writePtyCallback) == GHOSTTY_SUCCESS
        else {
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.initializationFailed
        }

        var scrollbackLines = 10_000
        guard ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            &scrollbackLines
        ) == GHOSTTY_SUCCESS else {
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.initializationFailed
        }

        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true

        var formatter: GhosttyFormatter?
        let formatterResult = ghostty_formatter_terminal_new(nil, &formatter, terminal, options)
        guard formatterResult == GHOSTTY_SUCCESS, let formatter else {
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.formatterInitializationFailed
        }

        var renderState: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &renderState) == GHOSTTY_SUCCESS,
              let renderState else {
            ghostty_formatter_free(formatter)
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.renderStateInitializationFailed
        }

        var rowIterator: GhosttyRenderStateRowIterator?
        guard ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
              let rowIterator else {
            ghostty_render_state_free(renderState)
            ghostty_formatter_free(formatter)
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.renderStateInitializationFailed
        }

        var rowCells: GhosttyRenderStateRowCells?
        guard ghostty_render_state_row_cells_new(nil, &rowCells) == GHOSTTY_SUCCESS,
              let rowCells else {
            ghostty_render_state_row_iterator_free(rowIterator)
            ghostty_render_state_free(renderState)
            ghostty_formatter_free(formatter)
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.renderStateInitializationFailed
        }

        var keyEncoder: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &keyEncoder) == GHOSTTY_SUCCESS,
              let keyEncoder else {
            ghostty_render_state_row_cells_free(rowCells)
            ghostty_render_state_row_iterator_free(rowIterator)
            ghostty_render_state_free(renderState)
            ghostty_formatter_free(formatter)
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.keyEncoderInitializationFailed
        }

        var keyEvent: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &keyEvent) == GHOSTTY_SUCCESS,
              let keyEvent else {
            ghostty_key_encoder_free(keyEncoder)
            ghostty_render_state_row_cells_free(rowCells)
            ghostty_render_state_row_iterator_free(rowIterator)
            ghostty_render_state_free(renderState)
            ghostty_formatter_free(formatter)
            ghostty_terminal_free(terminal)
            throw TerminalEngineError.keyEncoderInitializationFailed
        }

        self.terminal = terminal
        self.formatter = formatter
        self.renderState = renderState
        self.rowIterator = rowIterator
        self.rowCells = rowCells
        self.keyEncoder = keyEncoder
        self.keyEvent = keyEvent
        self.effects = effects
    }

    deinit {
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_formatter_free(formatter)
        ghostty_terminal_free(terminal)
    }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        searchState = nil
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            ghostty_terminal_vt_write(
                terminal,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                bytes.count
            )
        }
    }

    func drainClipboardWrites() -> [TerminalClipboardWrite] {
        effects.drain()
    }

    func drainEffects() -> TerminalEffects {
        effects.drainEffects()
    }

    func resize(columns: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        searchState = nil
        ghostty_terminal_resize(
            terminal,
            Self.dimension(columns),
            Self.dimension(rows),
            0,
            0
        )
    }

    func encode(event: TerminalInputEvent) throws -> Data {
        let key: TerminalKey
        let text: String
        let modifiers: TerminalKeyModifiers
        switch event {
        case .text(let value, let eventModifiers):
            guard !eventModifiers.isEmpty else { return Data(value.utf8) }
            guard let characterKey = TerminalKey.fromCommittedText(value) else {
                return Data(value.utf8)
            }
            key = characterKey
            text = value
            modifiers = eventModifiers
        case .key(let eventKey, let eventText, let eventModifiers):
            key = eventKey
            text = eventText
            modifiers = eventModifiers
        }

        lock.lock()
        defer { lock.unlock() }
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
        ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(keyEvent, Self.nativeKey(key))
        ghostty_key_event_set_mods(keyEvent, modifiers.rawValue)
        ghostty_key_event_set_consumed_mods(keyEvent, 0)
        ghostty_key_event_set_composing(keyEvent, false)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, Self.unshiftedCodepoint(key))
        return try text.withCString { pointer -> Data in
            ghostty_key_event_set_utf8(keyEvent, pointer, text.utf8.count)

            var buffer = [CChar](repeating: 0, count: 128)
            var written = 0
            var result = buffer.withUnsafeMutableBufferPointer { bytes in
                ghostty_key_encoder_encode(keyEncoder, keyEvent, bytes.baseAddress, bytes.count, &written)
            }
            if result == GHOSTTY_OUT_OF_SPACE {
                guard written <= 4_096 else { throw TerminalEngineError.keyEncodingFailed }
                buffer = [CChar](repeating: 0, count: written)
                result = buffer.withUnsafeMutableBufferPointer { bytes in
                    ghostty_key_encoder_encode(keyEncoder, keyEvent, bytes.baseAddress, bytes.count, &written)
                }
            }
            guard result == GHOSTTY_SUCCESS else { throw TerminalEngineError.keyEncodingFailed }
            return buffer.withUnsafeBytes { Data($0.prefix(written)) }
        }
    }

    private static func nativeKey(_ key: TerminalKey) -> GhosttyKey {
        switch key {
        case .escape: GHOSTTY_KEY_ESCAPE
        case .tab: GHOSTTY_KEY_TAB
        case .enter: GHOSTTY_KEY_ENTER
        case .backspace: GHOSTTY_KEY_BACKSPACE
        case .delete: GHOSTTY_KEY_DELETE
        case .insert: GHOSTTY_KEY_INSERT
        case .home: GHOSTTY_KEY_HOME
        case .end: GHOSTTY_KEY_END
        case .pageUp: GHOSTTY_KEY_PAGE_UP
        case .pageDown: GHOSTTY_KEY_PAGE_DOWN
        case .up: GHOSTTY_KEY_ARROW_UP
        case .down: GHOSTTY_KEY_ARROW_DOWN
        case .left: GHOSTTY_KEY_ARROW_LEFT
        case .right: GHOSTTY_KEY_ARROW_RIGHT
        case .function(let number): nativeFunctionKey(number)
        case .character(let value): nativeCharacterKey(value.uppercased())
        }
    }

    private static func nativeFunctionKey(_ number: Int) -> GhosttyKey {
        switch number {
        case 1: GHOSTTY_KEY_F1
        case 2: GHOSTTY_KEY_F2
        case 3: GHOSTTY_KEY_F3
        case 4: GHOSTTY_KEY_F4
        case 5: GHOSTTY_KEY_F5
        case 6: GHOSTTY_KEY_F6
        case 7: GHOSTTY_KEY_F7
        case 8: GHOSTTY_KEY_F8
        case 9: GHOSTTY_KEY_F9
        case 10: GHOSTTY_KEY_F10
        case 11: GHOSTTY_KEY_F11
        case 12: GHOSTTY_KEY_F12
        default: GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    private static func nativeCharacterKey(_ value: String) -> GhosttyKey {
        switch value {
        case "A": GHOSTTY_KEY_A
        case "B": GHOSTTY_KEY_B
        case "C": GHOSTTY_KEY_C
        case "D": GHOSTTY_KEY_D
        case "E": GHOSTTY_KEY_E
        case "F": GHOSTTY_KEY_F
        case "G": GHOSTTY_KEY_G
        case "H": GHOSTTY_KEY_H
        case "I": GHOSTTY_KEY_I
        case "J": GHOSTTY_KEY_J
        case "K": GHOSTTY_KEY_K
        case "L": GHOSTTY_KEY_L
        case "M": GHOSTTY_KEY_M
        case "N": GHOSTTY_KEY_N
        case "O": GHOSTTY_KEY_O
        case "P": GHOSTTY_KEY_P
        case "Q": GHOSTTY_KEY_Q
        case "R": GHOSTTY_KEY_R
        case "S": GHOSTTY_KEY_S
        case "T": GHOSTTY_KEY_T
        case "U": GHOSTTY_KEY_U
        case "V": GHOSTTY_KEY_V
        case "W": GHOSTTY_KEY_W
        case "X": GHOSTTY_KEY_X
        case "Y": GHOSTTY_KEY_Y
        case "Z": GHOSTTY_KEY_Z
        case "0": GHOSTTY_KEY_DIGIT_0
        case "1": GHOSTTY_KEY_DIGIT_1
        case "2": GHOSTTY_KEY_DIGIT_2
        case "3": GHOSTTY_KEY_DIGIT_3
        case "4": GHOSTTY_KEY_DIGIT_4
        case "5": GHOSTTY_KEY_DIGIT_5
        case "6": GHOSTTY_KEY_DIGIT_6
        case "7": GHOSTTY_KEY_DIGIT_7
        case "8": GHOSTTY_KEY_DIGIT_8
        case "9": GHOSTTY_KEY_DIGIT_9
        case " ": GHOSTTY_KEY_SPACE
        case "`": GHOSTTY_KEY_BACKQUOTE
        case "\\": GHOSTTY_KEY_BACKSLASH
        case "[": GHOSTTY_KEY_BRACKET_LEFT
        case "]": GHOSTTY_KEY_BRACKET_RIGHT
        case ",": GHOSTTY_KEY_COMMA
        case "=": GHOSTTY_KEY_EQUAL
        case "-": GHOSTTY_KEY_MINUS
        case ".": GHOSTTY_KEY_PERIOD
        case "'": GHOSTTY_KEY_QUOTE
        case ";": GHOSTTY_KEY_SEMICOLON
        case "/": GHOSTTY_KEY_SLASH
        default: GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    private static func unshiftedCodepoint(_ key: TerminalKey) -> UInt32 {
        guard case .character(let value) = key else { return 0 }
        return value.lowercased().unicodeScalars.first?.value ?? 0
    }

    func isPasteSafe(_ text: String) -> Bool {
        guard !text.contains("\r") else { return false }
        return text.withCString { ghostty_paste_is_safe($0, text.utf8.count) }
    }

    func encodePaste(_ text: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2004, false), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS else {
            throw TerminalEngineError.pasteEncodingFailed
        }

        var input = text.utf8.map { CChar(bitPattern: $0) }
        var output = [CChar](repeating: 0, count: input.count + 12)
        var written = 0
        let result = input.withUnsafeMutableBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                ghostty_paste_encode(
                    inputBuffer.baseAddress,
                    inputBuffer.count,
                    mode.value,
                    outputBuffer.baseAddress,
                    outputBuffer.count,
                    &written
                )
            }
        }
        guard result == GHOSTTY_SUCCESS else { throw TerminalEngineError.pasteEncodingFailed }
        return output.withUnsafeBytes { Data($0.prefix(written)) }
    }

    func scrollViewport(byRows rows: Int) {
        guard rows != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = rows
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    func scrollToBottom() {
        lock.lock()
        defer { lock.unlock() }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    func search(_ query: String, direction: TerminalSearchDirection) -> Bool {
        guard !query.isEmpty, query.utf8.count <= 1_024 else { return false }
        lock.lock()
        defer { lock.unlock() }

        var totalRows: UInt = 0
        var columns: UInt16 = 0
        var scrollbar = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &totalRows) == GHOSTTY_SUCCESS,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns) == GHOSTTY_SUCCESS,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar) == GHOSTTY_SUCCESS,
              totalRows > 0, columns > 0 else { return false }

        let continuing = searchState.map {
            $0.query.compare(query, options: .caseInsensitive) == .orderedSame
        } ?? false
        let current = continuing ? searchState?.match : nil
        var first: SearchMatch?
        var last: SearchMatch?
        var previous: SearchMatch?
        var next: SearchMatch?
        var foundCurrent = false
        var viewportPrevious: SearchMatch?
        var viewportNext: SearchMatch?
        var logicalLine = SearchableLine()

        func consume(_ match: SearchMatch) {
            if first == nil { first = match }
            last = match
            if match.start.row <= Int(scrollbar.offset) { viewportPrevious = match }
            if viewportNext == nil, match.start.row >= Int(scrollbar.offset) { viewportNext = match }
            guard let current else { return }
            if match == current { foundCurrent = true }
            else if foundCurrent {
                if next == nil { next = match }
            } else {
                previous = match
            }
        }

        func consumeMatches(in line: SearchableLine) {
            let source = line.text as NSString
            guard source.length > 0 else { return }
            var location = 0
            while location < source.length {
                let range = source.range(
                    of: query,
                    options: .caseInsensitive,
                    range: NSRange(location: location, length: source.length - location)
                )
                guard range.location != NSNotFound, range.length > 0,
                      range.location < line.utf16Cells.count,
                      range.location + range.length <= line.utf16Cells.count else { return }
                consume(SearchMatch(
                    start: line.utf16Cells[range.location],
                    end: line.utf16Cells[range.location + range.length - 1]
                ))
                location = range.location + 1
            }
        }

        for row in 0..<Int(totalRows) {
            for column in 0..<Int(columns) {
                guard var reference = screenReference(column: column, row: row) else { continue }
                var cell: GhosttyCell = 0
                var wide = GHOSTTY_CELL_WIDE_NARROW
                guard ghostty_grid_ref_cell(&reference, &cell) == GHOSTTY_SUCCESS else { continue }
                _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }

                var count = 0
                var value = ""
                if ghostty_grid_ref_graphemes(&reference, nil, 0, &count) == GHOSTTY_OUT_OF_SPACE,
                   count > 0 {
                    var codepoints = [UInt32](repeating: 0, count: count)
                    let result = codepoints.withUnsafeMutableBufferPointer { buffer in
                        ghostty_grid_ref_graphemes(&reference, buffer.baseAddress, buffer.count, &count)
                    }
                    if result == GHOSTTY_SUCCESS {
                        for codepoint in codepoints.prefix(count) {
                            if let scalar = UnicodeScalar(codepoint) { value.unicodeScalars.append(scalar) }
                        }
                    }
                }
                logicalLine.append(value.isEmpty ? " " : value, at: SearchPosition(row: row, column: column))
            }
            if !rowWraps(row: row) || row + 1 == Int(totalRows) {
                consumeMatches(in: logicalLine)
                logicalLine = SearchableLine()
            }
        }

        guard let selected: SearchMatch = {
            if continuing, foundCurrent {
                return direction == .previous ? (previous ?? last) : (next ?? first)
            }
            return direction == .previous ? (viewportPrevious ?? last) : (viewportNext ?? first)
        }() else { return false }

        guard let start = screenReference(column: selected.start.column, row: selected.start.row),
              let end = screenReference(column: selected.end.column, row: selected.end.row) else { return false }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        guard ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS else {
            return false
        }
        searchState = SearchState(query: query, match: selected)

        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        behavior.value.row = max(0, selected.start.row - Int(scrollbar.len / 3))
        ghostty_terminal_scroll_viewport(terminal, behavior)
        return true
    }

    private func screenReference(column: Int, row: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(
            x: UInt16(clamping: column),
            y: UInt32(clamping: row)
        )
        var reference = GhosttyGridRef()
        reference.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(terminal, point, &reference) == GHOSTTY_SUCCESS ? reference : nil
    }

    private func rowWraps(row: Int) -> Bool {
        guard var reference = screenReference(column: 0, row: row) else { return false }
        var nativeRow: GhosttyRow = 0
        var wraps = false
        return ghostty_grid_ref_row(&reference, &nativeRow) == GHOSTTY_SUCCESS
            && ghostty_row_get(nativeRow, GHOSTTY_ROW_DATA_WRAP, &wraps) == GHOSTTY_SUCCESS
            && wraps
    }

    func selectWord(column: Int, row: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(
            x: UInt16(clamping: max(0, column)),
            y: UInt32(clamping: max(0, row))
        )
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return false }

        var options = GhosttyTerminalSelectWordOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        options.ref = ref
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_word(terminal, &options, &selection) == GHOSTTY_SUCCESS,
              ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS else {
            return false
        }
        return true
    }

    func setSelectionEndpoint(start: Bool, column: Int, row: Int) -> Bool {
        guard column >= 0, row >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }

        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS,
              let reference = gridReference(column: column, row: row) else { return false }
        if start { selection.start = reference }
        else { selection.end = reference }
        return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    func selectRange(startColumn: Int, endColumn: Int, row: Int) -> Bool {
        guard startColumn >= 0, endColumn >= startColumn, row >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }

        guard let start = gridReference(column: startColumn, row: row),
              let end = gridReference(column: endColumn, row: row) else { return false }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    func selectOutput(column: Int, row: Int) -> Bool {
        guard column >= 0, row >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }

        guard let ref = gridReference(column: column, row: row) else { return false }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_output(terminal, ref, &selection) == GHOSTTY_SUCCESS else { return false }
        return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    func hyperlink(column: Int, row: Int) -> String? {
        guard column >= 0, row >= 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard var ref = gridReference(column: column, row: row) else { return nil }
        var required = 0
        let query = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &required)
        guard query == GHOSTTY_OUT_OF_SPACE, required > 0, required <= 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: required)
        var written = 0
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            ghostty_grid_ref_hyperlink_uri(&ref, buffer.baseAddress, buffer.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written <= bytes.count else { return nil }
        return String(bytes: bytes.prefix(written), encoding: .utf8)
    }

    private func gridReference(column: Int, row: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(
            x: UInt16(clamping: column),
            y: UInt32(clamping: row)
        )
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    func clearSelection() {
        lock.lock()
        defer { lock.unlock() }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    func selectedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        options.selection = nil
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(
            terminal,
            nil,
            options,
            &buffer,
            &length
        ) == GHOSTTY_SUCCESS, let buffer else { return "" }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    func visibleText() -> String {
        lock.lock()
        defer { lock.unlock() }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &buffer, &length) == GHOSTTY_SUCCESS,
              let buffer else {
            return ""
        }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    func snapshot() throws -> TerminalSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else {
            throw TerminalEngineError.snapshotFailed
        }

        var columns: UInt16 = 0
        var rows: UInt16 = 0
        var foreground = GhosttyColorRgb()
        var background = GhosttyColorRgb()
        var scrollbar = GhosttyTerminalScrollbar()
        var viewportActive = true
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &columns) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &foreground) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &background) == GHOSTTY_SUCCESS,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar) == GHOSTTY_SUCCESS,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &viewportActive) == GHOSTTY_SUCCESS else {
            throw TerminalEngineError.snapshotFailed
        }
        let selectionResult = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection)
        guard selectionResult == GHOSTTY_SUCCESS || selectionResult == GHOSTTY_NO_VALUE else {
            throw TerminalEngineError.snapshotFailed
        }
        let selectionEndpoints: TerminalSelectionEndpoints? = selectionResult == GHOSTTY_SUCCESS
            ? TerminalSelectionEndpoints(
                start: viewportSelectionPoint(selection.start),
                end: viewportSelectionPoint(selection.end)
            )
            : nil

        var nativeTitle = GhosttyString()
        let titleResult = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &nativeTitle)
        guard titleResult == GHOSTTY_SUCCESS || titleResult == GHOSTTY_NO_VALUE else {
            throw TerminalEngineError.snapshotFailed
        }
        var nativeWorkingDirectory = GhosttyString()
        let workingDirectoryResult = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &nativeWorkingDirectory)
        guard workingDirectoryResult == GHOSTTY_SUCCESS || workingDirectoryResult == GHOSTTY_NO_VALUE else {
            throw TerminalEngineError.snapshotFailed
        }
        let title = titleResult == GHOSTTY_SUCCESS ? Self.metadataString(nativeTitle) : nil
        let workingDirectory = workingDirectoryResult == GHOSTTY_SUCCESS
            ? Self.metadataString(nativeWorkingDirectory)
            : nil

        var cursorColor = foreground
        var hasCursorColor = false
        if ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE, &hasCursorColor) == GHOSTTY_SUCCESS,
           hasCursorColor {
            guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR, &cursorColor) == GHOSTTY_SUCCESS else {
                throw TerminalEngineError.snapshotFailed
            }
        }

        var nativeCursor = GhosttyRenderStateCursor()
        nativeCursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &nativeCursor) == GHOSTTY_SUCCESS else {
            throw TerminalEngineError.snapshotFailed
        }

        var iterator = rowIterator
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS else {
            throw TerminalEngineError.snapshotFailed
        }

        let defaultForeground = Self.color(foreground)
        let defaultBackground = Self.color(background)
        var cells: [TerminalCell] = []
        cells.reserveCapacity(Int(columns) * Int(rows))

        while ghostty_render_state_row_iterator_next(rowIterator) {
            var nativeCells = rowCells
            guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &nativeCells) == GHOSTTY_SUCCESS else {
                throw TerminalEngineError.snapshotFailed
            }

            while ghostty_render_state_row_cells_next(rowCells) {
                cells.append(try snapshotCell(
                    defaultForeground: defaultForeground,
                    defaultBackground: defaultBackground
                ))
            }
        }

        guard cells.count == Int(columns) * Int(rows) else {
            throw TerminalEngineError.snapshotFailed
        }

        let cursor: TerminalCursor? = nativeCursor.viewport_has_value
            ? TerminalCursor(
                column: Int(nativeCursor.viewport_x),
                row: Int(nativeCursor.viewport_y),
                visible: nativeCursor.visible,
                blinking: nativeCursor.blinking,
                style: Self.cursorStyle(nativeCursor.visual_style)
            )
            : nil

        return TerminalSnapshot(
            columns: Int(columns),
            rows: Int(rows),
            foreground: defaultForeground,
            background: defaultBackground,
            cursorColor: Self.color(cursorColor),
            cells: cells,
            cursor: cursor,
            viewport: TerminalViewport(
                totalRows: scrollbar.total,
                offset: scrollbar.offset,
                visibleRows: scrollbar.len,
                isAtBottom: viewportActive
            ),
            hasSelection: selectionResult == GHOSTTY_SUCCESS,
            title: title,
            workingDirectory: workingDirectory,
            selectionEndpoints: selectionEndpoints
        )
    }

    private static func metadataString(_ value: GhosttyString) -> String? {
        guard value.len > 0,
              value.len <= maximumMetadataBytes,
              let pointer = value.ptr else { return nil }
        return String(data: Data(bytes: pointer, count: value.len), encoding: .utf8)
    }

    private func viewportSelectionPoint(_ reference: GhosttyGridRef) -> TerminalSelectionPoint? {
        var reference = reference
        var coordinate = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(
            terminal,
            &reference,
            GHOSTTY_POINT_TAG_VIEWPORT,
            &coordinate
        ) == GHOSTTY_SUCCESS else { return nil }
        return TerminalSelectionPoint(column: Int(coordinate.x), row: Int(coordinate.y))
    }

    private func snapshotCell(
        defaultForeground: TerminalColor,
        defaultBackground: TerminalColor
    ) throws -> TerminalCell {
        var graphemeLength: UInt32 = 0
        var style = GhosttyStyle()
        var selected = false
        style.size = MemoryLayout<GhosttyStyle>.size
        guard ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLength) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected) == GHOSTTY_SUCCESS else {
            throw TerminalEngineError.snapshotFailed
        }

        var text = ""
        if graphemeLength > 0 {
            var codepoints = [UInt32](repeating: 0, count: Int(graphemeLength))
            let result = codepoints.withUnsafeMutableBufferPointer { buffer in
                ghostty_render_state_row_cells_get(
                    rowCells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                    buffer.baseAddress
                )
            }
            guard result == GHOSTTY_SUCCESS else { throw TerminalEngineError.snapshotFailed }
            for codepoint in codepoints {
                guard let scalar = UnicodeScalar(codepoint) else { continue }
                text.unicodeScalars.append(scalar)
            }
        }

        var nativeForeground = GhosttyColorRgb()
        var nativeBackground = GhosttyColorRgb()
        let foregroundResult = ghostty_render_state_row_cells_get(
            rowCells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &nativeForeground
        )
        let backgroundResult = ghostty_render_state_row_cells_get(
            rowCells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &nativeBackground
        )
        guard foregroundResult == GHOSTTY_SUCCESS || foregroundResult == GHOSTTY_INVALID_VALUE,
              backgroundResult == GHOSTTY_SUCCESS || backgroundResult == GHOSTTY_INVALID_VALUE else {
            throw TerminalEngineError.snapshotFailed
        }

        var cellForeground = foregroundResult == GHOSTTY_SUCCESS ? Self.color(nativeForeground) : defaultForeground
        var cellBackground = backgroundResult == GHOSTTY_SUCCESS ? Self.color(nativeBackground) : defaultBackground
        if style.inverse {
            swap(&cellForeground, &cellBackground)
        }

        return TerminalCell(
            text: style.invisible ? "" : text,
            foreground: cellForeground,
            background: cellBackground,
            bold: style.bold,
            italic: style.italic,
            faint: style.faint,
            underline: Self.underline(style.underline),
            strikethrough: style.strikethrough,
            overline: style.overline,
            blinking: style.blink,
            invisible: style.invisible,
            selected: selected
        )
    }

    private static func color(_ color: GhosttyColorRgb) -> TerminalColor {
        TerminalColor(red: color.r, green: color.g, blue: color.b)
    }

    private static func underline(_ value: Int32) -> TerminalUnderline {
        switch value {
        case GHOSTTY_SGR_UNDERLINE_SINGLE.rawValue: .single
        case GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue: .double
        case GHOSTTY_SGR_UNDERLINE_CURLY.rawValue: .curly
        case GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue: .dotted
        case GHOSTTY_SGR_UNDERLINE_DASHED.rawValue: .dashed
        default: .none
        }
    }

    private static func cursorStyle(_ value: GhosttyRenderStateCursorVisualStyle) -> TerminalCursorStyle {
        switch value {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: .hollowBlock
        default: .block
        }
    }

    private static func dimension(_ value: Int) -> UInt16 {
        UInt16(clamping: max(1, value))
    }
}
#endif
