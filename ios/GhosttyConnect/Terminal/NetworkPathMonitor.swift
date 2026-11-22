import Foundation
import Network
import SeanceCore

enum NetworkAvailability: Equatable, Sendable {
    case usable
    case unavailable
    case unknown

    var allowsRetry: Bool { self != .unavailable }
}

protocol NetworkPathMonitoring: AnyObject {
    func start(_ handler: @escaping @Sendable (NetworkAvailability) -> Void)
    func cancel()
}

final class DefaultNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "fail.founder.terminal.network-path")

    func start(_ handler: @escaping @Sendable (NetworkAvailability) -> Void) {
        monitor.pathUpdateHandler = { path in
            handler(path.status == .satisfied ? .usable : .unavailable)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

/// Reconnect policy backed by the shared core (see `core/` and ADR 0012).
/// Backoff and the retry window are identical on iOS and Android.
struct ReconnectPolicy {
    private var state = ScReconnectPolicy()

    init(enabled: Bool = true, maxAttempts: Int = 5, backoff: RetryBackoff = .balanced) {
        configure(enabled: enabled, maxAttempts: maxAttempts, backoff: backoff)
    }

    /// Milliseconds from a monotonic clock.
    static func nowMilliseconds() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    var attemptCount: Int { withUnsafePointer(to: state) { Int(sc_reconnect_attempt_count($0)) } }
    var retryWindowMilliseconds: Int64 { withUnsafePointer(to: state) { sc_reconnect_window_ms($0) } }

    /// Applies host settings while keeping attempts and the retry window.
    /// Out-of-range attempts are clamped to 1...10.
    mutating func configure(enabled: Bool, maxAttempts: Int, backoff: RetryBackoff) {
        let attempts = UInt32(min(10, max(1, maxAttempts)))
        let kind = backoff.coreValue
        if state.max_attempts == 0 {
            _ = sc_reconnect_init(&state, enabled, attempts, kind)
        } else {
            _ = sc_reconnect_configure(&state, enabled, attempts, kind)
        }
    }

    func nextDelayNanoseconds(now: Int64 = ReconnectPolicy.nowMilliseconds()) -> UInt64? {
        var delay: Int64 = 0
        guard withUnsafePointer(to: state, { sc_reconnect_next_delay($0, now, &delay) }) else { return nil }
        return UInt64(max(0, delay)) * 1_000_000
    }

    mutating func beginAttempt(now: Int64 = ReconnectPolicy.nowMilliseconds()) -> Int? {
        sc_reconnect_begin_attempt(&state, now) ? attemptCount : nil
    }

    mutating func reset() {
        sc_reconnect_reset(&state)
    }

    mutating func pause(now: Int64 = ReconnectPolicy.nowMilliseconds()) {
        sc_reconnect_pause(&state, now)
    }

    mutating func resume(now: Int64 = ReconnectPolicy.nowMilliseconds()) {
        sc_reconnect_resume(&state, now)
    }
}

private extension RetryBackoff {
    var coreValue: UInt8 {
        switch self {
        case .fast: UInt8(SC_BACKOFF_FAST)
        case .balanced: UInt8(SC_BACKOFF_BALANCED)
        case .conservative: UInt8(SC_BACKOFF_CONSERVATIVE)
        }
    }
}
