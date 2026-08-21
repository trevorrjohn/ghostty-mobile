import XCTest
@testable import GhosttyConnect

final class TerminalInteractionTests: XCTestCase {
    func testNormalizesKeyboardInputForPTY() {
        XCTAssertEqual(TerminalInputEncoder.encode("hello\n"), "hello\r")
        XCTAssertEqual(TerminalInputEncoder.encode("one\r\ntwo\n"), "one\rtwo\r")
        XCTAssertEqual(TerminalInputEncoder.backspace, "\u{7f}")
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
