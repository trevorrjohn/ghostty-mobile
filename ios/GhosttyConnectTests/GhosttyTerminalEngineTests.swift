import XCTest
@testable import GhosttyConnect

final class GhosttyTerminalEngineTests: XCTestCase {
    func testParsesVTIntoVisibleText() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 4)
        engine.feed(Data("plain \u{1b}[31mred\u{1b}[0m\r\n".utf8))

        let visibleText = engine.visibleText()
        XCTAssertTrue(visibleText.contains("plain red"))
        XCTAssertFalse(visibleText.contains("\u{1b}"))
    }

    func testEncodesTextAsUTF8() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        XCTAssertEqual(try engine.encode(event: .text("λ 日本語")), Data("λ 日本語".utf8))
    }

    func testEncodesCursorKeysFromTerminalMode() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        XCTAssertEqual(try engine.encode(event: .key(.up)), Data("\u{1b}[A".utf8))

        engine.feed(Data("\u{1b}[?1h".utf8))
        XCTAssertEqual(try engine.encode(event: .key(.up)), Data("\u{1b}OA".utf8))
    }

    func testEncodesBroaderNamedAndFunctionKeys() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        XCTAssertEqual(try engine.encode(event: .key(.enter)), Data("\r".utf8))
        XCTAssertEqual(try engine.encode(event: .key(.delete)), Data("\u{1b}[3~".utf8))
        XCTAssertEqual(try engine.encode(event: .key(.pageDown)), Data("\u{1b}[6~".utf8))
        XCTAssertEqual(try engine.encode(event: .key(.function(1))), Data("\u{1b}OP".utf8))
        XCTAssertEqual(try engine.encode(event: .key(.function(12))), Data("\u{1b}[24~".utf8))
    }

    func testEncodesControlCharacterThroughKeyEncoder() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        let encoded = try engine.encode(event: .key(.character("C"), text: "c", modifiers: .control))
        XCTAssertEqual(Array(encoded), [0x03])
    }

    func testEncodesShiftedTextAndTab() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        XCTAssertEqual(try engine.encode(event: .text("A", modifiers: .shift)), Data("A".utf8))
        XCTAssertEqual(try engine.encode(event: .key(.tab, modifiers: .shift)), Data("\u{1b}[Z".utf8))
    }

    func testEncodesShiftedCustomActionCharacters() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        XCTAssertEqual(
            try engine.encode(event: .key(.character("A"), text: "A", modifiers: .shift)),
            Data("A".utf8)
        )
        XCTAssertEqual(
            try engine.encode(event: .key(.character("1"), text: "!", modifiers: .shift)),
            Data("!".utf8)
        )
        XCTAssertEqual(
            try engine.encode(event: .key(.character("A"), text: "A", modifiers: [.alt, .shift])),
            Data("\u{1b}A".utf8)
        )
    }

    func testEncodesModifiedCharacterInKittyMode() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        engine.feed(Data("\u{1b}[>1u".utf8))
        let encoded = try engine.encode(event: .key(.character("C"), text: "c", modifiers: .control))

        XCTAssertEqual(encoded, Data("\u{1b}[99;5u".utf8))
    }

    func testSnapshotsStylesAndCursor() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 10, rows: 3)
        engine.feed(Data("\u{1b}[1;3;4;9;38;2;12;34;56;48;2;20;30;40mX\u{1b}[0m".utf8))

        let snapshot = try engine.snapshot()
        let cell = try XCTUnwrap(snapshot.cell(column: 0, row: 0))
        XCTAssertEqual(cell.text, "X")
        XCTAssertEqual(cell.foreground, TerminalColor(red: 12, green: 34, blue: 56))
        XCTAssertEqual(cell.background, TerminalColor(red: 20, green: 30, blue: 40))
        XCTAssertTrue(cell.bold)
        XCTAssertTrue(cell.italic)
        XCTAssertEqual(cell.underline, .single)
        XCTAssertTrue(cell.strikethrough)
        XCTAssertEqual(snapshot.cursor?.column, 1)
        XCTAssertEqual(snapshot.cursor?.row, 0)
        XCTAssertTrue(snapshot.cursor?.visible == true)
    }

    func testSnapshotReflectsResize() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 10, rows: 3)
        engine.resize(columns: 7, rows: 5)

        let snapshot = try engine.snapshot()
        XCTAssertEqual(snapshot.columns, 7)
        XCTAssertEqual(snapshot.rows, 5)
        XCTAssertEqual(snapshot.cells.count, 35)
    }

    func testScrollsRetainedHistoryAndReturnsToLiveOutput() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 12, rows: 3)
        engine.feed(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
        let live = try engine.snapshot()
        XCTAssertTrue(live.viewport.isAtBottom)
        XCTAssertGreaterThan(live.viewport.totalRows, live.viewport.visibleRows)

        engine.scrollViewport(byRows: -2)
        let history = try engine.snapshot()
        XCTAssertFalse(history.viewport.isAtBottom)
        XCTAssertLessThan(history.viewport.offset, live.viewport.offset)

        engine.scrollToBottom()
        XCTAssertTrue(try engine.snapshot().viewport.isAtBottom)
    }

    func testSelectsAndFormatsWord() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 3)
        engine.feed(Data("hello world".utf8))
        XCTAssertTrue(engine.selectWord(column: 1, row: 0))
        XCTAssertEqual(engine.selectedText(), "hello")
        XCTAssertEqual(try engine.snapshot().cells.filter(\.selected).count, 5)

        engine.feed(Data("\r\none\r\ntwo\r\nthree\r\nfour".utf8))
        let offscreen = try engine.snapshot()
        XCTAssertTrue(offscreen.hasSelection)
        XCTAssertFalse(offscreen.cells.contains(where: \.selected))
        XCTAssertEqual(engine.selectedText(), "hello")

        engine.clearSelection()
        XCTAssertFalse(try engine.snapshot().hasSelection)
    }

    func testSelectsRangeAndSemanticOutputAtPoint() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 30, rows: 4)
        engine.feed(Data("/tmp/report.txt".utf8))
        XCTAssertTrue(engine.selectRange(startColumn: 0, endColumn: 14, row: 0))
        XCTAssertEqual(engine.selectedText(), "/tmp/report.txt")

        let outputEngine = try TerminalEngineFactory.make(columns: 30, rows: 4)
        outputEngine.feed(Data((
            "\u{1b}]133;A;cl=line\u{7}$ \u{1b}]133;B\u{7}generate\r\n" +
                "\u{1b}]133;C\u{7}generated output\r\n\u{1b}]133;D;0\u{7}"
        ).utf8))
        XCTAssertTrue(outputEngine.selectOutput(column: 2, row: 1))
        XCTAssertEqual(outputEngine.selectedText(), "generated output")
    }

    func testReadsOSC8Hyperlink() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 2)
        engine.feed(Data("\u{1b}]8;;https://example.com\u{7}docs\u{1b}]8;;\u{7}".utf8))
        XCTAssertEqual(engine.hyperlink(column: 1, row: 0), "https://example.com")
        XCTAssertNil(engine.hyperlink(column: 6, row: 0))
    }

    func testEncodesSafeAndConfirmedPasteForTerminalMode() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        XCTAssertTrue(engine.isPasteSafe("printf test"))
        XCTAssertFalse(engine.isPasteSafe("first\nsecond"))
        XCTAssertFalse(engine.isPasteSafe("command\r"))
        XCTAssertFalse(engine.isPasteSafe("value\u{1b}[201~command"))
        XCTAssertEqual(try engine.encodePaste("first\nsecond"), Data("first\rsecond".utf8))

        engine.feed(Data("\u{1b}[?2004h".utf8))
        XCTAssertEqual(
            try engine.encodePaste("first\nsecond"),
            Data("\u{1b}[200~first\nsecond\u{1b}[201~".utf8)
        )
    }
}
