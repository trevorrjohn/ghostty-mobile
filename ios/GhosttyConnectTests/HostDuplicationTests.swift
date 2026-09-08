import XCTest
@testable import GhosttyConnect

final class HostDuplicationTests: XCTestCase {
    func testDuplicatesHostConfigurationWithNewIdentity() {
        let identityID = UUID()
        let host = Host(
            alias: "Production",
            hostname: "server.example.com",
            port: 2222,
            username: "deploy",
            authenticationType: .sshKey,
            identityID: identityID,
            remoteClipboard: .allow,
            remoteNotifications: .block,
            retryEnabled: true,
            retryMaxAttempts: 8,
            retryBackoff: .conservative
        )

        let duplicate = host.duplicated(existingNames: [host.name])

        XCTAssertNotEqual(duplicate.id, host.id)
        XCTAssertEqual(duplicate.alias, "Production Copy")
        XCTAssertEqual(duplicate.hostname, host.hostname)
        XCTAssertEqual(duplicate.port, host.port)
        XCTAssertEqual(duplicate.username, host.username)
        XCTAssertEqual(duplicate.authenticationType, host.authenticationType)
        XCTAssertEqual(duplicate.identityID, host.identityID)
        XCTAssertEqual(duplicate.remoteClipboard, host.remoteClipboard)
        XCTAssertEqual(duplicate.remoteNotifications, host.remoteNotifications)
        XCTAssertEqual(duplicate.retryEnabled, host.retryEnabled)
        XCTAssertEqual(duplicate.retryMaxAttempts, host.retryMaxAttempts)
        XCTAssertEqual(duplicate.retryBackoff, host.retryBackoff)
    }

    func testGeneratesUniqueCopyNameCaseInsensitively() {
        var host = Host()
        host.hostname = "server"

        let duplicate = host.duplicated(existingNames: ["server copy", "Server Copy 2"])

        XCTAssertEqual(duplicate.alias, "server Copy 3")
    }

    func testLegacyHostDefaultsReconnectPolicy() throws {
        let data = Data(#"{"hostname":"example.com","username":"tj"}"#.utf8)

        let host = try JSONDecoder().decode(Host.self, from: data)

        XCTAssertTrue(host.retryEnabled)
        XCTAssertEqual(host.retryMaxAttempts, 5)
        XCTAssertEqual(host.retryBackoff, .balanced)
    }
}
