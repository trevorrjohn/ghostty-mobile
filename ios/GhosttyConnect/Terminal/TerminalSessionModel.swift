import Foundation

@MainActor
final class TerminalSessionModel: ObservableObject {
    @Published private(set) var state = SessionState.disconnected
    @Published private(set) var snapshot: TerminalSnapshot?

    private let engine: (any TerminalEngine)?
    private let transport: any SSHTransport
    private var outputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var requestedDimensions: TerminalDimensions?
    private var appliedDimensions: TerminalDimensions?

    init(transport: any SSHTransport = CitadelSSHTransport()) {
        self.transport = transport
        do {
            let engine = try TerminalEngineFactory.make()
            let initialSnapshot = try engine.snapshot()
            self.engine = engine
            snapshot = initialSnapshot
        } catch {
            self.engine = nil
            state = .failed(error.localizedDescription)
        }
    }

    func connect(to host: Host, secret: String?, key: StoredKey? = nil) async {
        guard let engine else { return }
        let credential: SSHCredential
        switch host.authenticationType {
        case .password:
            credential = .password(secret ?? "")
        case .sshKey:
            guard let key else {
                state = .failed("The selected SSH key is unavailable.")
                return
            }
            credential = .privateKey(key.data, passphrase: secret)
        }
        state = .connecting
        outputTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await data in transport.output {
                    engine.feed(data)
                    snapshot = try engine.snapshot()
                }
                if state == .connected { state = .disconnected }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }

        do {
            try await transport.connect(to: host, credential: credential)
            state = .connected
            scheduleResize()
        } catch {
            outputTask?.cancel()
            state = .failed(error.localizedDescription)
        }
    }

    func send(_ text: String) {
        guard let engine, state == .connected else { return }
        let data = engine.encode(text: text)
        Task {
            do { try await transport.write(data) }
            catch { state = .failed(error.localizedDescription) }
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
                state = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() async {
        outputTask?.cancel()
        outputTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        await transport.disconnect()
        if state == .connected || state == .connecting { state = .disconnected }
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
