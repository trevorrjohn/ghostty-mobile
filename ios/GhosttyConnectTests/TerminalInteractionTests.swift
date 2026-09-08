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
        XCTAssertEqual(
            TerminalKeyboardInputView.event(input: "a", flags: .alphaShift),
            .key(.character("A"), text: "a", modifiers: .capsLock)
        )
        XCTAssertNil(TerminalKeyboardInputView.event(input: "c", flags: .command))
        XCTAssertNil(TerminalKeyboardInputView.event(input: UIKeyCommand.inputLeftArrow, flags: .command))
        XCTAssertEqual(
            TerminalKeyboardInputView.event(input: "1", flags: []).map { $0.adding(.shift) },
            .key(.character("1"), text: "!", modifiers: .shift)
        )
    }

    func testNormalizesExternalKeyboardPunctuation() {
        let shifted: [(String, String)] = [
            ("`", "~"), ("-", "_"), ("=", "+"), ("[", "{"), ("]", "}"),
            ("\\", "|"), (";", ":"), ("'", "\""), (",", "<"), (".", ">"), ("/", "?"),
        ]

        for (input, output) in shifted {
            XCTAssertEqual(
                TerminalKeyboardInputView.event(input: input, flags: .shift),
                .key(.character(input), text: output, modifiers: .shift)
            )
            XCTAssertEqual(
                TerminalKeyboardInputView.event(input: input, flags: []),
                .key(.character(input), text: input)
            )
        }
        XCTAssertNil(TerminalKeyboardInputView.event(input: "é", flags: []))
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

    func testSelectionDragChoosesAndKeepsForwardEndpoint() {
        var drag = TerminalSelectionDragState()
        drag.begin(column: 4, row: 2)

        XCTAssertNil(drag.update(column: 4, row: 2))
        XCTAssertEqual(drag.update(column: 5, row: 2), .end)
        XCTAssertNil(drag.update(column: 1, row: 1))
    }

    func testSelectionDragChoosesBackwardEndpointAndResets() {
        var drag = TerminalSelectionDragState()
        drag.begin(column: 4, row: 2)

        XCTAssertEqual(drag.update(column: 9, row: 1), .start)
        drag.reset()
        XCTAssertNil(drag.update(column: 0, row: 0))
        XCTAssertNil(drag.anchor)
        XCTAssertNil(drag.endpoint)
    }

    func testSelectionAutoscrollUsesOnlyMatchingEndpointDirection() {
        var drag = TerminalSelectionDragState()
        drag.begin(column: 4, row: 2)

        XCTAssertEqual(drag.endpointForAutoscroll(direction: -1), .start)
        XCTAssertNil(drag.endpointForAutoscroll(direction: 1))
        drag.reset()
        XCTAssertNil(drag.endpointForAutoscroll(direction: -1))
    }

    func testSelectionAutoscrollStopsOutsideEdgesAndOnReset() {
        var autoscroll = TerminalSelectionAutoscrollState()

        autoscroll.update(locationY: 10, height: 300, edgeHeight: 30)
        XCTAssertEqual(autoscroll.rowDelta, -1)
        autoscroll.update(locationY: 290, height: 300, edgeHeight: 30)
        XCTAssertEqual(autoscroll.rowDelta, 1)
        autoscroll.update(locationY: 150, height: 300, edgeHeight: 30)
        XCTAssertEqual(autoscroll.rowDelta, 0)
        autoscroll.update(locationY: 290, height: 300, edgeHeight: 30)
        autoscroll.reset()
        XCTAssertEqual(autoscroll.rowDelta, 0)
    }

    func testSelectionHandleDoesNotCrossOppositeEndpoint() {
        let endpoints = TerminalSelectionEndpoints(
            start: TerminalSelectionPoint(column: 2, row: 1),
            end: TerminalSelectionPoint(column: 7, row: 2)
        )
        var drag = TerminalSelectionHandleDragState()

        drag.begin(endpoint: .start, endpoints: endpoints)
        XCTAssertTrue(drag.allows(TerminalSelectionPoint(column: 6, row: 2)))
        XCTAssertFalse(drag.allows(TerminalSelectionPoint(column: 8, row: 2)))
        drag.reset()
        XCTAssertFalse(drag.allows(TerminalSelectionPoint(column: 0, row: 0)))
    }

    func testSelectionHandlePreservesReversedSelectionDirection() {
        let endpoints = TerminalSelectionEndpoints(
            start: TerminalSelectionPoint(column: 7, row: 2),
            end: TerminalSelectionPoint(column: 2, row: 1)
        )
        var drag = TerminalSelectionHandleDragState()

        drag.begin(endpoint: .start, endpoints: endpoints)
        XCTAssertTrue(drag.allows(TerminalSelectionPoint(column: 3, row: 1)))
        XCTAssertFalse(drag.allows(TerminalSelectionPoint(column: 1, row: 1)))
    }
}
