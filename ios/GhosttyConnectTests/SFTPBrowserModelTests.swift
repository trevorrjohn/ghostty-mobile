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

    func testRecentFoldersRequireFileInteractionAndIgnoreDirectoryNavigation() async throws {
        let file = SFTPEntry(name: "notes.txt", kind: .file, size: 12, modifiedAt: nil, accessedAt: nil, permissions: nil)
        let directory = SFTPEntry(name: "src", kind: .directory, size: nil, modifiedAt: nil, accessedAt: nil, permissions: nil)
        let transport = DirectoryTestTransport(entries: [file, directory])
        let browser = SFTPBrowserModel(transportFactory: { transport })
        let host = Host()
        defer { try? SecureStore().delete(account: "sftp-locations:\(host.id.uuidString.lowercased())") }

        await browser.connect(to: host, secret: "test", key: nil, initialPath: "/srv")
        await browser.open(directory)
        browser.recordFileInteraction(directory)
        XCTAssertTrue(browser.recentPaths.isEmpty)

        browser.recordFileInteraction(file)
        XCTAssertEqual(browser.recentPaths, ["/srv/src"])
        await browser.navigate(to: "/tmp")
        await browser.refresh()
        XCTAssertEqual(browser.recentPaths, ["/srv/src"])
        browser.recordFileInteraction(file)
        browser.recordFileInteraction(file)
        XCTAssertEqual(browser.recentPaths, ["/tmp", "/srv/src"])
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
    private let entries: [SFTPEntry]

    init(entries: [SFTPEntry] = []) { self.entries = entries }

    func connect(to host: Host, credential: SSHCredential) async throws {}
    func list(path: String) async throws -> SFTPDirectory {
        requests.append(path)
        return SFTPDirectory(path: path == "." ? "/home/test" : (path as NSString).standardizingPath, entries: entries)
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
