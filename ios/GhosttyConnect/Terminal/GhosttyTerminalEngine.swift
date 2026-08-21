#if canImport(GhosttyVt)
import Foundation
import GhosttyVt

final class GhosttyTerminalEngine: TerminalEngine {
    private let terminal: GhosttyTerminal
    private let formatter: GhosttyFormatter
    private let renderState: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    private let lock = NSLock()

    init(columns: Int, rows: Int) throws {
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
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            ghostty_terminal_vt_write(
                terminal,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                bytes.count
            )
        }
    }

    func resize(columns: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
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
            hasSelection: selectionResult == GHOSTTY_SUCCESS
        )
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
