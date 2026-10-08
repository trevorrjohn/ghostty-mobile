import XCTest
@testable import GhosttyConnect

@MainActor
final class SFTPBrowserModelTests: XCTestCase {
    func testStartsInReportedDirectoryAndNavigatesRelativeToCurrentFolder() async throws {
        let transport = DirectoryTestTransport()
        let browser = SFTPBrowserModel(transportFactory: { transport })
        let host = Host()
        defer { try? SecureStore().delete(account: "sftp-locations:\(host.id.uuidString.lowercased())") }

        await browser.connect(to: host, secret: "test", key: nil, initialPath: "/srv/project")
        XCTAssertEqual(browser.path, "/srv/project")
        await browser.navigate(to: "./src")
        XCTAssertEqual(browser.path, "/srv/project/src")
        await browser.navigateUp()
        XCTAssertEqual(browser.path, "/srv/project")
        let requests = await transport.requests
        XCTAssertEqual(requests, ["/srv/project", "/srv/project/./src", "/srv/project"])
        await browser.disconnect()
    }

    func testNoMetadataStartsAtHomeAndParentStopsAtRoot() async throws {
        let transport = DirectoryTestTransport()
        let browser = SFTPBrowserModel(transportFactory: { transport })
        let host = Host()
        defer { try? SecureStore().delete(account: "sftp-locations:\(host.id.uuidString.lowercased())") }

        await browser.connect(to: host, secret: "test", key: nil)
        XCTAssertEqual(browser.path, "/home/test")
        await browser.navigate(to: "/")
        await browser.navigateUp()
        XCTAssertEqual(browser.path, "/")
        let requests = await transport.requests
        XCTAssertEqual(requests, [".", "/"])
        await browser.disconnect()
    }
}

private actor DirectoryTestTransport: SFTPTransport {
    nonisolated let hostTrustRequests = AsyncStream<HostTrustRequest> { $0.finish() }
    private(set) var requests: [String] = []

    func connect(to host: Host, credential: SSHCredential) async throws {}
    func list(path: String) async throws -> SFTPDirectory {
        requests.append(path)
        return SFTPDirectory(path: path == "." ? "/home/test" : (path as NSString).standardizingPath, entries: [])
    }
    func createDirectory(path: String) async throws { throw SFTPBrowserError.unsupportedEntry }
    func rename(from: String, to: String) async throws { throw SFTPBrowserError.unsupportedEntry }
    func remove(path: String, directory: Bool) async throws { throw SFTPBrowserError.unsupportedEntry }
    func download(path: String, to localURL: URL, maxBytes: UInt64, progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws {
        throw SFTPBrowserError.unsupportedEntry
    }
    func upload(from localURL: URL, to path: String, progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws {
        throw SFTPBrowserError.unsupportedEntry
    }
    func disconnect() async {}
}
