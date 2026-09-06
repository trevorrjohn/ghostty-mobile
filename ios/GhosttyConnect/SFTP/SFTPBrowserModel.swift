import Foundation

@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published private(set) var status = SFTPBrowserStatus.disconnected
    @Published private(set) var path = ""
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var transfer: SFTPTransfer?
    @Published private(set) var pendingHostTrust: HostTrustRequest?
    @Published var addressText = ""
    @Published var sort = SFTPSort.nameAscending
    @Published var showHidden = false
    @Published var errorMessage: String?
    @Published private(set) var favorites: [String] = []
    @Published private(set) var recentPaths: [String] = []

    private let transportFactory: () -> any SFTPTransport
    private var transport: (any SFTPTransport)?
    private var hostTrustTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var cancelActiveTransfer: (() -> Void)?
    private var awaitActiveTransfer: (() async -> Void)?
    private var transferID: UUID?
    private let locationStore = SFTPLocationStore()
    private var hostID: UUID?
    private var pathHistory: [String] = []

    init(transportFactory: @escaping () -> any SFTPTransport = { CitadelSFTPTransport() }) {
        self.transportFactory = transportFactory
    }

    var query: String {
        let value = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == path || isPathInput(value) ? "" : value
    }

    var visibleEntries: [SFTPEntry] {
        filteredSFTPEntries(entries, query: query, sort: sort, showHidden: showHidden)
    }

    var connected: Bool {
        if case .ready = status { return true }
        return false
    }

    var canNavigateBack: Bool { !pathHistory.isEmpty }

    func connect(to host: Host, secret: String?, key: StoredKey?) async {
        guard transport == nil else { return }
        let credential: SSHCredential
        switch host.authenticationType {
        case .password:
            credential = .password(secret ?? "")
        case .sshKey:
            guard let key else {
                status = .failed("The selected SSH key is unavailable.")
                return
            }
            credential = .privateKey(key.data, passphrase: secret)
        }
        let id = UUID()
        hostID = host.id
        pathHistory = []
        if let locations = try? locationStore.load(hostID: host.id) {
            favorites = locations.favorites
            recentPaths = locations.recent
        }
        let transport = transportFactory()
        connectionID = id
        self.transport = transport
        status = .connecting
        errorMessage = nil
        hostTrustTask = Task { [weak self] in
            guard let self else { return }
            for await request in transport.hostTrustRequests {
                guard connectionID == id else {
                    request.answer(accepted: false)
                    return
                }
                pendingHostTrust = request
                status = .verifyingHost
            }
        }
        do {
            try await transport.connect(to: host, credential: credential)
            guard connectionID == id else {
                await transport.disconnect()
                return
            }
            try await load(path: ".")
        } catch {
            await failConnection(error, host: host, id: id, transport: transport)
        }
    }

    func answerHostTrust(requestID: UUID, accepted: Bool) {
        guard let request = pendingHostTrust, request.id == requestID else { return }
        pendingHostTrust = nil
        status = .connecting
        request.answer(accepted: accepted)
    }

    func updateAddress(_ value: String) {
        addressText = value
    }

    func submitAddress() async {
        let value = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPathInput(value) else { return }
        await navigate(to: value)
    }

    func navigate(to requestedPath: String) async {
        guard transport != nil else { return }
        let previousPath = path
        do {
            try await load(path: requestedPath)
            if !previousPath.isEmpty, previousPath != path {
                pathHistory.append(previousPath)
                pathHistory = Array(pathHistory.suffix(100))
            }
        }
        catch { operationFailed(error) }
    }

    func navigateBack() async {
        guard let previousPath = pathHistory.popLast() else { return }
        do { try await load(path: previousPath) }
        catch {
            pathHistory.append(previousPath)
            operationFailed(error)
        }
    }

    func navigateUp() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await navigate(to: parent.isEmpty ? "/" : parent)
    }

    func open(_ entry: SFTPEntry) async {
        guard entry.kind == .directory else { return }
        await navigate(to: remoteChildPath(parent: path, name: entry.name))
    }

    func refresh() async {
        guard !path.isEmpty else { return }
        await navigate(to: path)
    }

    func toggleCurrentFavorite() {
        guard !path.isEmpty else { return }
        if favorites.contains(path) { favorites.removeAll { $0 == path } }
        else { favorites.append(path); favorites.sort() }
        persistLocations()
    }

    func clearRecentPaths() {
        recentPaths = []
        persistLocations()
    }

    func createDirectory(named name: String) async {
        await mutate(name: name) { transport, remotePath in
            try await transport.createDirectory(path: remotePath)
        }
    }

    func rename(_ entry: SFTPEntry, to name: String) async {
        guard validRemoteChildName(name), !entries.contains(where: { $0.name == name }) else {
            errorMessage = SFTPBrowserError.invalidName.localizedDescription
            return
        }
        await performMutation {
            guard let transport else { throw SFTPBrowserError.notConnected }
            try await transport.rename(
                from: remoteChildPath(parent: path, name: entry.name),
                to: remoteChildPath(parent: path, name: name)
            )
        }
    }

    func delete(_ entry: SFTPEntry) async {
        await performMutation {
            guard let transport else { throw SFTPBrowserError.notConnected }
            try await transport.remove(
                path: remoteChildPath(parent: path, name: entry.name),
                directory: entry.kind == .directory
            )
        }
    }

    func download(_ entry: SFTPEntry, maxBytes: UInt64) async throws -> URL {
        guard entry.kind == .file, let transport else { throw SFTPBrowserError.unsupportedEntry }
        guard transfer == nil else { throw SFTPBrowserError.notConnected }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL = directory.appendingPathComponent("\(UUID().uuidString)-\(entry.name)")
        let transferID = UUID()
        self.transferID = transferID
        transfer = SFTPTransfer(direction: .download, name: entry.name, completed: 0, total: entry.size)
        let task = Task<URL, Error> {
            try await transport.download(
                path: remoteChildPath(parent: path, name: entry.name),
                to: localURL,
                maxBytes: maxBytes
            ) { [weak self] completed, total in
                Task { @MainActor in
                    guard self?.transferID == transferID else { return }
                    self?.transfer = SFTPTransfer(direction: .download, name: entry.name, completed: completed, total: total)
                }
            }
            return localURL
        }
        cancelActiveTransfer = { task.cancel() }
        awaitActiveTransfer = { _ = await task.result }
        do {
            let result = try await task.value
            transfer = nil
            cancelActiveTransfer = nil
            awaitActiveTransfer = nil
            self.transferID = nil
            return result
        } catch {
            transfer = nil
            cancelActiveTransfer = nil
            awaitActiveTransfer = nil
            self.transferID = nil
            operationFailed(error)
            throw error
        }
    }

    func upload(from localURL: URL, as name: String) async {
        guard validRemoteChildName(name) else {
            errorMessage = SFTPBrowserError.invalidName.localizedDescription
            return
        }
        guard !entries.contains(where: { $0.name == name }) else {
            errorMessage = SFTPBrowserError.destinationExists.localizedDescription
            return
        }
        guard let transport, transfer == nil else { return }
        let accessing = localURL.startAccessingSecurityScopedResource()
        defer { if accessing { localURL.stopAccessingSecurityScopedResource() } }
        let transferID = UUID()
        self.transferID = transferID
        transfer = SFTPTransfer(direction: .upload, name: name, completed: 0, total: nil)
        let task = Task<Void, Error> {
            try await transport.upload(
                from: localURL,
                to: remoteChildPath(parent: path, name: name)
            ) { [weak self] completed, total in
                Task { @MainActor in
                    guard self?.transferID == transferID else { return }
                    self?.transfer = SFTPTransfer(direction: .upload, name: name, completed: completed, total: total)
                }
            }
        }
        cancelActiveTransfer = { task.cancel() }
        awaitActiveTransfer = { _ = await task.result }
        do {
            try await task.value
            cancelActiveTransfer = nil
            awaitActiveTransfer = nil
            self.transferID = nil
            transfer = nil
            await refresh()
        } catch {
            cancelActiveTransfer = nil
            awaitActiveTransfer = nil
            self.transferID = nil
            transfer = nil
            operationFailed(error)
        }
    }

    func cancelTransfer() async {
        cancelActiveTransfer?()
        let wait = awaitActiveTransfer
        let transport = self.transport
        self.transport = nil
        connectionID = nil
        pathHistory = []
        status = .disconnected
        await transport?.disconnect()
        await wait?()
        cancelActiveTransfer = nil
        awaitActiveTransfer = nil
        transferID = nil
        transfer = nil
        status = .failed("Transfer canceled. Reconnect to continue browsing.")
    }

    func disconnect() async {
        connectionID = nil
        cancelActiveTransfer?()
        let wait = awaitActiveTransfer
        let transport = self.transport
        self.transport = nil
        connectionID = nil
        pathHistory = []
        status = .disconnected
        await transport?.disconnect()
        await wait?()
        cancelActiveTransfer = nil
        awaitActiveTransfer = nil
        transferID = nil
        transfer = nil
        hostTrustTask?.cancel()
        hostTrustTask = nil
        pendingHostTrust?.answer(accepted: false)
        pendingHostTrust = nil
    }

    private func load(path requestedPath: String) async throws {
        guard let transport else { throw SFTPBrowserError.notConnected }
        status = .loading
        let directory = try await transport.list(path: requestedPath)
        path = directory.path
        entries = directory.entries
        addressText = directory.path
        recentPaths.removeAll { $0 == directory.path }
        recentPaths.insert(directory.path, at: 0)
        recentPaths = Array(recentPaths.prefix(10))
        persistLocations()
        status = .ready
        errorMessage = nil
    }

    private func mutate(
        name: String,
        operation: (any SFTPTransport, String) async throws -> Void
    ) async {
        guard validRemoteChildName(name) else {
            errorMessage = SFTPBrowserError.invalidName.localizedDescription
            return
        }
        guard !entries.contains(where: { $0.name == name }) else {
            errorMessage = SFTPBrowserError.destinationExists.localizedDescription
            return
        }
        await performMutation {
            guard let transport else { throw SFTPBrowserError.notConnected }
            try await operation(transport, remoteChildPath(parent: path, name: name))
        }
    }

    private func performMutation(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            await refresh()
        } catch { operationFailed(error) }
    }

    private func operationFailed(_ error: Error) {
        errorMessage = error.localizedDescription
        status = transport == nil ? .disconnected : .ready
    }

    private func persistLocations() {
        guard let hostID else { return }
        do { try locationStore.save(SFTPLocations(favorites: favorites, recent: recentPaths), hostID: hostID) }
        catch { errorMessage = "Saved locations could not be protected." }
    }

    private func isPathInput(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") ||
            value == "." || value == ".." || value.contains("/")
    }

    private func failConnection(
        _ error: Error,
        host: Host,
        id: UUID,
        transport: any SFTPTransport
    ) async {
        guard connectionID == id else { return }
        connectionID = nil
        self.transport = nil
        hostTrustTask?.cancel()
        hostTrustTask = nil
        pendingHostTrust?.answer(accepted: false)
        pendingHostTrust = nil
        let failure = SSHFailureClassifier.classify(error, destination: host.destination)
        status = .failed(failure.message)
        await transport.disconnect()
    }
}
