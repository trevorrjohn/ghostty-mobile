import XCTest
import UIKit
@testable import GhosttyConnect

@MainActor
final class TerminalQuickActionTests: XCTestCase {
    func testHoldThenSwipeDispatchesOnceAtOriginalCellWithoutScrollingOrSelecting() {
        var actions: [TerminalQuickDirection] = []
        var selected = false
        let overlay = makeOverlay(onSelect: { selected = true }) { direction, column, row in
            actions.append(direction)
            XCTAssertEqual(column, 10)
            XCTAssertEqual(row, 5)
        }
        let coordinator = overlay.makeCoordinator()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let gesture = SimulatedTerminalHold()
        view.addGestureRecognizer(gesture)
        gesture.point = CGPoint(x: 100, y: 100)
        gesture.simulatedState = .began
        coordinator.longPress(gesture)
        XCTAssertFalse(view.subviews.isEmpty)
        XCTAssertTrue(actions.isEmpty)
        gesture.point.x += 60
        gesture.simulatedState = .changed
        coordinator.longPress(gesture)
        XCTAssertTrue(actions.isEmpty)
        gesture.simulatedState = .ended
        coordinator.longPress(gesture)
        XCTAssertEqual(actions, [.right])
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertFalse(selected)
    }

    func testCancelledHoldDoesNotDispatchAndRemovesControls() {
        let overlay = makeOverlay { _, _, _ in XCTFail("A cancelled gesture must not send input") }
        let coordinator = overlay.makeCoordinator()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let gesture = SimulatedTerminalHold()
        view.addGestureRecognizer(gesture)
        gesture.point = CGPoint(x: 100, y: 100)
        gesture.simulatedState = .began
        coordinator.longPress(gesture)
        gesture.point.y += 80
        gesture.simulatedState = .cancelled
        coordinator.longPress(gesture)
        XCTAssertTrue(view.subviews.isEmpty)
    }

    func testCenteredReleasePinsButtonsAndTapDispatches() throws {
        var actions: [TerminalQuickDirection] = []
        let overlay = makeOverlay { direction, _, _ in actions.append(direction) }
        let coordinator = overlay.makeCoordinator()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let gesture = SimulatedTerminalHold()
        view.addGestureRecognizer(gesture)
        gesture.point = CGPoint(x: 100, y: 100)
        gesture.simulatedState = .began
        coordinator.longPress(gesture)
        gesture.simulatedState = .ended
        coordinator.longPress(gesture)
        XCTAssertTrue(actions.isEmpty)
        let panel = try XCTUnwrap(view.subviews.first)
        let button = try XCTUnwrap(panel.subviews.compactMap { $0 as? UIButton }.first { $0.configuration?.title == "← Next session" })
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, [.left])
        XCTAssertTrue(view.subviews.isEmpty)
    }

    func testExistingSelectionKeepsLongPressSelectionBehavior() {
        var selected = false
        var overlay = makeOverlay(onSelect: { selected = true }) { _, _, _ in XCTFail("Must select instead") }
        overlay = TerminalInteractionOverlay(
            scrollMultiplier: overlay.scrollMultiplier, cellWidth: 10, cellHeight: 20, columns: 40, rows: 25,
            selectionEndpoints: nil, onTap: {}, onDoubleTap: { _, _ in }, onScrollRows: { _ in },
            onSelectWord: overlay.onSelectWord, onSelectionEndpointChanged: { _, _, _ in }, onSelectionFinished: {},
            onMagnify: { _, _ in }, onQuickNavigation: nil, quickActionLabels: [:], onQuickAction: overlay.onQuickAction,
            interactionID: nil
        )
        let coordinator = overlay.makeCoordinator()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let gesture = SimulatedTerminalHold()
        view.addGestureRecognizer(gesture)
        gesture.point = CGPoint(x: 100, y: 100)
        gesture.simulatedState = .began
        coordinator.longPress(gesture)
        XCTAssertTrue(selected)
        XCTAssertTrue(view.subviews.isEmpty)
    }

    private func makeOverlay(onSelect: @escaping () -> Void = {}, action: @escaping (TerminalQuickDirection, Int, Int) -> Void) -> TerminalInteractionOverlay {
        TerminalInteractionOverlay(
            scrollMultiplier: 1, cellWidth: 10, cellHeight: 20, columns: 40, rows: 25,
            selectionEndpoints: nil, onTap: {}, onDoubleTap: { _, _ in }, onScrollRows: { _ in XCTFail("Must not scroll") },
            onSelectWord: { _, _ in onSelect() }, onSelectionEndpointChanged: { _, _, _ in }, onSelectionFinished: {},
            onMagnify: { _, _ in }, onQuickNavigation: {},
            quickActionLabels: [.up: "Search", .right: "Paste", .down: "Escape", .left: "Next session"],
            onQuickAction: action, interactionID: nil
        )
    }
}

private final class SimulatedTerminalHold: UILongPressGestureRecognizer {
    var simulatedState: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { simulatedState }
        set { simulatedState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
}
