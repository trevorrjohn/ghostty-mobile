import XCTest
@testable import GhosttyConnect

final class HostDuplicationTests: XCTestCase {
    func testDuplicatesHostConfigurationWithNewIdentity() {
        let host = Host(
            alias: "Production",
            hostname: "server.example.com",
            port: 2222,
            username: "deploy",
            authenticationType: .sshKey,
            keyName: "id_ed25519",
            remoteClipboard: .allow,
            remoteNotifications: .block
        )

        let duplicate = host.duplicated(existingNames: [host.name])

        XCTAssertNotEqual(duplicate.id, host.id)
        XCTAssertEqual(duplicate.alias, "Production Copy")
        XCTAssertEqual(duplicate.hostname, host.hostname)
        XCTAssertEqual(duplicate.port, host.port)
        XCTAssertEqual(duplicate.username, host.username)
        XCTAssertEqual(duplicate.authenticationType, host.authenticationType)
        XCTAssertEqual(duplicate.keyName, host.keyName)
        XCTAssertEqual(duplicate.remoteClipboard, host.remoteClipboard)
        XCTAssertEqual(duplicate.remoteNotifications, host.remoteNotifications)
    }

    func testGeneratesUniqueCopyNameCaseInsensitively() {
        var host = Host()
        host.hostname = "server"

        let duplicate = host.duplicated(existingNames: ["server copy", "Server Copy 2"])

        XCTAssertEqual(duplicate.alias, "server Copy 3")
    }
}
