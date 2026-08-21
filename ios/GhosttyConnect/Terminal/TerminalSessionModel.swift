import Foundation

@MainActor
final class TerminalSessionModel: ObservableObject {
    @Published private(set) var state = SessionState.disconnected
    @Published private(set) var snapshot: TerminalSnapshot?
    @Published private(set) var pendingHostTrust: HostTrustRequest?

    private let engine: (any TerminalEngine)?
    private let transportFactory: () -> any SSHTransport
    private var transport: (any SSHTransport)?
    private var outputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var hostTrustTask: Task<Void, Never>?
    private var requestedDimensions: TerminalDimensions?
    private var appliedDimensions: TerminalDimensions?
    private var connectionAttemptID: UUID?
    private var activeDestination: String?
    private(set) var hasConnectedShell = false

    init(transportFactory: @escaping () -> any SSHTransport = { CitadelSSHTransport() }) {
        self.transportFactory = transportFactory
        do {
            let engine = try TerminalEngineFactory.make()
            let initialSnapshot = try engine.snapshot()
            self.engine = engine
            snapshot = initialSnapshot
        } catch {
            self.engine = nil
            state = .failed(SessionFailure(kind: .configuration, message: error.localizedDescription))
        }
    }

    func connect(to host: Host, secret: String?, key: StoredKey? = nil, isReconnect: Bool = false) async {
        guard let engine, connectionAttemptID == nil, transport == nil else { return }
        let credential: SSHCredential
        switch host.authenticationType {
        case .password:
            credential = .password(secret ?? "")
        case .sshKey:
            guard let key else {
                state = .failed(SessionFailure(
                    kind: .configuration,
                    message: "The selected SSH key is unavailable."
                ))
                return
            }
            credential = .privateKey(key.data, passphrase: secret)
        }
        let attemptID = UUID()
        let transport = transportFactory()
        connectionAttemptID = attemptID
        self.transport = transport
        activeDestination = host.destination
        appliedDimensions = nil
        state = .connecting
        hostTrustTask = Task { [weak self] in
            guard let self else { return }
            for await request in transport.hostTrustRequests {
                guard connectionAttemptID == attemptID else {
                    request.answer(accepted: false)
                    return
                }
                pendingHostTrust = request
                state = .verifyingHost
            }
        }
        outputTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await data in transport.output {
                    guard connectionAttemptID == attemptID else { return }
                    engine.feed(data)
                    snapshot = try engine.snapshot()
                }
                await finishAttempt(attemptID: attemptID, transport: transport, failure: nil)
            } catch {
                await finishAttempt(
                    attemptID: attemptID,
                    transport: transport,
                    failure: SSHFailureClassifier.classify(error, destination: host.destination)
                )
            }
        }

        do {
            try await transport.connect(to: host, credential: credential)
            guard connectionAttemptID == attemptID else {
                await transport.disconnect()
                return
            }
            if isReconnect && hasConnectedShell {
                engine.feed(Data("\r\n\u{1b}[2m[Connected with a new SSH shell]\u{1b}[0m\r\n".utf8))
                snapshot = try engine.snapshot()
            }
            hasConnectedShell = true
            state = .connected
            scheduleResize()
        } catch {
            await finishAttempt(
                attemptID: attemptID,
                transport: transport,
                failure: SSHFailureClassifier.classify(error, destination: host.destination)
            )
        }
    }

    func answerHostTrust(requestID: UUID, accepted: Bool) {
        guard let request = pendingHostTrust, request.id == requestID else { return }
        pendingHostTrust = nil
        state = .connecting
        request.answer(accepted: accepted)
    }

    func send(_ text: String) {
        guard let engine, let transport, let attemptID = connectionAttemptID, state == .connected else { return }
        let destination = activeDestination ?? "the remote host"
        let data = engine.encode(text: text)
        Task {
            do { try await transport.write(data) }
            catch {
                await finishAttempt(
                    attemptID: attemptID,
                    transport: transport,
                    failure: SSHFailureClassifier.classify(error, destination: destination)
                )
            }
        }
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        requestedDimensions = TerminalDimensions(
            columns: max(1, columns),
            rows: max(1, rows),
            pixelWidth: max(0, pixelWidth),
            pixelHeight: max(0, pixelHeight)
        )
        scheduleResize()
    }

    private func scheduleResize() {
        resizeTask?.cancel()
        guard state == .connected,
              let engine,
              let transport,
              let attemptID = connectionAttemptID,
              let destination = activeDestination,
              let dimensions = requestedDimensions,
              dimensions != appliedDimensions else { return }
        resizeTask = Task {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                try Task.checkCancellation()
                engine.resize(columns: dimensions.columns, rows: dimensions.rows)
                try await transport.resize(
                    columns: dimensions.columns,
                    rows: dimensions.rows,
                    pixelWidth: dimensions.pixelWidth,
                    pixelHeight: dimensions.pixelHeight
                )
                appliedDimensions = dimensions
                snapshot = try engine.snapshot()
            } catch is CancellationError {
                return
            } catch {
                await finishAttempt(
                    attemptID: attemptID,
                    transport: transport,
                    failure: SSHFailureClassifier.classify(error, destination: destination)
                )
            }
        }
    }

    private func finishAttempt(
        attemptID: UUID,
        transport: any SSHTransport,
        failure: SessionFailure?
    ) async {
        guard connectionAttemptID == attemptID else { return }
        connectionAttemptID = nil
        outputTask?.cancel()
        outputTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        hostTrustTask?.cancel()
        hostTrustTask = nil
        pendingHostTrust?.answer(accepted: false)
        pendingHostTrust = nil
        await transport.disconnect()
        guard connectionAttemptID == nil, self.transport === transport else { return }
        self.transport = nil
        activeDestination = nil
        state = failure.map(SessionState.failed) ?? .disconnected
    }

    func disconnect() async {
        let transport = self.transport
        connectionAttemptID = nil
        outputTask?.cancel()
        outputTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        hostTrustTask?.cancel()
        hostTrustTask = nil
        pendingHostTrust?.answer(accepted: false)
        pendingHostTrust = nil
        await transport?.disconnect()
        guard connectionAttemptID == nil else { return }
        self.transport = nil
        activeDestination = nil
        state = .disconnected
    }
}

struct TerminalDimensions: Equatable {
    let columns: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int

    static func fit(size: CGSize, fontSize: Double, displayScale: CGFloat) -> TerminalDimensions {
        let columns = max(1, Int(size.width / TerminalGridView.cellWidth(fontSize: fontSize)))
        let rows = max(1, Int(size.height / TerminalGridView.cellHeight(fontSize: fontSize)))
        return TerminalDimensions(
            columns: columns,
            rows: rows,
            pixelWidth: max(0, Int(size.width * displayScale)),
            pixelHeight: max(0, Int(size.height * displayScale))
        )
    }
}
