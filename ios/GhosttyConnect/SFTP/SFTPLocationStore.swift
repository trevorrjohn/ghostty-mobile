import Foundation

struct SFTPLocations: Codable, Equatable {
    var favorites: [String] = []
    var recent: [String] = []
}

struct SFTPLocationStore {
    private let store = SecureStore()

    func load(hostID: UUID) throws -> SFTPLocations {
        try store.read(
            SFTPLocations.self,
            account: account(hostID),
            default: SFTPLocations(),
            maximumBytes: 32 * 1024
        )
    }

    func save(_ locations: SFTPLocations, hostID: UUID) throws {
        try store.write(locations, account: account(hostID))
    }

    private func account(_ hostID: UUID) -> String { "sftp-locations:\(hostID.uuidString.lowercased())" }
}
