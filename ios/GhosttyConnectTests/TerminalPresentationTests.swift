import XCTest
@testable import GhosttyConnect

final class TerminalPresentationTests: XCTestCase {
    func testCursorBlinkPhaseAlternatesEveryHalfSecond() {
        let origin = Date(timeIntervalSinceReferenceDate: 10)
        XCTAssertTrue(TerminalCursorBlinkPhase.isVisible(at: origin))
        XCTAssertTrue(TerminalCursorBlinkPhase.isVisible(at: origin.addingTimeInterval(0.49)))
        XCTAssertFalse(TerminalCursorBlinkPhase.isVisible(at: origin.addingTimeInterval(0.5)))
        XCTAssertFalse(TerminalCursorBlinkPhase.isVisible(at: origin.addingTimeInterval(0.99)))
        XCTAssertTrue(TerminalCursorBlinkPhase.isVisible(at: origin.addingTimeInterval(1)))
    }

    func testWorkingDirectoryDisplayDecodesFileURL() {
        XCTAssertEqual(terminalWorkingDirectoryDisplay("file:///srv/My%20App"), "/srv/My App")
        XCTAssertEqual(terminalWorkingDirectoryDisplay("file://server/srv/app"), "server:/srv/app")
        XCTAssertEqual(terminalWorkingDirectoryDisplay("/srv/app"), "/srv/app")
    }

    func testProgressDisplayPreservesTypedState() {
        XCTAssertEqual(terminalProgressDisplay(TerminalProgressReport(state: .set, percent: 42)), "Progress 42%")
        XCTAssertEqual(terminalProgressDisplay(TerminalProgressReport(state: .indeterminate, percent: nil)), "In progress")
        XCTAssertEqual(terminalProgressDisplay(TerminalProgressReport(state: .paused, percent: 80)), "Paused at 80%")
        XCTAssertEqual(terminalProgressDisplay(TerminalProgressReport(state: .error, percent: nil)), "Failed")
    }
}
