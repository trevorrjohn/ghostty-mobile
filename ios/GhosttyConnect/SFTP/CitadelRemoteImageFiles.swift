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
        } catch let SFTPError.errorStatus(status) where Self.directoryFallbackCodes.contains(status.errorCode) {
            return nil
        }
    }

    func ensurePrivateDirectory(_ path: String) async throws {
        do {
            _ = try await sftp.getAttributes(at: path)
        } catch let SFTPError.errorStatus(status) where status.errorCode == .noSuchFile {
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
        } catch let SFTPError.errorStatus(status) where Self.directoryFallbackCodes.contains(status.errorCode) {
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

    private static var privateDirectoryAttributes: SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o700
        return attributes
    }

    private static let directoryFallbackCodes: Set<SFTPStatusCode> = [.permissionDenied, .noSuchFile, .failure]
}
