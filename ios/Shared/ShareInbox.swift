import Foundation

/// Hand-off folder between the Share extension and the app, inside the shared App Group container.
/// The extension only copies image files in; the app owns every connection, prompt and upload.
struct ShareInbox {
    static let appGroupID = "group.fail.founder.terminal"
    static let urlScheme = "seance-shell"
    static let uploadURLHost = "upload"
    static let maximumImages = 10
    static let staleAfter: TimeInterval = 24 * 60 * 60

    let root: URL

    /// The App Group's inbox, or nil when the group is not provisioned for this build.
    static var shared: ShareInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            .map { ShareInbox(root: $0.appendingPathComponent("ShareInbox", isDirectory: true)) }
    }

    static func openURL(batchID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = uploadURLHost
        components.queryItems = [URLQueryItem(name: "id", value: batchID.uuidString)]
        return components.url
    }

    func batchDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Creates an empty batch folder for the extension to fill.
    func makeBatch() throws -> (id: UUID, directory: URL) {
        let id = UUID()
        let directory = batchDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (id, directory)
    }

    /// Batch ids with at least one file, oldest first.
    func pendingBatchIDs() -> [UUID] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .compactMap { url -> (UUID, Date)? in
                guard let id = UUID(uuidString: url.lastPathComponent), !files(in: id).isEmpty else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (id, date)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Image files in a batch, in the order the extension numbered them.
    func files(in id: UUID) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: batchDirectory(id),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: batchDirectory(id))
    }

    /// Drops batches nobody picked up, so shared images never linger in the container.
    func purgeStale(now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )) ?? []
        for url in entries {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(date) > Self.staleAfter { try? FileManager.default.removeItem(at: url) }
        }
    }
}
