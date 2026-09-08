import Combine
import Foundation

@MainActor
final class TerminalSessionRecord: ObservableObject, Identifiable {
    let id: UUID
    let host: Host
    let session: TerminalSessionModel
    let startedAt: ContinuousClock.Instant
    @Published var hasRequestedConnection = false
    @Published var searchQuery = ""

    private var observation: AnyCancellable?

    init(
        id: UUID = UUID(),
        host: Host,
        session: TerminalSessionModel,
        startedAt: ContinuousClock.Instant = .now
    ) {
        self.id = id
        self.host = host
        self.session = session
        self.startedAt = startedAt
        observation = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var shortID: String { id.uuidString.prefix(4).uppercased() }

    var status: String {
        switch session.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .waitingForNetwork: "Waiting for network"
        case .retrying(let attempt, let maxAttempts, _): "Retrying \(attempt)/\(maxAttempts)"
        case .verifyingHost: "Verifying host"
        case .authenticating: "Authenticating"
        case .connected: "Connected"
        case .failed: "Failed"
        }
    }

    var elapsedSeconds: Int {
        let duration = startedAt.duration(to: .now)
        return max(0, Int(duration.components.seconds))
    }
}

@MainActor
final class TerminalSessionRegistry: ObservableObject {
    @Published private(set) var records: [TerminalSessionRecord] = []

    private let sessionFactory: (@MainActor () -> TerminalSessionModel)?
    private let keyProvider: @MainActor (UUID) -> StoredKey?
    private let clipboardWriter: @MainActor (TerminalClipboardWrite) -> Void
    private let networkMonitor: (any NetworkPathMonitoring)?
    private var backgroundGeneration = 0
    private var backgroundDisconnectTask: Task<Void, Never>?
    private var networkAvailability = NetworkAvailability.unknown

    init(
        sessionFactory: (@MainActor () -> TerminalSessionModel)? = nil,
        networkMonitor: (any NetworkPathMonitoring)? = DefaultNetworkPathMonitor(),
        keyProvider: @escaping @MainActor (UUID) -> StoredKey? = { _ in nil },
        clipboardWriter: @escaping @MainActor (TerminalClipboardWrite) -> Void = { _ in }
    ) {
        self.sessionFactory = sessionFactory
        self.networkMonitor = networkMonitor
        self.keyProvider = keyProvider
        self.clipboardWriter = clipboardWriter
        networkMonitor?.start { [weak self] availability in
            Task { @MainActor in self?.setNetworkAvailability(availability) }
        }
    }

    deinit {
        networkMonitor?.cancel()
    }

    @discardableResult
    func create(for host: Host) -> UUID {
        let session = sessionFactory?() ?? TerminalSessionModel(
            keyProvider: keyProvider,
            clipboardWriter: clipboardWriter
        )
        let record = TerminalSessionRecord(host: host, session: session)
        record.session.setNetworkAvailability(networkAvailability)
        records.append(record)
        return record.id
    }

    func record(id: UUID) -> TerminalSessionRecord? {
        records.first { $0.id == id }
    }

    func isIdentityInUse(_ identityID: UUID) -> Bool {
        records.contains {
            $0.host.identityID == identityID && $0.session.ownsConnectionResources
        }
    }

    func close(id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        await record.session.disconnect()
    }

    @discardableResult
    func disconnectForBackground() -> Task<Void, Never> {
        backgroundDisconnectTask?.cancel()
        backgroundGeneration += 1
        let generation = backgroundGeneration
        let activeRecords = records
        let task = Task { [weak self] in
            guard let self else { return }
            var disconnects: [Task<Void, Never>] = []
            for record in activeRecords {
                disconnects.append(Task { @MainActor [weak self, weak record] in
                    guard let self,
                          let record,
                          !Task.isCancelled,
                          generation == backgroundGeneration else { return }
                    await record.session.disconnect()
                })
            }
            for disconnect in disconnects { await disconnect.value }
            if generation == backgroundGeneration { backgroundDisconnectTask = nil }
        }
        backgroundDisconnectTask = task
        return task
    }

    func cancelBackgroundDisconnect() {
        backgroundGeneration += 1
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
    }

    private func setNetworkAvailability(_ availability: NetworkAvailability) {
        guard networkAvailability != availability else { return }
        networkAvailability = availability
        records.forEach { $0.session.setNetworkAvailability(availability) }
    }
}
