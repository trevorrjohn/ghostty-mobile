import Foundation
import SwiftUI

enum AuthenticationType: String, Codable, CaseIterable, Identifiable {
    case password
    case sshKey

    var id: Self { self }
    var label: String { self == .password ? "Password" : "SSH key" }
}

enum RemotePermission: String, Codable, CaseIterable, Identifiable {
    case ask
    case allow
    case block

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

struct Host: Codable, Identifiable, Hashable {
    var id = UUID()
    var alias = ""
    var hostname = ""
    var port = 22
    var username = ""
    var authenticationType = AuthenticationType.password
    var identityID: UUID?
    private(set) var legacyKeyName: String?
    var remoteClipboard = RemotePermission.ask
    var remoteNotifications = RemotePermission.ask
    var allowSftpDelete: Bool?

    var name: String { alias.trimmingCharacters(in: .whitespaces).isEmpty ? hostname : alias }
    var destination: String { "\(username)@\(hostname):\(port)" }

    init(
        id: UUID = UUID(),
        alias: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authenticationType: AuthenticationType = .password,
        identityID: UUID? = nil,
        remoteClipboard: RemotePermission = .ask,
        remoteNotifications: RemotePermission = .ask,
        allowSftpDelete: Bool? = nil
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authenticationType = authenticationType
        self.identityID = identityID
        self.remoteClipboard = remoteClipboard
        self.remoteNotifications = remoteNotifications
        self.allowSftpDelete = allowSftpDelete
    }

    private enum CodingKeys: String, CodingKey {
        case id, alias, hostname, port, username, authenticationType, identityID, keyName
        case remoteClipboard, remoteNotifications, allowSftpDelete
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        alias = try values.decodeIfPresent(String.self, forKey: .alias) ?? ""
        hostname = try values.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        authenticationType = try values.decodeIfPresent(AuthenticationType.self, forKey: .authenticationType) ?? .password
        identityID = try values.decodeIfPresent(UUID.self, forKey: .identityID)
        legacyKeyName = try values.decodeIfPresent(String.self, forKey: .keyName)
        remoteClipboard = try values.decodeIfPresent(RemotePermission.self, forKey: .remoteClipboard) ?? .ask
        remoteNotifications = try values.decodeIfPresent(RemotePermission.self, forKey: .remoteNotifications) ?? .ask
        allowSftpDelete = try values.decodeIfPresent(Bool.self, forKey: .allowSftpDelete)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(alias, forKey: .alias)
        try values.encode(hostname, forKey: .hostname)
        try values.encode(port, forKey: .port)
        try values.encode(username, forKey: .username)
        try values.encode(authenticationType, forKey: .authenticationType)
        try values.encodeIfPresent(identityID, forKey: .identityID)
        if identityID == nil { try values.encodeIfPresent(legacyKeyName, forKey: .keyName) }
        try values.encode(remoteClipboard, forKey: .remoteClipboard)
        try values.encode(remoteNotifications, forKey: .remoteNotifications)
        try values.encodeIfPresent(allowSftpDelete, forKey: .allowSftpDelete)
    }

    mutating func migrateIdentityReference(to id: UUID) {
        identityID = id
        legacyKeyName = nil
    }

    func duplicated(existingNames: [String]) -> Host {
        var duplicate = self
        duplicate.id = UUID()

        let existing = Set(existingNames.map { $0.lowercased() })
        let base = "\(name) Copy"
        var candidate = base
        var suffix = 2
        while existing.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        duplicate.alias = candidate
        return duplicate
    }
}

struct StoredKey: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var data: Data
    var requiresPassphrase: Bool
    var algorithm: String?
    var fingerprint: String?
    var publicKey: String?

    init(
        id: UUID = UUID(),
        name: String,
        data: Data,
        requiresPassphrase: Bool,
        algorithm: String? = nil,
        fingerprint: String? = nil,
        publicKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.data = data
        self.requiresPassphrase = requiresPassphrase
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.publicKey = publicKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, data, requiresPassphrase, algorithm, fingerprint, publicKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        data = try values.decode(Data.self, forKey: .data)
        requiresPassphrase = try values.decode(Bool.self, forKey: .requiresPassphrase)
        algorithm = try values.decodeIfPresent(String.self, forKey: .algorithm)
        fingerprint = try values.decodeIfPresent(String.self, forKey: .fingerprint)
        publicKey = try values.decodeIfPresent(String.self, forKey: .publicKey)
    }
}

enum IdentityReferenceMigration {
    static func migrate(hosts: [Host], keys: [StoredKey]) -> (hosts: [Host], changed: Bool) {
        var changed = false
        let migrated = hosts.map { host in
            guard host.identityID == nil, let legacyName = host.legacyKeyName else { return host }
            let matches = keys.filter { $0.name.caseInsensitiveCompare(legacyName) == .orderedSame }
            guard matches.count == 1 else { return host }
            var host = host
            host.migrateIdentityReference(to: matches[0].id)
            changed = true
            return host
        }
        return (migrated, changed)
    }
}

enum IdentityMetadataMigration {
    static func enrich(keys: [StoredKey]) -> (keys: [StoredKey], changed: Bool) {
        var changed = false
        let enriched = keys.map { key in
            guard key.algorithm == nil || key.fingerprint == nil || key.publicKey == nil,
                  let details = try? SSHKeyInspector.inspect(key.data) else { return key }
            let original = key
            var key = key
            if key.algorithm == nil { key.algorithm = details.algorithm }
            if key.fingerprint == nil { key.fingerprint = details.fingerprint }
            if key.publicKey == nil { key.publicKey = details.publicKey }
            changed = changed || key != original
            return key
        }
        return (enriched, changed)
    }
}

struct AppSettings: Codable, Equatable {
    var themeID = "ghostty"
    var fontSize = 15.0
}

struct TerminalTheme: Identifiable {
    let id: String
    let name: String
    let foreground: Color
    let background: Color
    let cursor: Color

    static let all = [
        TerminalTheme(id: "ghostty", name: "Ghostty", foreground: Color(hex: 0xF1F3F8), background: Color(hex: 0x0A0C10), cursor: Color(hex: 0x8BE9B3)),
        TerminalTheme(id: "dracula", name: "Dracula", foreground: Color(hex: 0xF8F8F2), background: Color(hex: 0x282A36), cursor: Color(hex: 0xFF79C6)),
        TerminalTheme(id: "nord", name: "Nord", foreground: Color(hex: 0xD8DEE9), background: Color(hex: 0x2E3440), cursor: Color(hex: 0x88C0D0)),
        TerminalTheme(id: "solarized-dark", name: "Solarized Dark", foreground: Color(hex: 0x839496), background: Color(hex: 0x002B36), cursor: Color(hex: 0xB58900)),
    ]

    static func theme(id: String) -> TerminalTheme { all.first { $0.id == id } ?? all[0] }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }

    static let ghosttySurface = Color(hex: 0x111318)
    static let ghosttyRaised = Color(hex: 0x1A1D24)
    static let ghosttyAccent = Color(hex: 0x8BE9B3)
    static let ghosttySecondary = Color(hex: 0xAEB6C6)
}
