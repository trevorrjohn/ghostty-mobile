import Foundation

/// Where an uploaded image goes. `ask` shows a destination sheet; the others upload immediately.
enum ImageUploadDestinationMode: String, Codable, CaseIterable, Identifiable {
    case ask
    case currentDirectory
    case uploadsFolder

    var id: Self { self }

    var label: String {
        switch self {
        case .ask: "Ask every time"
        case .currentDirectory: "Current directory"
        case .uploadsFolder: "Uploads folder"
        }
    }
}

/// Remote folder, relative to the account's home directory, used when the terminal's directory is unknown or unusable.
let imageUploadsFolder = ".seance/uploads"

/// Where an image upload finished and whether it had to leave the requested directory.
struct ImageUploadResult: Equatable {
    let remotePath: String
    let fellBackToUploadsFolder: Bool
}

enum ImageUploadError: LocalizedError, Equatable {
    case notConnected
    case tooLarge
    case unsupportedImage
    case destinationUnusable
    case noImages

    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect to the host before uploading an image."
        case .tooLarge: "The image is larger than the 25 MiB upload limit."
        case .unsupportedImage: "The image could not be read or converted."
        case .destinationUnusable: "The remote folder could not be written."
        case .noImages: "No images were found to upload."
        }
    }
}

let maximumImageUploadBytes = 25 * 1_024 * 1_024

private let imageNameAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

/// `screenshot-20261125-143005-ab12.png`: unique enough that an upload never needs a conflict prompt.
func imageUploadFileName(
    now: Date,
    fileExtension: String,
    timeZone: TimeZone = .current,
    using generator: inout some RandomNumberGenerator
) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let suffix = String((0..<4).map { _ in imageNameAlphabet.randomElement(using: &generator)! })
    let safe = String(fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    return "screenshot-\(formatter.string(from: now))-\(suffix).\(safe.isEmpty ? "png" : safe)"
}

func imageUploadFileName(now: Date, fileExtension: String, timeZone: TimeZone = .current) -> String {
    var generator = SystemRandomNumberGenerator()
    return imageUploadFileName(now: now, fileExtension: fileExtension, timeZone: timeZone, using: &generator)
}

private let shellSafeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")

/// Quotes only when a POSIX shell would otherwise split or expand the path.
func shellQuotePath(_ path: String) -> String {
    if !path.isEmpty, path.allSatisfy({ shellSafeCharacters.contains($0) }) { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Text pasted into the terminal for finished uploads. Never ends in a newline, so nothing is executed.
func pastedUploadPaths(_ paths: [String]) -> String {
    paths.map(shellQuotePath).joined(separator: " ")
}

/// Whether a prompt is needed. With no known terminal directory there is only one sensible answer,
/// so `ask` and `currentDirectory` both skip straight to the uploads folder.
func shouldPromptForImageDestination(mode: ImageUploadDestinationMode, terminalDirectory: String?) -> Bool {
    mode == .ask && terminalDirectory != nil
}

/// Terminal directory to use for `mode`, or nil to use the uploads folder.
func imageUploadTerminalDirectory(mode: ImageUploadDestinationMode, terminalDirectory: String?) -> String? {
    mode == .uploadsFolder ? nil : terminalDirectory
}

/// The remote operations image upload needs. Implemented over a channel on the terminal's own SSH connection.
protocol RemoteImageFiles: AnyObject {
    func homeDirectory() async throws -> String
    /// Canonical path when `path` names a directory the account can reach; nil when it is missing, not a directory, or denied.
    func resolveDirectory(_ path: String) async throws -> String?
    /// Creates `path` with mode 0700 when it does not exist.
    func ensurePrivateDirectory(_ path: String) async throws
    /// Writes `source` to a temporary file, then renames it to `name`. Throws `ImageUploadError.destinationUnusable`
    /// only when the server refused the destination before any byte was read from `source`.
    func writeNewFile(
        in directory: String,
        name: String,
        from source: URL,
        progress: @escaping @Sendable (UInt64, UInt64?) -> Void
    ) async throws
    func close() async
}

/// Opens an image-upload channel on a live session without a new connection or credential prompt.
protocol RemoteImageFilesProviding: AnyObject {
    func openRemoteImageFiles() async throws -> any RemoteImageFiles
}

enum ImageUploader {
    /// Uploads to `terminalDirectory` when it is a writable directory, otherwise to the uploads folder under home.
    /// Falls back only before any bytes were read, so a failed first attempt never leaves a half-consumed source.
    static func upload(
        files: any RemoteImageFiles,
        terminalDirectory: String?,
        fileName: String,
        from source: URL,
        progress: @escaping @Sendable (UInt64, UInt64?) -> Void
    ) async throws -> ImageUploadResult {
        if let terminalDirectory, let directory = try await files.resolveDirectory(terminalDirectory) {
            do {
                try await files.writeNewFile(in: directory, name: fileName, from: source, progress: progress)
                return ImageUploadResult(remotePath: remoteChildPath(parent: directory, name: fileName), fellBackToUploadsFolder: false)
            } catch ImageUploadError.destinationUnusable {
                // Fall through to the uploads folder.
            }
        }
        let home = try await files.homeDirectory()
        var path = home
        for segment in imageUploadsFolder.split(separator: "/") {
            path = remoteChildPath(parent: path, name: String(segment))
            try await files.ensurePrivateDirectory(path)
        }
        try await files.writeNewFile(in: path, name: fileName, from: source, progress: progress)
        return ImageUploadResult(
            remotePath: remoteChildPath(parent: path, name: fileName),
            fellBackToUploadsFolder: terminalDirectory != nil
        )
    }
}

enum ImageUploadSource {
    case library
    case camera
    case share
}

/// A per-host choice wins; otherwise the terminal menu uploads to the current directory and a share-in asks.
func resolveImageUploadMode(hostMode: ImageUploadDestinationMode?, shared: Bool) -> ImageUploadDestinationMode {
    hostMode ?? (shared ? .ask : .currentDirectory)
}

/// A share-in goes straight to the only live session; otherwise the user picks a session or saved host.
func shareInGoesToSingleSession(liveSessionCount: Int) -> Bool {
    liveSessionCount == 1
}
