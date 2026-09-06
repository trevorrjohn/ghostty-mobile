import XCTest
@testable import GhosttyConnect

final class SFTPModelsTests: XCTestCase {
    func testRemoteChildNameRejectsTraversalAndSeparators() {
        XCTAssertFalse(validRemoteChildName(""))
        XCTAssertFalse(validRemoteChildName("."))
        XCTAssertFalse(validRemoteChildName(".."))
        XCTAssertFalse(validRemoteChildName("a/b"))
        XCTAssertFalse(validRemoteChildName("a\\b"))
        XCTAssertFalse(validRemoteChildName("a\0b"))
        XCTAssertTrue(validRemoteChildName("archive.tar.gz"))
    }

    func testRemoteChildPathPreservesRoot() {
        XCTAssertEqual(remoteChildPath(parent: "/", name: "file.txt"), "/file.txt")
        XCTAssertEqual(remoteChildPath(parent: "/tmp", name: "file.txt"), "/tmp/file.txt")
    }

    func testUnsafeServerNamesRemainUnsupported() {
        XCTAssertEqual(sftpEntryKind(name: "../escape", permissions: 0o100644), .unsupported)
        XCTAssertEqual(sftpEntryKind(name: "nested/file", permissions: 0o100644), .unsupported)
        XCTAssertEqual(sftpEntryKind(name: "safe.txt", permissions: 0o100644), .file)
        XCTAssertEqual(sftpEntryKind(name: "folder", permissions: 0o040755), .directory)
    }

    func testFilteringKeepsDirectoriesFirstAndCanRevealHiddenEntries() {
        let entries = [
            entry("z.txt", kind: .file),
            entry("folder", kind: .directory),
            entry(".secret", kind: .file),
            entry("a.txt", kind: .file),
        ]
        XCTAssertEqual(
            filteredSFTPEntries(entries, query: "", sort: .nameAscending, showHidden: false).map(\.name),
            ["folder", "a.txt", "z.txt"]
        )
        XCTAssertEqual(
            filteredSFTPEntries(entries, query: "sec", sort: .nameAscending, showHidden: true).map(\.name),
            [".secret"]
        )
    }

    func testSizeSortUsesRequestedDirection() {
        let entries = [
            entry("small", kind: .file, size: 1),
            entry("large", kind: .file, size: 100),
        ]
        XCTAssertEqual(
            filteredSFTPEntries(entries, query: "", sort: .sizeDescending, showHidden: true).map(\.name),
            ["large", "small"]
        )
    }

    private func entry(_ name: String, kind: SFTPEntryKind, size: UInt64? = nil) -> SFTPEntry {
        SFTPEntry(
            name: name,
            kind: kind,
            size: size,
            modifiedAt: nil,
            accessedAt: nil,
            permissions: nil
        )
    }
}
