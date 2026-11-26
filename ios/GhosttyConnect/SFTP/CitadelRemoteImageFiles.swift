import Citadel
import Foundation
import NIOCore

/// Image-upload operations over an SFTP channel opened on a terminal session's SSH connection.
/// Closing this closes only the channel; the session keeps owning the transport.
final class CitadelRemoteImageFiles: RemoteImageFiles {
    private let sftp: SFTPClient

    init(sftp: SFTPClient) {
        self.sftp = sftp
    }

    func homeDirectory() async throws -> String {
        try await sftp.getRealPath(atPath: ".")
    }

    func resolveDirectory(_ path: String) async throws -> String? {
        do {
            let canonical = try await sftp.getRealPath(atPath: path)
            let permissions = try await sftp.getAttributes(at: canonical).permissions
            guard let permissions, permissions & 0o170000 == 0o040000 else { return nil }
            return canonical
        } catch where Self.status(error).map({ Self.directoryFallbackCodes.contains($0.errorCode) }) == true {
            return nil
        }
    }

    func ensurePrivateDirectory(_ path: String) async throws {
        do {
            _ = try await sftp.getAttributes(at: path)
        } catch where Self.status(error)?.errorCode == .noSuchFile {
            try await sftp.createDirectory(atPath: path, attributes: Self.privateDirectoryAttributes)
            // The server's umask can only remove bits, but set the mode explicitly so 0700 never depends on it.
            try await sftp.setAttributes(at: path, to: Self.privateDirectoryAttributes)
        }
    }

    func writeNewFile(
        in directory: String,
        name: String,
        from source: URL,
        progress: @escaping @Sendable (UInt64, UInt64?) -> Void
    ) async throws {
        let finalPath = remoteChildPath(parent: directory, name: name)
        let temporaryPath = remoteChildPath(parent: directory, name: ".seance-shell-upload-\(UUID().uuidString)")
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init)
        let remote: SFTPFile
        do {
            remote = try await sftp.openFile(filePath: temporaryPath, flags: [.write, .create, .forceCreate])
        } catch where Self.status(error).map({ Self.directoryFallbackCodes.contains($0.errorCode) }) == true {
            throw ImageUploadError.destinationUnusable
        }
        let local: FileHandle
        do { local = try FileHandle(forReadingFrom: source) }
        catch {
            try? await remote.close()
            try? await sftp.remove(at: temporaryPath)
            throw error
        }
        do {
            var offset: UInt64 = 0
            while let data = try local.read(upToCount: 64 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                try await remote.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                progress(offset, total)
            }
            try local.close()
            try await remote.close()
            try Task.checkCancellation()
            try await sftp.rename(at: temporaryPath, to: finalPath)
        } catch {
            try? local.close()
            try? await remote.close()
            try? await sftp.remove(at: temporaryPath)
            throw error
        }
    }

    func close() async {
        try? await sftp.close()
    }

    /// Citadel throws a status either bare or wrapped in `SFTPError.errorStatus`, depending on the call.
    static func status(_ error: Error) -> SFTPMessage.Status? {
        if let status = error as? SFTPMessage.Status { return status }
        if case SFTPError.errorStatus(let status) = error { return status }
        return nil
    }

    /// A readable failure for the upload chip, including the server's own reason when it gave one.
    static func failureDescription(_ error: Error) -> String {
        guard let status = status(error) else {
            if let error = error as? LocalizedError, let text = error.errorDescription { return text }
            return "The upload failed (\(type(of: error)))."
        }
        let reason: String
        switch status.errorCode {
        case .permissionDenied: reason = "permission denied"
        case .noSuchFile: reason = "path not found"
        case .failure: reason = "the server reported a failure"
        case .unsupportedOperation: reason = "the server does not support this SFTP operation"
        case .connectionLost, .noConnection: reason = "the connection was lost"
        default: reason = "SFTP status \(status.errorCode.rawValue)"
        }
        let detail = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "The server refused the upload: \(reason)." : "The server refused the upload: \(reason) (\(detail))."
    }

    private static var privateDirectoryAttributes: SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o700
        return attributes
    }

    private static let directoryFallbackCodes: Set<SFTPStatusCode> = [.permissionDenied, .noSuchFile, .failure]
}
