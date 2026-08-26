import XCTest
import UIKit
@testable import GhosttyConnect

final class TerminalInteractionTests: XCTestCase {
    func testNormalizesKeyboardInputForPTY() {
        XCTAssertEqual(TerminalInputEncoder.encode("hello\n"), "hello\r")
        XCTAssertEqual(TerminalInputEncoder.encode("one\r\ntwo\n"), "one\rtwo\r")
        XCTAssertEqual(TerminalInputEncoder.backspace, "\u{7f}")
    }

    func testNormalizesModifiedHardwareKeys() {
        XCTAssertEqual(
            TerminalKeyboardInputView.event(input: "c", flags: .control),
            .key(.character("C"), text: "c", modifiers: .control)
        )
        XCTAssertEqual(
            TerminalKeyboardInputView.event(input: "1", flags: [.shift, .alternate]),
            .key(.character("1"), text: "!", modifiers: [.shift, .alt])
        )
        XCTAssertEqual(
            TerminalKeyboardInputView.event(input: UIKeyCommand.inputPageDown, flags: .control),
            .key(.pageDown, modifiers: .control)
        )
        XCTAssertEqual(
            TerminalKeyboardInputView.event(input: UIKeyCommand.f12, flags: []),
            .key(.function(12))
        )
        XCTAssertNil(TerminalKeyboardInputView.event(input: "c", flags: .command))
        XCTAssertNil(TerminalKeyboardInputView.event(input: UIKeyCommand.inputLeftArrow, flags: .command))
        XCTAssertEqual(
            TerminalKeyboardInputView.event(input: "1", flags: []).map { $0.adding(.shift) },
            .key(.character("1"), text: "!", modifiers: .shift)
        )
    }

    func testFitsTerminalDimensionsToViewport() {
        let dimensions = TerminalDimensions.fit(
            size: CGSize(width: 390, height: 600),
            fontSize: 15,
            displayScale: 3
        )

        XCTAssertEqual(dimensions.columns, 41)
        XCTAssertEqual(dimensions.rows, 29)
        XCTAssertEqual(dimensions.pixelWidth, 1_170)
        XCTAssertEqual(dimensions.pixelHeight, 1_800)
    }

    func testViewportAlwaysHasAtLeastOneCell() {
        let dimensions = TerminalDimensions.fit(
            size: .zero,
            fontSize: 30,
            displayScale: 3
        )

        XCTAssertEqual(dimensions.columns, 1)
        XCTAssertEqual(dimensions.rows, 1)
    }

    func testMatchesContextualWebLinkWithoutPunctuation() {
        let match = TerminalTokenMatcher.match(
            cells: "(https://example.com/docs).".map(String.init),
            column: 8
        )

        XCTAssertEqual(match?.kind, .link)
        XCTAssertEqual(match?.text, "https://example.com/docs")
        XCTAssertEqual(match?.startColumn, 1)
        XCTAssertEqual(match?.endColumn, 24)
    }

    func testMatchesContextualRelativePath() {
        let match = TerminalTokenMatcher.match(cells: "src/main/App.swift:42".map(String.init), column: 5)

        XCTAssertEqual(match?.kind, .path)
        XCTAssertEqual(match?.text, "src/main/App.swift:42")
    }

    func testIgnoresOrdinaryContextualWord() {
        XCTAssertNil(TerminalTokenMatcher.match(cells: "connected".map(String.init), column: 3))
    }

    func testAllowsOnlyWellFormedWebLinks() {
        XCTAssertNotNil(ContextualSelection.safeWebURL("https://example.com/docs"))
        XCTAssertNil(ContextualSelection.safeWebURL("ftp://example.com/file"))
        XCTAssertNil(ContextualSelection.safeWebURL("https://"))
    }
}
