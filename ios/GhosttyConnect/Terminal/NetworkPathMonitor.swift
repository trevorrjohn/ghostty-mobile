import Foundation
import Network

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

struct ReconnectPolicy {
    private(set) var attemptCount = 0

    func nextDelayNanoseconds(maxAttempts: Int, backoff: RetryBackoff) -> UInt64? {
        guard attemptCount < min(10, max(1, maxAttempts)) else { return nil }
        return backoff.delaysNanoseconds[attemptCount]
    }

    mutating func beginAttempt(maxAttempts: Int) -> Int? {
        guard attemptCount < min(10, max(1, maxAttempts)) else { return nil }
        attemptCount += 1
        return attemptCount
    }

    mutating func reset() {
        attemptCount = 0
    }
}

private extension RetryBackoff {
    var delaysNanoseconds: [UInt64] {
        switch self {
        case .fast:
            [0, 1, 2, 3, 5, 8, 13, 20, 30, 30].map { $0 * 1_000_000_000 }
        case .balanced:
            [0, 2, 5, 10, 20, 30, 30, 30, 30, 30].map { $0 * 1_000_000_000 }
        case .conservative:
            [0, 5, 15, 30, 60, 60, 60, 60, 60, 60].map { $0 * 1_000_000_000 }
        }
    }
}
