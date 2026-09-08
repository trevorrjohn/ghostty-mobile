import XCTest
@testable import GhosttyConnect

final class ReconnectPolicyTests: XCTestCase {
    func testBalancedBackoffAndAttemptLimit() {
        var policy = ReconnectPolicy()

        XCTAssertEqual(policy.nextDelayNanoseconds(maxAttempts: 3, backoff: .balanced), 0)
        XCTAssertEqual(policy.beginAttempt(maxAttempts: 3), 1)
        XCTAssertEqual(policy.nextDelayNanoseconds(maxAttempts: 3, backoff: .balanced), 2_000_000_000)
        XCTAssertEqual(policy.beginAttempt(maxAttempts: 3), 2)
        XCTAssertEqual(policy.nextDelayNanoseconds(maxAttempts: 3, backoff: .balanced), 5_000_000_000)
        XCTAssertEqual(policy.beginAttempt(maxAttempts: 3), 3)
        XCTAssertNil(policy.nextDelayNanoseconds(maxAttempts: 3, backoff: .balanced))
        XCTAssertNil(policy.beginAttempt(maxAttempts: 3))
    }

    func testResetRestoresRetryBudget() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.beginAttempt(maxAttempts: 1), 1)
        policy.reset()
        XCTAssertEqual(policy.attemptCount, 0)
        XCTAssertEqual(policy.beginAttempt(maxAttempts: 1), 1)
    }

    func testUnknownNetworkAllowsRetryButUnavailableDoesNot() {
        XCTAssertTrue(NetworkAvailability.unknown.allowsRetry)
        XCTAssertTrue(NetworkAvailability.usable.allowsRetry)
        XCTAssertFalse(NetworkAvailability.unavailable.allowsRetry)
    }
}
