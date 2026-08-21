import XCTest
@testable import GhosttyConnect

final class KeyboardBarTests: XCTestCase {
    func testDefaultsMatchSharedBasicOrder() {
        XCTAssertEqual(KeyboardBarConfig.defaults.items, [
            .builtIn(.escape), .builtIn(.control), .builtIn(.alt), .builtIn(.tab),
            .builtIn(.shift), .builtIn(.up), .builtIn(.down), .builtIn(.left), .builtIn(.right),
        ])
    }

    func testConfigurationRoundTripsIncludingEmptyBar() throws {
        let action = KeyboardAction(label: "Interrupt", key: .c, modifiers: [.control])
        let config = KeyboardBarConfig(enabled: false, items: [.action(action.id)], actions: [action])
        let decoded = try JSONDecoder().decode(
            KeyboardBarConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded, config)
    }

    func testMigratesVersionOneAndFiltersUnknownAndDuplicateItems() throws {
        let data = Data(#"{"version":1,"enabled":true,"itemIDs":["escape","future","escape","tab"]}"#.utf8)

        let decoded = try JSONDecoder().decode(KeyboardBarConfig.self, from: data)

        XCTAssertEqual(decoded.items, [.builtIn(.escape), .builtIn(.tab)])
        XCTAssertTrue(decoded.actions.isEmpty)
    }

    func testRejectsUnsupportedConfigurationVersion() {
        let data = Data(#"{"version":3,"enabled":true,"items":[],"actions":[]}"#.utf8)

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

    func testSavesAddsAndDeletesCustomAction() {
        var config = KeyboardBarConfig(enabled: true, items: [])
        let action = KeyboardAction(label: "Interrupt", key: .c, modifiers: [.control])

        config.saveAction(action, addToBar: true)
        XCTAssertEqual(config.actions, [action])
        XCTAssertEqual(config.items, [.action(action.id)])
        XCTAssertEqual(action.event, .key(.character("C"), text: "c", modifiers: .control))

        config.deleteAction(id: action.id)
        XCTAssertTrue(config.actions.isEmpty)
        XCTAssertTrue(config.items.isEmpty)
    }

    func testRejectsInvalidAndUnreferencedCustomActions() throws {
        let id = UUID()
        let invalid = KeyboardAction(id: id, label: "   ", key: .c, modifiers: [.control])
        var config = KeyboardBarConfig(enabled: true, items: [.action(id)], actions: [invalid])

        XCTAssertTrue(config.actions.isEmpty)
        XCTAssertTrue(config.items.isEmpty)

        config.saveAction(KeyboardAction(label: "No modifier", key: .c, modifiers: []), addToBar: true)
        XCTAssertTrue(config.actions.isEmpty)
    }

    func testNormalizesDecodedActionLabel() throws {
        let id = UUID()
        let longLabel = String(repeating: "x", count: KeyboardAction.maximumLabelBytes + 10)
        let data = Data(#"{"version":2,"enabled":true,"items":["action:\#(id.uuidString)"],"actions":[{"id":"\#(id.uuidString)","label":"  \#(longLabel)  ","key":"c","modifiers":["control"]}]}"#.utf8)

        let config = try JSONDecoder().decode(KeyboardBarConfig.self, from: data)

        XCTAssertEqual(config.actions.first?.label.utf8.count, KeyboardAction.maximumLabelBytes)
        XCTAssertEqual(config.items, [.action(id)])
    }

    func testBoundsLabelByUTF8Bytes() {
        let action = KeyboardAction(
            label: String(repeating: "é", count: KeyboardAction.maximumLabelBytes),
            key: .c,
            modifiers: [.control]
        )

        XCTAssertLessThanOrEqual(action.label.utf8.count, KeyboardAction.maximumLabelBytes)
    }

    func testShiftedActionUsesGeneratedText() {
        let letter = KeyboardAction(label: "Upper A", key: .a, modifiers: [.shift])
        let digit = KeyboardAction(label: "Bang", key: .one, modifiers: [.shift])

        XCTAssertEqual(letter.event, .key(.character("A"), text: "A", modifiers: .shift))
        XCTAssertEqual(digit.event, .key(.character("1"), text: "!", modifiers: .shift))
    }
}
