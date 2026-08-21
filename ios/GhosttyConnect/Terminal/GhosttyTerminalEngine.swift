#if canImport(GhosttyVt)
import Foundation
import GhosttyVt

final class GhosttyTerminalEngine: TerminalEngine {
    private let terminal: GhosttyTerminal
    private let formatter: GhosttyFormatter
    private let renderState: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells
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

        self.terminal = terminal
        self.formatter = formatter
        self.renderState = renderState
        self.rowIterator = rowIterator
        self.rowCells = rowCells
    }

    deinit {
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

    func encode(text: String) -> Data {
        Data(text.utf8)
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
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &columns) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &foreground) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &background) == GHOSTTY_SUCCESS else {
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
            cursor: cursor
        )
    }

    private func snapshotCell(
        defaultForeground: TerminalColor,
        defaultBackground: TerminalColor
    ) throws -> TerminalCell {
        var graphemeLength: UInt32 = 0
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        guard ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLength) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS else {
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
            invisible: style.invisible
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
