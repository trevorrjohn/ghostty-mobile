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
}
