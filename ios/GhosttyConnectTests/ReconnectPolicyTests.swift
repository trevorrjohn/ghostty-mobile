import XCTest
@testable import GhosttyConnect

final class ReconnectPolicyTests: XCTestCase {
    func testBalancedBackoffAndAttemptLimit() {
        var policy = ReconnectPolicy(maxAttempts: 3)
        var now: Int64 = 1_000

        XCTAssertEqual(policy.nextDelayNanoseconds(now: now), 0)
        XCTAssertEqual(policy.beginAttempt(now: now), 1)
        XCTAssertEqual(policy.nextDelayNanoseconds(now: now), 2_000_000_000)
        now += 2_000
        XCTAssertEqual(policy.beginAttempt(now: now), 2)
        XCTAssertEqual(policy.nextDelayNanoseconds(now: now), 5_000_000_000)
        now += 5_000
        XCTAssertEqual(policy.beginAttempt(now: now), 3)
        XCTAssertNil(policy.nextDelayNanoseconds(now: now))
        XCTAssertNil(policy.beginAttempt(now: now))
    }

    func testResetRestoresRetryBudget() {
        var policy = ReconnectPolicy(maxAttempts: 1)
        XCTAssertEqual(policy.beginAttempt(now: 0), 1)
        policy.reset()
        XCTAssertEqual(policy.attemptCount, 0)
        XCTAssertEqual(policy.beginAttempt(now: 0), 1)
    }

    func testRetryWindowClosesWithoutSuccessfulConnection() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.beginAttempt(now: 1_000), 1)
        XCTAssertNil(policy.nextDelayNanoseconds(now: 1_000 + policy.retryWindowMilliseconds + 1))
    }

    func testPausedTimeDoesNotCountAgainstRetryWindow() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.beginAttempt(now: 0), 1)
        policy.pause(now: 10_000)
        let late = 10_000 + policy.retryWindowMilliseconds * 3
        XCTAssertNotNil(policy.nextDelayNanoseconds(now: late))
        policy.resume(now: late)
        XCTAssertNotNil(policy.nextDelayNanoseconds(now: late + 1_000))
        XCTAssertNil(policy.nextDelayNanoseconds(now: late + policy.retryWindowMilliseconds + 1))
    }

    func testConfigureKeepsProgressAndDisabledNeverRetries() {
        var policy = ReconnectPolicy(maxAttempts: 5)
        XCTAssertEqual(policy.beginAttempt(now: 0), 1)
        policy.configure(enabled: true, maxAttempts: 2, backoff: .fast)
        XCTAssertEqual(policy.attemptCount, 1)
        XCTAssertEqual(policy.nextDelayNanoseconds(now: 0), 1_000_000_000)
        policy.configure(enabled: false, maxAttempts: 2, backoff: .fast)
        XCTAssertNil(policy.nextDelayNanoseconds(now: 0))
    }

    func testUnknownNetworkAllowsRetryButUnavailableDoesNot() {
        XCTAssertTrue(NetworkAvailability.unknown.allowsRetry)
        XCTAssertTrue(NetworkAvailability.usable.allowsRetry)
        XCTAssertFalse(NetworkAvailability.unavailable.allowsRetry)
    }
}
