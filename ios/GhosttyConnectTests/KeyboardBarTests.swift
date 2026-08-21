import XCTest
@testable import GhosttyConnect

final class KeyboardBarTests: XCTestCase {
    func testDefaultsMatchSharedBasicOrder() {
        XCTAssertEqual(KeyboardBarConfig.defaults.itemIDs, [
            .escape, .control, .alt, .tab, .shift, .up, .down, .left, .right,
        ])
    }

    func testConfigurationRoundTripsIncludingEmptyBar() throws {
        let config = KeyboardBarConfig(enabled: false, itemIDs: [])
        let decoded = try JSONDecoder().decode(
            KeyboardBarConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded, config)
    }

    func testDecodeFiltersUnknownAndDuplicateItems() throws {
        let data = Data(#"{"version":1,"enabled":true,"itemIDs":["escape","future","escape","tab"]}"#.utf8)

        let decoded = try JSONDecoder().decode(KeyboardBarConfig.self, from: data)

        XCTAssertEqual(decoded.itemIDs, [.escape, .tab])
    }

    func testRejectsUnsupportedConfigurationVersion() {
        let data = Data(#"{"version":2,"enabled":true,"itemIDs":[]}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardBarConfig.self, from: data))
    }

    func testOneShotModifiersToggleAndConsume() {
        var state = KeyboardBarRuntimeState()
        state.toggle(.control)
        state.toggle(.alt)
        XCTAssertEqual(state.activeModifiers, [.control, .alt])

        state.toggle(.alt)
        XCTAssertEqual(state.activeModifiers, [.control])

        state.consume()
        XCTAssertTrue(state.activeModifiers.isEmpty)
    }
}
