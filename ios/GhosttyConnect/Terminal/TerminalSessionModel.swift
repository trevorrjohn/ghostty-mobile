import Foundation

@MainActor
final class TerminalSessionModel: ObservableObject {
    @Published private(set) var state = SessionState.disconnected
    @Published private(set) var snapshot: TerminalSnapshot?
    @Published private(set) var pendingHostTrust: HostTrustRequest?

    private let engine: (any TerminalEngine)?
    private let transportFactory: () -> any SSHTransport
    private let keyProvider: @MainActor (UUID) -> StoredKey?
    private var transport: (any SSHTransport)?
    private var outputTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var hostTrustTask: Task<Void, Never>?
    private var cleanupTask: (id: UUID, task: Task<Void, Never>)?
    private var retryTask: Task<Void, Never>?
    private var stableConnectionTask: Task<Void, Never>?
    private var requestedDimensions: TerminalDimensions?
    private var appliedDimensions: TerminalDimensions?
    private var connectionAttemptID: UUID?
    private var activeDestination: String?
    private var lifecycleGeneration = 0
    private var networkAvailability = NetworkAvailability.unknown
    private var reconnectPolicy = ReconnectPolicy()
    private var reconnectPending = false
    private var reconnectHost: Host?
    private var reconnectIdentityID: UUID?
    private(set) var hasConnectedShell = false
    private let retrySleep: @Sendable (UInt64) async throws -> Void
    private let stableConnectionNanoseconds: UInt64

    init(
        transportFactory: @escaping () -> any SSHTransport = { CitadelSSHTransport() },
        engineFactory: () throws -> any TerminalEngine = { try TerminalEngineFactory.make() },
        keyProvider: @escaping @MainActor (UUID) -> StoredKey? = { _ in nil },
        retrySleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        stableConnectionNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.transportFactory = transportFactory
        self.keyProvider = keyProvider
        self.retrySleep = retrySleep
        self.stableConnectionNanoseconds = stableConnectionNanoseconds
        do {
            let engine = try engineFactory()
            let initialSnapshot = try engine.snapshot()
            self.engine = engine
            snapshot = initialSnapshot
        } catch {
            self.engine = nil
            state = .failed(SessionFailure(kind: .configuration, message: error.localizedDescription))
        }
    }

    func connect(to host: Host, secret: String?, key: StoredKey? = nil, isReconnect: Bool = false) async {
        cancelAutomaticRetry(clearCredential: true)
        reconnectPolicy.reset()
        await connectAttempt(to: host, secret: secret, key: key, isReconnect: isReconnect, automaticRetry: false)
    }

    private func connectAttempt(
        to host: Host,
        secret: String?,
        key: StoredKey?,
        isReconnect: Bool,
        automaticRetry: Bool
    ) async {
        guard let engine else { return }
        let generation = lifecycleGeneration
        if let cleanupTask { await cleanupTask.task.value }
        guard lifecycleGeneration == generation, connectionAttemptID == nil, transport == nil else { return }
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
        if automaticRetry {
            state = .retrying(
                attempt: reconnectPolicy.attemptCount,
                maxAttempts: host.retryMaxAttempts,
                delaySeconds: 0
            )
        } else {
            state = .connecting
        }
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
            reconnectPending = false
            if host.retryEnabled,
               host.authenticationType == .sshKey,
               let key,
               !key.requiresPassphrase {
                reconnectHost = host
                reconnectIdentityID = key.id
            } else {
                reconnectHost = nil
                reconnectIdentityID = nil
            }
            scheduleStableConnectionReset(attemptID: attemptID, automaticRetry: automaticRetry)
            scheduleResize()
        } catch {
            await finishAttempt(
                attemptID: attemptID,
                transport: transport,
                failure: SSHFailureClassifier.classify(error, destination: host.destination)
            )
        }
    }

    func setNetworkAvailability(_ availability: NetworkAvailability) {
        guard networkAvailability != availability else { return }
        networkAvailability = availability
        guard reconnectPending, connectionAttemptID == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        if availability.allowsRetry { scheduleAutomaticRetry() }
        else { state = .waitingForNetwork }
    }

    func answerHostTrust(requestID: UUID, accepted: Bool) {
        guard let request = pendingHostTrust, request.id == requestID else { return }
        pendingHostTrust = nil
        state = .connecting
        request.answer(accepted: accepted)
    }

    func send(_ event: TerminalInputEvent) {
        send([event])
    }

    func send(_ events: [TerminalInputEvent]) {
        guard !events.isEmpty else { return }
        guard let engine, let transport, let attemptID = connectionAttemptID, state == .connected else { return }
        let destination = activeDestination ?? "the remote host"
        engine.scrollToBottom()
        snapshot = try? engine.snapshot()
        let data: Data
        do {
            var encoded = Data()
            for event in events { encoded.append(try engine.encode(event: event)) }
            data = encoded
        }
        catch {
            Task {
                await finishAttempt(
                    attemptID: attemptID,
                    transport: transport,
                    failure: SessionFailure(kind: .protocolFailure, message: error.localizedDescription)
                )
            }
            return
        }
        enqueueWrite(data, transport: transport, attemptID: attemptID, destination: destination)
    }

    func isPasteSafe(_ text: String) -> Bool {
        engine?.isPasteSafe(text) ?? false
    }

    func paste(_ text: String) {
        guard let engine, let transport, let attemptID = connectionAttemptID, state == .connected else { return }
        let destination = activeDestination ?? "the remote host"
        engine.scrollToBottom()
        snapshot = try? engine.snapshot()
        let data: Data
        do { data = try engine.encodePaste(text) }
        catch {
            Task {
                await finishAttempt(
                    attemptID: attemptID,
                    transport: transport,
                    failure: SessionFailure(kind: .protocolFailure, message: error.localizedDescription)
                )
            }
            return
        }
        enqueueWrite(data, transport: transport, attemptID: attemptID, destination: destination)
    }

    func scrollViewport(byRows rows: Int) {
        guard let engine else { return }
        engine.scrollViewport(byRows: rows)
        snapshot = try? engine.snapshot()
    }

    func scrollToBottom() {
        guard let engine else { return }
        engine.scrollToBottom()
        snapshot = try? engine.snapshot()
    }

    @discardableResult
    func search(_ query: String, direction: TerminalSearchDirection) -> Bool {
        guard let engine else { return false }
        let found = engine.search(query, direction: direction)
        snapshot = try? engine.snapshot()
        return found
    }

    func selectWord(column: Int, row: Int) {
        guard let engine, engine.selectWord(column: column, row: row) else { return }
        snapshot = try? engine.snapshot()
    }

    func setSelectionEndpoint(start: Bool, column: Int, row: Int) {
        guard let engine, engine.setSelectionEndpoint(start: start, column: column, row: row) else { return }
        snapshot = try? engine.snapshot()
    }

    func contextualSelection(column: Int, row: Int) -> ContextualSelection? {
        guard let engine, let snapshot else { return nil }
        if let link = engine.hyperlink(column: column, row: row),
           ContextualSelection.safeWebURL(link) != nil {
            _ = engine.selectWord(column: column, row: row)
            self.snapshot = try? engine.snapshot()
            return ContextualSelection(kind: .link, value: link)
        }
        if let match = TerminalTokenMatcher.match(snapshot: snapshot, column: column, row: row),
           engine.selectRange(startColumn: match.startColumn, endColumn: match.endColumn, row: row) {
            self.snapshot = try? engine.snapshot()
            let kind: ContextualSelectionKind = match.kind == .link && ContextualSelection.safeWebURL(match.text) == nil
                ? .word
                : match.kind
            return ContextualSelection(kind: kind, value: match.text)
        }
        if engine.selectOutput(column: column, row: row) {
            self.snapshot = try? engine.snapshot()
            return ContextualSelection(kind: .output)
        }
        guard engine.selectWord(column: column, row: row) else { return nil }
        self.snapshot = try? engine.snapshot()
        return ContextualSelection(kind: .word)
    }

    func copySelection() -> String {
        guard let engine else { return "" }
        let text = engine.selectedText()
        engine.clearSelection()
        snapshot = try? engine.snapshot()
        return text
    }

    func clearSelection() {
        guard let engine else { return }
        engine.clearSelection()
        snapshot = try? engine.snapshot()
    }

    private func enqueueWrite(
        _ data: Data,
        transport: any SSHTransport,
        attemptID: UUID,
        destination: String
    ) {
        guard !data.isEmpty else { return }
        let previousWrite = writeTask
        writeTask = Task { [weak self] in
            _ = await previousWrite?.result
            guard let self,
                  !Task.isCancelled,
                  connectionAttemptID == attemptID,
                  self.transport === transport,
                  state == .connected else { return }
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
        guard connectionAttemptID == attemptID, self.transport === transport else { return }
        let generation = lifecycleGeneration
        let effectiveFailure = failure ?? (networkAvailability == .unavailable && hasConnectedShell
            ? SessionFailure(kind: .network, message: "The network connection was lost.")
            : nil)
        let shouldRetry = effectiveFailure?.kind == .network
            && hasConnectedShell
            && reconnectHost != nil
            && reconnectIdentityID != nil
        connectionAttemptID = nil
        self.transport = nil
        activeDestination = nil
        state = effectiveFailure.map(SessionState.failed) ?? .disconnected
        outputTask?.cancel()
        outputTask = nil
        writeTask?.cancel()
        writeTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil
        hostTrustTask?.cancel()
        hostTrustTask = nil
        pendingHostTrust?.answer(accepted: false)
        pendingHostTrust = nil
        await closeTransport(transport)
        guard shouldRetry, lifecycleGeneration == generation else { return }
        if !reconnectPending {
            reconnectPending = true
            engine?.feed(Data("\r\n\u{1b}[33m[Connection lost. Terminal input is paused while reconnecting.]\u{1b}[0m\r\n".utf8))
            if let engine { snapshot = try? engine.snapshot() }
        }
        scheduleAutomaticRetry()
    }

    func disconnect() async {
        lifecycleGeneration += 1
        cancelAutomaticRetry(clearCredential: true)
        reconnectPolicy.reset()
        let transport = self.transport
        connectionAttemptID = nil
        self.transport = nil
        activeDestination = nil
        state = .disconnected
        outputTask?.cancel()
        outputTask = nil
        writeTask?.cancel()
        writeTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        hostTrustTask?.cancel()
        hostTrustTask = nil
        pendingHostTrust?.answer(accepted: false)
        pendingHostTrust = nil
        if let transport {
            await closeTransport(transport)
        } else if let cleanupTask {
            await cleanupTask.task.value
        }
    }

    private func closeTransport(_ transport: any SSHTransport) async {
        let id = UUID()
        let task = Task { await transport.disconnect() }
        cleanupTask = (id, task)
        await task.value
        if cleanupTask?.id == id { cleanupTask = nil }
    }

    private func scheduleAutomaticRetry() {
        guard reconnectPending,
              retryTask == nil,
              connectionAttemptID == nil,
              let host = reconnectHost,
              let identityID = reconnectIdentityID else { return }
        guard networkAvailability.allowsRetry else {
            state = .waitingForNetwork
            return
        }
        guard let delay = reconnectPolicy.nextDelayNanoseconds(
            maxAttempts: host.retryMaxAttempts,
            backoff: host.retryBackoff
        ) else {
            reconnectPending = false
            state = .failed(SessionFailure(
                kind: .network,
                message: "Automatic reconnect stopped after \(reconnectPolicy.attemptCount) attempts."
            ))
            return
        }
        let attempt = reconnectPolicy.attemptCount + 1
        state = .retrying(
            attempt: attempt,
            maxAttempts: host.retryMaxAttempts,
            delaySeconds: Int(delay / 1_000_000_000)
        )
        let generation = lifecycleGeneration
        retryTask = Task { [weak self] in
            do { try await self?.retrySleep(delay) }
            catch { return }
            guard let self,
                  !Task.isCancelled,
                  lifecycleGeneration == generation,
                  reconnectPending,
                  networkAvailability.allowsRetry else { return }
            retryTask = nil
            guard let key = keyProvider(identityID), !key.requiresPassphrase else {
                reconnectPending = false
                reconnectHost = nil
                reconnectIdentityID = nil
                state = .failed(SessionFailure(
                    kind: .configuration,
                    message: "The SSH identity for automatic reconnect is no longer available."
                ))
                return
            }
            guard reconnectPolicy.beginAttempt(maxAttempts: host.retryMaxAttempts) != nil else { return }
            await connectAttempt(to: host, secret: nil, key: key, isReconnect: true, automaticRetry: true)
        }
    }

    private func scheduleStableConnectionReset(attemptID: UUID, automaticRetry: Bool) {
        stableConnectionTask?.cancel()
        guard automaticRetry else {
            reconnectPolicy.reset()
            return
        }
        stableConnectionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: self?.stableConnectionNanoseconds ?? 0) }
            catch { return }
            guard let self, connectionAttemptID == attemptID, state == .connected else { return }
            reconnectPolicy.reset()
            stableConnectionTask = nil
        }
    }

    private func cancelAutomaticRetry(clearCredential: Bool) {
        retryTask?.cancel()
        retryTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil
        reconnectPending = false
        if clearCredential {
            reconnectHost = nil
            reconnectIdentityID = nil
        }
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
