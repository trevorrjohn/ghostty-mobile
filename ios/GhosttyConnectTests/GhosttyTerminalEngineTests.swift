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

    func testEncodesTmuxPrefixSequence() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        let action = KeyboardAction(
            label: "Tmux next",
            steps: [
                KeyboardActionStep(key: .b, modifiers: [.control]),
                KeyboardActionStep(key: .n, modifiers: []),
            ]
        )
        var encoded = Data()
        for event in action.events() { encoded.append(try engine.encode(event: event)) }

        XCTAssertEqual(Array(encoded), [0x02, 0x6e])
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
        XCTAssertEqual(
            try engine.encode(event: .key(.character("/"), text: "?", modifiers: .shift)),
            Data("?".utf8)
        )
        XCTAssertEqual(
            try engine.encode(event: .key(.character("`"), text: "~", modifiers: [.alt, .shift])),
            Data("\u{1b}~".utf8)
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

    func testSnapshotIncludesRemoteTitleAndWorkingDirectory() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 4)
        engine.feed(Data("\u{1b}]0;deploy\u{7}\u{1b}]7;file:///srv/app\u{7}".utf8))

        let snapshot = try engine.snapshot()
        XCTAssertEqual(snapshot.title, "deploy")
        XCTAssertEqual(snapshot.workingDirectory, "file:///srv/app")
    }

    func testEmptyRemoteMetadataClearsSnapshotValues() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 4)
        engine.feed(Data("\u{1b}]2;deploy\u{7}\u{1b}]7;file:///srv/app\u{7}".utf8))
        engine.feed(Data("\u{1b}]2;\u{7}\u{1b}]7;\u{7}".utf8))

        let snapshot = try engine.snapshot()
        XCTAssertNil(snapshot.title)
        XCTAssertNil(snapshot.workingDirectory)
    }

    func testDrainsBellProgressNotificationAndPtyResponseEffects() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 4)
        engine.feed(Data("\u{7}\u{1b}]9;Build complete\u{7}\u{1b}]9;4;1;42\u{7}\u{1b}[5n".utf8))

        let effects = engine.drainEffects()
        XCTAssertEqual(effects.bells, 1)
        XCTAssertEqual(effects.notifications, [TerminalRemoteNotification(title: "", body: "Build complete")])
        XCTAssertEqual(effects.progress, TerminalProgressReport(state: .set, percent: 42))
        XCTAssertEqual(effects.ptyWrite, Data("\u{1b}[0n".utf8))
        XCTAssertEqual(engine.drainEffects(), TerminalEffects())
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

    func testSearchSelectsAcrossSoftWrap() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 5, rows: 3)
        engine.feed(Data("abcdefgh".utf8))

        XCTAssertTrue(engine.search("def", direction: .next))
        XCTAssertEqual(engine.selectedText(), "def")
        XCTAssertEqual(try engine.snapshot().cells.filter(\.selected).count, 3)
    }

    func testSearchFindsOffscreenHistoryAndIgnoresCase() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 3)
        engine.feed(Data("ÄPFEL target\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
        XCTAssertTrue(try engine.snapshot().viewport.isAtBottom)

        XCTAssertTrue(engine.search("äpfel", direction: .previous))
        XCTAssertEqual(engine.selectedText(), "ÄPFEL")
        XCTAssertFalse(try engine.snapshot().viewport.isAtBottom)
    }

    func testSearchDoesNotCrossHardLineBoundary() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 10, rows: 3)
        engine.feed(Data("abc\r\ndef".utf8))

        XCTAssertFalse(engine.search("cde", direction: .next))
        XCTAssertFalse(try engine.snapshot().hasSelection)
    }

    func testSearchRejectsOversizedQueryWithoutChangingSelection() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 10, rows: 3)
        engine.feed(Data("needle".utf8))
        XCTAssertTrue(engine.search("needle", direction: .next))

        XCTAssertFalse(engine.search(String(repeating: "x", count: 1_025), direction: .next))
        XCTAssertEqual(engine.selectedText(), "needle")
    }

    func testSearchNextAndPreviousWrapBetweenMatches() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 3)
        engine.feed(Data("hit one\r\ntwo\r\nthree\r\nfour\r\nhit two".utf8))

        XCTAssertTrue(engine.search("hit", direction: .next))
        let newestOffset = try engine.snapshot().viewport.offset
        XCTAssertTrue(engine.search("hit", direction: .next))
        let oldestOffset = try engine.snapshot().viewport.offset
        XCTAssertLessThan(oldestOffset, newestOffset)
        XCTAssertTrue(engine.search("hit", direction: .previous))
        XCTAssertEqual(try engine.snapshot().viewport.offset, newestOffset)
    }

    func testSelectsAndFormatsWord() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 20, rows: 3)
        engine.feed(Data("hello world".utf8))
        XCTAssertTrue(engine.selectWord(column: 1, row: 0))
        XCTAssertEqual(engine.selectedText(), "hello")
        let selected = try engine.snapshot()
        XCTAssertEqual(selected.cells.filter(\.selected).count, 5)
        XCTAssertEqual(selected.selectionEndpoints?.start, TerminalSelectionPoint(column: 0, row: 0))
        XCTAssertEqual(selected.selectionEndpoints?.end, TerminalSelectionPoint(column: 4, row: 0))

        engine.feed(Data("\r\none\r\ntwo\r\nthree\r\nfour".utf8))
        let offscreen = try engine.snapshot()
        XCTAssertTrue(offscreen.hasSelection)
        XCTAssertFalse(offscreen.cells.contains(where: \.selected))
        XCTAssertEqual(offscreen.selectionEndpoints, TerminalSelectionEndpoints(start: nil, end: nil))
        XCTAssertEqual(engine.selectedText(), "hello")

        engine.clearSelection()
        XCTAssertFalse(try engine.snapshot().hasSelection)
    }

    func testExtendsSelectionAcrossRows() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 10, rows: 4)
        engine.feed(Data("one\r\ntwo\r\nthree".utf8))
        XCTAssertTrue(engine.selectWord(column: 1, row: 1))

        XCTAssertTrue(engine.setSelectionEndpoint(start: false, column: 2, row: 2))
        XCTAssertEqual(engine.selectedText(), "two\nthr")
        let snapshot = try engine.snapshot()
        XCTAssertEqual(snapshot.selectionEndpoints?.end, TerminalSelectionPoint(column: 2, row: 2))
        let selectedRows = Set(snapshot.cells.enumerated().compactMap { index, cell in
            cell.selected ? index / 10 : nil
        })
        XCTAssertEqual(selectedRows, Set([1, 2]))
    }

    func testSelectionEndpointRequiresValidSelectionAndCoordinate() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make(columns: 10, rows: 3)
        engine.feed(Data("one two".utf8))
        XCTAssertFalse(engine.setSelectionEndpoint(start: false, column: 2, row: 0))
        XCTAssertTrue(engine.selectWord(column: 5, row: 0))
        XCTAssertFalse(engine.setSelectionEndpoint(start: true, column: -1, row: 0))
        XCTAssertEqual(engine.selectedText(), "two")
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

    func testDrainsStandardOSC52ClipboardWrites() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        engine.feed(Data("\u{1b}]52;c;aGVsbG8=\u{7}".utf8))
        XCTAssertEqual(engine.drainClipboardWrites(), [.text("hello")])
        XCTAssertTrue(engine.drainClipboardWrites().isEmpty)

        engine.feed(Data("\u{1b}]52;c;\u{7}".utf8))
        XCTAssertEqual(engine.drainClipboardWrites(), [.clear])
    }

    func testRejectsUnsupportedAndMalformedOSC52ClipboardWrites() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        engine.feed(Data("\u{1b}]52;p;aGVsbG8=\u{7}".utf8))
        engine.feed(Data("\u{1b}]52;c;/w==\u{7}".utf8))
        XCTAssertTrue(engine.drainClipboardWrites().isEmpty)
    }

    func testBoundsPendingOSC52ClipboardWrites() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        for value in 0..<9 {
            let payload = Data(String(value).utf8).base64EncodedString()
            engine.feed(Data("\u{1b}]52;c;\(payload)\u{7}".utf8))
        }
        XCTAssertEqual(engine.drainClipboardWrites(), (0..<8).map { .text(String($0)) })

        engine.feed(Data("\u{1b}]52;c;YWdhaW4=\u{7}".utf8))
        XCTAssertEqual(engine.drainClipboardWrites(), [.text("again")])
    }

    func testAcceptsMaximumAndRejectsOversizedOSC52ClipboardWrite() throws {
        guard TerminalEngineFactory.isAvailable else {
            throw XCTSkip("GhosttyVt XCFramework is not installed")
        }

        let engine = try TerminalEngineFactory.make()
        let maximumPayload = Data(repeating: 0x61, count: 1_048_576).base64EncodedString()
        engine.feed(Data("\u{1b}]52;c;\(maximumPayload)\u{7}".utf8))
        guard case .text(let maximumText) = try XCTUnwrap(engine.drainClipboardWrites().first) else {
            return XCTFail("Expected a text clipboard write")
        }
        XCTAssertEqual(maximumText.utf8.count, 1_048_576)

        let payload = Data(repeating: 0x61, count: 1_048_577).base64EncodedString()
        engine.feed(Data("\u{1b}]52;c;\(payload)\u{7}".utf8))
        XCTAssertTrue(engine.drainClipboardWrites().isEmpty)
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
