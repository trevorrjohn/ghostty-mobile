#if canImport(SeanceCore)
import Foundation
import SeanceCore

/// Thin Swift binding over the terminal engine in the shared Zig core
/// (`core/`, ADR 0012). All terminal behavior lives there; this type converts
/// between Swift types and the core's C ABI (`seance_core.h`) and parses its
/// snapshot and effects wire formats into `TerminalSnapshot` and
/// `TerminalEffects`.
final class GhosttyTerminalEngine: TerminalEngine {
    private static let maximumMetadataBytes = 4_096
    private static let maximumHyperlinkBytes = 1_024
    private static let maximumPendingBells = 10
    private static let maximumPendingNotifications = 8
    private static let maximumPendingWrites = 8

    private let engine: OpaquePointer
    /// Guards `pendingEffects` and keeps a snapshot consistent with its selection queries.
    private let lock = NSLock()
    private var pendingEffects = TerminalEffects()

    init(columns: Int, rows: Int) throws {
        var config = ScEngineConfig(
            size: MemoryLayout<ScEngineConfig>.size,
            cols: Self.dimension(columns),
            rows: Self.dimension(rows),
            has_colors: false,
            foreground: 0,
            background: 0,
            cursor: 0,
            palette: nil,
            scrollback_lines: 0
        )
        var created: OpaquePointer?
        guard sc_engine_new(&config, &created) == 0, let created else {
            throw TerminalEngineError.initializationFailed
        }
        engine = created
    }

    deinit {
        sc_engine_free(engine)
    }

    // MARK: Output and effects

    func feed(_ data: Data) {
        data.withUnsafeBytes { bytes in
            _ = sc_engine_write(
                engine,
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bytes.count
            )
        }
    }

    func resize(columns: Int, rows: Int) {
        _ = sc_engine_resize(engine, UInt32(Self.dimension(columns)), UInt32(Self.dimension(rows)), 0, 0)
    }

    func drainClipboardWrites() -> [TerminalClipboardWrite] {
        lock.lock()
        defer { lock.unlock() }
        collectEffects()
        let writes = pendingEffects.clipboardWrites
        pendingEffects.clipboardWrites.removeAll()
        return writes
    }

    func drainEffects() -> TerminalEffects {
        lock.lock()
        defer { lock.unlock() }
        collectEffects()
        let effects = pendingEffects
        pendingEffects = TerminalEffects()
        return effects
    }

    /// Moves the core's queued effects into `pendingEffects`, keeping the
    /// bounds the core applies on its own queues.
    private func collectEffects() {
        guard let data = bytes({ sc_engine_drain_effects(engine, $0) }),
              let drained = try? Self.parseEffects(data) else { return }
        pendingEffects.clipboardWrites.append(contentsOf: drained.clipboardWrites)
        if pendingEffects.clipboardWrites.count > Self.maximumPendingWrites {
            pendingEffects.clipboardWrites.removeLast(pendingEffects.clipboardWrites.count - Self.maximumPendingWrites)
        }
        pendingEffects.bells = min(Self.maximumPendingBells, pendingEffects.bells + drained.bells)
        pendingEffects.notifications.append(contentsOf: drained.notifications)
        if pendingEffects.notifications.count > Self.maximumPendingNotifications {
            pendingEffects.notifications.removeLast(pendingEffects.notifications.count - Self.maximumPendingNotifications)
        }
        if let progress = drained.progress { pendingEffects.progress = progress }
        pendingEffects.ptyWrite.append(drained.ptyWrite)
    }

    // MARK: Input

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

        let name = Array(Self.keyName(key).utf8)
        let utf8 = Array(text.utf8)
        guard let data = bytes({ out in
            name.withUnsafeBufferPointer { name in
                utf8.withUnsafeBufferPointer { text in
                    sc_engine_encode_key(
                        engine,
                        name.baseAddress, name.count,
                        text.baseAddress, text.count,
                        UInt32(modifiers.rawValue),
                        1, // press
                        out
                    )
                }
            }
        }) else { throw TerminalEngineError.keyEncodingFailed }
        return data
    }

    /// The core's key name for a key: W3C-style names, or the character itself.
    private static func keyName(_ key: TerminalKey) -> String {
        switch key {
        case .escape: "ESCAPE"
        case .tab: "TAB"
        case .enter: "ENTER"
        case .backspace: "BACKSPACE"
        case .delete: "DELETE"
        case .insert: "INSERT"
        case .home: "HOME"
        case .end: "END"
        case .pageUp: "PAGE_UP"
        case .pageDown: "PAGE_DOWN"
        case .up: "ARROW_UP"
        case .down: "ARROW_DOWN"
        case .left: "ARROW_LEFT"
        case .right: "ARROW_RIGHT"
        case .function(let number): "F\(number)"
        case .character(let value): value.uppercased()
        }
    }

    func isPasteSafe(_ text: String) -> Bool {
        guard !text.contains("\r") else { return false }
        let utf8 = Array(text.utf8)
        return utf8.withUnsafeBufferPointer { sc_paste_is_safe($0.baseAddress, $0.count) }
    }

    func encodePaste(_ text: String) throws -> Data {
        let utf8 = Array(text.utf8)
        guard let data = bytes({ out in
            utf8.withUnsafeBufferPointer { sc_engine_encode_paste(engine, $0.baseAddress, $0.count, out) }
        }) else { throw TerminalEngineError.pasteEncodingFailed }
        return data
    }

    // MARK: Scrolling

    func scrollViewport(byRows rows: Int) {
        guard rows != 0 else { return }
        sc_engine_scroll(engine, Int32(clamping: rows))
    }

    /// Encodes a viewport scroll as input for applications that own scrolling
    /// (mouse tracking, or alternate screen with alternate scroll). Returns nil
    /// when the terminal's own scrollback should scroll instead.
    func encodeScrollInput(byRows rows: Int) -> Data? {
        guard rows != 0,
              let data = bytes({ sc_engine_encode_scroll(engine, Int32(clamping: rows), $0) }),
              !data.isEmpty else { return nil }
        return data
    }

    func scrollToBottom() {
        sc_engine_scroll_to_bottom(engine)
    }

    // MARK: Search and selection

    func search(_ query: String, direction: TerminalSearchDirection) -> Bool {
        guard !query.isEmpty else { return false }
        let utf8 = Array(query.utf8)
        let result = utf8.withUnsafeBufferPointer {
            sc_engine_search(engine, $0.baseAddress, $0.count, direction == .previous ? -1 : 1)
        }
        return result == 1
    }

    func selectWord(column: Int, row: Int) -> Bool {
        sc_engine_select_word(engine, Int32(clamping: column), Int32(clamping: row)) == 1
    }

    func setSelectionEndpoint(start: Bool, column: Int, row: Int) -> Bool {
        sc_engine_set_selection_endpoint(engine, start, Int32(clamping: column), Int32(clamping: row)) == 1
    }

    func selectRange(startColumn: Int, endColumn: Int, row: Int) -> Bool {
        sc_engine_select_range(
            engine,
            Int32(clamping: startColumn),
            Int32(clamping: endColumn),
            Int32(clamping: row)
        ) == 1
    }

    func selectOutput(column: Int, row: Int) -> Bool {
        sc_engine_select_output(engine, Int32(clamping: column), Int32(clamping: row)) == 1
    }

    func hyperlink(column: Int, row: Int) -> String? {
        guard let data = bytes({ sc_engine_hyperlink(engine, Int32(clamping: column), Int32(clamping: row), $0) }),
              !data.isEmpty, data.count <= Self.maximumHyperlinkBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clearSelection() {
        _ = sc_engine_clear_selection(engine)
    }

    func selectedText() -> String {
        guard let data = bytes({ sc_engine_selected_text(engine, $0) }) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func visibleText() -> String {
        guard let data = bytes({ sc_engine_plain_text(engine, $0) }) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Snapshot

    func snapshot() throws -> TerminalSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let data = bytes({ sc_engine_snapshot(engine, true, $0) }) else {
            throw TerminalEngineError.snapshotFailed
        }
        var endpoints: TerminalSelectionEndpoints?
        if sc_engine_has_selection(engine) {
            var points: [Int32] = [-1, -1, -1, -1]
            sc_engine_selection_endpoints(engine, &points)
            func point(_ column: Int32, _ row: Int32) -> TerminalSelectionPoint? {
                column < 0 || row < 0 ? nil : TerminalSelectionPoint(column: Int(column), row: Int(row))
            }
            endpoints = TerminalSelectionEndpoints(
                start: point(points[0], points[1]),
                end: point(points[2], points[3])
            )
        }
        return try Self.parseSnapshot(data, selectionEndpoints: endpoints)
    }

    // MARK: Helpers

    private static func dimension(_ value: Int) -> UInt16 {
        UInt16(clamping: max(1, value))
    }

    /// Runs a core call that fills an `ScBytes` and returns its contents, or nil on failure.
    private func bytes(_ call: (UnsafeMutablePointer<ScBytes>) -> Int32) -> Data? {
        var out = ScBytes(ptr: nil, len: 0)
        guard call(&out) >= 0 else { return nil }
        defer { sc_bytes_free(out.ptr, out.len) }
        guard let pointer = out.ptr, out.len > 0 else { return Data() }
        return Data(bytes: pointer, count: out.len)
    }
}

// MARK: - Wire formats

/// Reads the little-endian int32 stream the core produces.
private struct WireReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { offset == data.count }

    mutating func int32() throws -> Int32 {
        guard data.count - offset >= 4 else { throw TerminalEngineError.snapshotFailed }
        let base = data.startIndex + offset
        let value = UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
        offset += 4
        return Int32(bitPattern: value)
    }

    mutating func bytes() throws -> Data {
        let length = Int(try int32())
        guard length >= 0, data.count - offset >= length else { throw TerminalEngineError.snapshotFailed }
        let start = data.startIndex + offset
        offset += length
        return data.subdata(in: start..<start + length)
    }

    mutating func string() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }
}

private extension GhosttyTerminalEngine {
    static let snapshotMagic: Int32 = 0x4756_5431

    static func parseSnapshot(_ data: Data, selectionEndpoints: TerminalSelectionEndpoints?) throws -> TerminalSnapshot {
        var reader = WireReader(data)
        guard try reader.int32() == snapshotMagic else { throw TerminalEngineError.snapshotFailed }
        let columns = Int(try reader.int32())
        let rows = Int(try reader.int32())
        guard columns > 0, rows > 0, columns <= 4_096, rows <= 4_096 else { throw TerminalEngineError.snapshotFailed }
        let background = color(try reader.int32())
        let foreground = color(try reader.int32())
        let cursorColor = color(try reader.int32())
        let cursorColumn = Int(try reader.int32())
        let cursorRow = Int(try reader.int32())
        let cursorStyleCode = Int(try reader.int32())
        let scrollTotal = max(0, Int(try reader.int32()))
        let scrollOffset = max(0, Int(try reader.int32()))
        let scrollVisible = max(0, Int(try reader.int32()))
        let cursorFlags = try reader.int32()
        let title = metadata(try reader.bytes())
        let workingDirectory = metadata(try reader.bytes())
        _ = try reader.int32() // dirty state; a full snapshot always lists every row
        let rowCount = Int(try reader.int32())
        guard rowCount == rows else { throw TerminalEngineError.snapshotFailed }

        var cells: [TerminalCell] = []
        cells.reserveCapacity(columns * rows)
        for expectedRow in 0..<rows {
            guard Int(try reader.int32()) == expectedRow else { throw TerminalEngineError.snapshotFailed }
            for _ in 0..<columns {
                let cellForeground = color(try reader.int32())
                let cellBackground = color(try reader.int32())
                let flags = Int(try reader.int32())
                _ = try reader.int32() // underline color
                let text = try reader.string()
                let invisible = flags & 32 != 0
                cells.append(TerminalCell(
                    text: invisible ? "" : text,
                    foreground: cellForeground,
                    background: cellBackground,
                    bold: flags & 1 != 0,
                    italic: flags & 2 != 0,
                    faint: flags & 4 != 0,
                    underline: underline(flags >> 8 & 0x7),
                    strikethrough: flags & 16 != 0,
                    overline: flags & 128 != 0,
                    blinking: flags & 8 != 0,
                    invisible: invisible,
                    selected: flags & 64 != 0
                ))
            }
        }
        guard reader.isAtEnd else { throw TerminalEngineError.snapshotFailed }

        let cursor: TerminalCursor? = cursorColumn >= 0 && cursorRow >= 0
            ? TerminalCursor(
                column: cursorColumn,
                row: cursorRow,
                visible: cursorStyleCode > 0,
                blinking: cursorFlags & 1 != 0,
                style: cursorStyle(cursorStyleCode - 1)
            )
            : nil
        return TerminalSnapshot(
            columns: columns,
            rows: rows,
            foreground: foreground,
            background: background,
            cursorColor: cursorColor,
            cells: cells,
            cursor: cursor,
            viewport: TerminalViewport(
                totalRows: UInt64(scrollTotal),
                offset: UInt64(scrollOffset),
                visibleRows: UInt64(scrollVisible),
                isAtBottom: scrollOffset + scrollVisible >= scrollTotal
            ),
            hasSelection: selectionEndpoints != nil,
            title: title,
            workingDirectory: workingDirectory,
            selectionEndpoints: selectionEndpoints
        )
    }

    static func metadata(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumMetadataBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// libghostty's SGR underline values.
    static func underline(_ value: Int) -> TerminalUnderline {
        switch value {
        case 1: .single
        case 2: .double
        case 3: .curly
        case 4: .dotted
        case 5: .dashed
        default: .none
        }
    }

    /// libghostty's cursor style values.
    static func cursorStyle(_ value: Int) -> TerminalCursorStyle {
        switch value {
        case 0: .bar
        case 2: .underline
        case 3: .hollowBlock
        default: .block
        }
    }

    static func color(_ argb: Int32) -> TerminalColor {
        let value = UInt32(bitPattern: argb)
        return TerminalColor(red: UInt8(value >> 16 & 0xff), green: UInt8(value >> 8 & 0xff), blue: UInt8(value & 0xff))
    }

    static func parseEffects(_ data: Data) throws -> TerminalEffects {
        var reader = WireReader(data)
        var effects = TerminalEffects()
        effects.bells = Int(try reader.int32())
        let progressState = try reader.int32()
        let progressValue = try reader.int32()
        _ = try reader.int32() // unknown sequence count
        _ = try reader.int32() // VT processing error
        effects.ptyWrite = try reader.bytes()
        for _ in 0..<Int(try reader.int32()) {
            let kind = try reader.int32()
            let text = try reader.bytes()
            if kind == 0 {
                effects.clipboardWrites.append(.clear)
            } else if let string = String(data: text, encoding: .utf8) {
                effects.clipboardWrites.append(.text(string))
            }
        }
        for _ in 0..<Int(try reader.int32()) {
            let title = try reader.string()
            let body = try reader.string()
            effects.notifications.append(TerminalRemoteNotification(title: title, body: body))
        }
        let state: TerminalProgressState?
        switch progressState {
        case 0: state = .remove
        case 1: state = .set
        case 2: state = .error
        case 3: state = .indeterminate
        case 4: state = .paused
        default: state = nil
        }
        if let state {
            effects.progress = TerminalProgressReport(
                state: state,
                percent: (0...100).contains(Int(progressValue)) ? Int(progressValue) : nil
            )
        }
        return effects
    }
}
#endif
