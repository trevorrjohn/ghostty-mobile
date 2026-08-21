import XCTest
@testable import GhosttyConnect

final class KnownHostValidatorTests: XCTestCase {
    func testTrustsFirstUse() {
        XCTAssertEqual(KnownHostDecision.decide(stored: nil, presented: "key-a"), .trustFirstUse)
        XCTAssertEqual(KnownHostDecision.decide(stored: "", presented: "key-a"), .trustFirstUse)
    }

    func testAcceptsMatchingKey() {
        XCTAssertEqual(KnownHostDecision.decide(stored: "key-a", presented: "key-a"), .trusted)
    }

    func testRejectsChangedKey() {
        XCTAssertEqual(KnownHostDecision.decide(stored: "key-a", presented: "key-b"), .mismatch)
    }
}
