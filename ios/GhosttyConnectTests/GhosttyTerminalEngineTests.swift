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
}
