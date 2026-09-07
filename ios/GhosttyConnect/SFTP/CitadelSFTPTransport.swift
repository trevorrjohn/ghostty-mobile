import Citadel
import Foundation
import NIOCore

protocol SFTPTransport: AnyObject {
    var hostTrustRequests: AsyncStream<HostTrustRequest> { get }
    func connect(to host: Host, credential: SSHCredential) async throws
    func list(path: String) async throws -> SFTPDirectory
    func createDirectory(path: String) async throws
    func rename(from: String, to: String) async throws
    func remove(path: String, directory: Bool) async throws
    func download(path: String, to localURL: URL, maxBytes: UInt64, progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws
    func upload(from localURL: URL, to path: String, progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws
    func disconnect() async
}

actor CitadelSFTPTransport: SFTPTransport {
    nonisolated let hostTrustRequests: AsyncStream<HostTrustRequest>
    private let hostTrustContinuation: AsyncStream<HostTrustRequest>.Continuation
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var validator: KeychainHostKeyValidator?
    private var started = false

    init() {
        var continuation: AsyncStream<HostTrustRequest>.Continuation!
        hostTrustRequests = AsyncStream { continuation = $0 }
        hostTrustContinuation = continuation
    }

    func connect(to host: Host, credential: SSHCredential) async throws {
        guard !started else { throw SSHTransportError.alreadyConnected }
        started = true
        let authentication = try CitadelAuthenticationFactory.make(username: host.username, credential: credential)
        let validator = KeychainHostKeyValidator(host: host.hostname, port: host.port) { [hostTrustContinuation] request in
            if case .terminated = hostTrustContinuation.yield(request) { request.answer(accepted: false) }
        }
        self.validator = validator
        let settings = SSHClientSettings(
            host: host.hostname,
            port: host.port,
            authenticationMethod: { authentication },
            hostKeyValidator: .custom(validator)
        )
        var connectedClient: SSHClient?
        do {
            let client = try await SSHClient.connect(to: settings)
            connectedClient = client
            guard !Task.isCancelled else {
                try? await client.close()
                throw CancellationError()
            }
            let sftp = try await client.openSFTP()
            self.client = client
            self.sftp = sftp
        } catch {
            validator.cancelPendingRequest()
            self.validator = nil
            try? await connectedClient?.close()
            throw CitadelSSHTransport.connectionError(error, host: host)
        }
    }

    func list(path: String) async throws -> SFTPDirectory {
        let sftp = try connectedSFTP()
        let canonical = try await sftp.getRealPath(atPath: path)
        let entries = try await sftp.listDirectory(atPath: canonical)
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .prefix(10_000)
            .map(Self.entry)
        return SFTPDirectory(path: canonical, entries: Array(entries))
    }

    func createDirectory(path: String) async throws {
        try await connectedSFTP().createDirectory(atPath: path)
    }

    func rename(from: String, to: String) async throws {
        try await connectedSFTP().rename(at: from, to: to)
    }

    func remove(path: String, directory: Bool) async throws {
        if directory { try await connectedSFTP().rmdir(at: path) }
        else { try await connectedSFTP().remove(at: path) }
    }

    func download(
        path: String,
        to localURL: URL,
        maxBytes: UInt64,
        progress: @escaping @Sendable (UInt64, UInt64?) -> Void
    ) async throws {
        let sftp = try connectedSFTP()
        let total = try await sftp.getAttributes(at: path).size
        if let total, total > maxBytes { throw SFTPBrowserError.tooLarge }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let local = try FileHandle(forWritingTo: localURL)
        let remote = try await sftp.openFile(filePath: path, flags: .read)
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                var buffer = try await remote.read(from: offset, length: 64 * 1024)
                guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { break }
                try local.write(contentsOf: Data(bytes))
                offset += UInt64(bytes.count)
                if offset > maxBytes { throw SFTPBrowserError.tooLarge }
                progress(offset, total)
            }
            try local.close()
            try await remote.close()
        } catch {
            try? local.close()
            try? await remote.close()
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    func upload(
        from localURL: URL,
        to path: String,
        progress: @escaping @Sendable (UInt64, UInt64?) -> Void
    ) async throws {
        let sftp = try connectedSFTP()
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let total = values.fileSize.map(UInt64.init)
        let temporaryPath = "\(path).seance-shell-upload-\(UUID().uuidString)"
        let local = try FileHandle(forReadingFrom: localURL)
        let remote = try await sftp.openFile(filePath: temporaryPath, flags: [.write, .create, .forceCreate])
        do {
            var offset: UInt64 = 0
            while let data = try local.read(upToCount: 64 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try await remote.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                progress(offset, total)
            }
            try local.close()
            try await remote.close()
            try Task.checkCancellation()
            try await sftp.rename(at: temporaryPath, to: path)
        } catch {
            try? local.close()
            try? await remote.close()
            try? await sftp.remove(at: temporaryPath)
            throw error
        }
    }

    func disconnect() async {
        validator?.cancelPendingRequest()
        validator = nil
        let sftp = self.sftp
        let client = self.client
        self.sftp = nil
        self.client = nil
        try? await sftp?.close()
        try? await client?.close()
        hostTrustContinuation.finish()
    }

    private func connectedSFTP() throws -> SFTPClient {
        guard let sftp, sftp.isActive else { throw SFTPBrowserError.notConnected }
        return sftp
    }

    private static func entry(_ component: SFTPPathComponent) -> SFTPEntry {
        let permissions = component.attributes.permissions
        let kind = sftpEntryKind(name: component.filename, permissions: permissions)
        return SFTPEntry(
            name: component.filename,
            kind: kind,
            size: component.attributes.size,
            modifiedAt: component.attributes.accessModificationTime?.modificationTime,
            accessedAt: component.attributes.accessModificationTime?.accessTime,
            permissions: permissions
        )
    }
}
