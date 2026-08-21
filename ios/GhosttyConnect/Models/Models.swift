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
    var keyName: String?
    var remoteClipboard = RemotePermission.ask
    var remoteNotifications = RemotePermission.ask

    var name: String { alias.trimmingCharacters(in: .whitespaces).isEmpty ? hostname : alias }
    var destination: String { "\(username)@\(hostname):\(port)" }
}

struct StoredKey: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var data: Data
    var requiresPassphrase: Bool
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
