import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import GhosttyConnect

final class ImageUploadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_617_005) // 2026-11-25T14:30:05Z
    private let utc = TimeZone(identifier: "UTC")!

    func testFileNamesAreTimestampedAndUnique() {
        var generator = SystemRandomNumberGenerator()
        let first = imageUploadFileName(now: now, fileExtension: "png", timeZone: utc, using: &generator)
        let second = imageUploadFileName(now: now, fileExtension: "png", timeZone: utc, using: &generator)
        XCTAssertNotNil(first.range(of: #"^screenshot-20261125-143005-[a-z0-9]{4}\.png$"#, options: .regularExpression), first)
        XCTAssertNotEqual(first, second)
    }

    func testFileNameExtensionIsSanitized() {
        XCTAssertTrue(imageUploadFileName(now: now, fileExtension: "JPG", timeZone: utc).hasSuffix(".jpg"))
        XCTAssertTrue(imageUploadFileName(now: now, fileExtension: "../x", timeZone: utc).hasSuffix(".x"))
        XCTAssertTrue(imageUploadFileName(now: now, fileExtension: "", timeZone: utc).hasSuffix(".png"))
        XCTAssertTrue(validRemoteChildName(imageUploadFileName(now: now, fileExtension: "png", timeZone: utc)))
    }

    func testSafePathsAreNotQuoted() {
        XCTAssertEqual(shellQuotePath("/home/me/project/a-b_c.png"), "/home/me/project/a-b_c.png")
    }

    func testUnsafePathsAreSingleQuoted() {
        XCTAssertEqual(shellQuotePath("/srv/my project/a.png"), "'/srv/my project/a.png'")
        XCTAssertEqual(shellQuotePath("/srv/it's/a.png"), "'/srv/it'\\''s/a.png'")
        XCTAssertEqual(shellQuotePath("/srv/$HOME/`x`.png"), "'/srv/$HOME/`x`.png'")
        XCTAssertEqual(shellQuotePath(""), "''")
    }

    func testPastedTextJoinsPathsWithoutExecutingAnything() {
        let text = pastedUploadPaths(["/a/one.png", "/a b/two.png"])
        XCTAssertEqual(text, "/a/one.png '/a b/two.png'")
        XCTAssertFalse(text.contains("\n") || text.contains("\r"))
    }

    func testPromptOnlyWhenAskingWithAKnownDirectory() {
        XCTAssertTrue(shouldPromptForImageDestination(mode: .ask, terminalDirectory: "/srv"))
        XCTAssertFalse(shouldPromptForImageDestination(mode: .ask, terminalDirectory: nil))
        XCTAssertFalse(shouldPromptForImageDestination(mode: .currentDirectory, terminalDirectory: "/srv"))
        XCTAssertFalse(shouldPromptForImageDestination(mode: .uploadsFolder, terminalDirectory: "/srv"))
    }

    func testUploadsFolderModeIgnoresTheTerminalDirectory() {
        XCTAssertNil(imageUploadTerminalDirectory(mode: .uploadsFolder, terminalDirectory: "/srv"))
        XCTAssertEqual(imageUploadTerminalDirectory(mode: .currentDirectory, terminalDirectory: "/srv"), "/srv")
        XCTAssertEqual(imageUploadTerminalDirectory(mode: .ask, terminalDirectory: "/srv"), "/srv")
        XCTAssertNil(imageUploadTerminalDirectory(mode: .currentDirectory, terminalDirectory: nil))
    }

    func testDefaultModeDependsOnWhereTheImageCameFrom() {
        XCTAssertEqual(resolveImageUploadMode(hostMode: nil, shared: false), .currentDirectory)
        XCTAssertEqual(resolveImageUploadMode(hostMode: nil, shared: true), .ask)
        XCTAssertEqual(resolveImageUploadMode(hostMode: .uploadsFolder, shared: true), .uploadsFolder)
        XCTAssertTrue(shareInGoesToSingleSession(liveSessionCount: 1))
        XCTAssertFalse(shareInGoesToSingleSession(liveSessionCount: 0))
        XCTAssertFalse(shareInGoesToSingleSession(liveSessionCount: 2))
    }

    func testHostRoundTripsDestinationModeAndToleratesUnknownValues() throws {
        var host = Host(hostname: "example.com", username: "tj")
        host.imageUploadMode = .uploadsFolder
        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        XCTAssertEqual(decoded.imageUploadMode, .uploadsFolder)
        let legacy = try JSONDecoder().decode(Host.self, from: Data(#"{"hostname":"h","username":"u","imageUploadMode":"future"}"#.utf8))
        XCTAssertNil(legacy.imageUploadMode)
    }
}

final class ImageUploaderTests: XCTestCase {
    private final class FakeFiles: RemoteImageFiles {
        var directories: Set<String> = ["/home/me"]
        var unwritable: Set<String> = []
        var written: [(directory: String, name: String)] = []
        var created: [String] = []
        var failAfterBytes = false

        func homeDirectory() async throws -> String { "/home/me" }
        func resolveDirectory(_ path: String) async throws -> String? { directories.contains(path) ? path : nil }
        func ensurePrivateDirectory(_ path: String) async throws {
            if directories.insert(path).inserted { created.append(path) }
        }
        func writeNewFile(in directory: String, name: String, from source: URL,
                          progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws {
            if unwritable.contains(directory) { throw ImageUploadError.destinationUnusable }
            if failAfterBytes { throw CocoaError(.fileWriteOutOfSpace) }
            written.append((directory, name))
            progress(1, 1)
        }
        func close() async {}
    }

    private let source = URL(fileURLWithPath: "/dev/null")

    func testUploadsToTheTerminalDirectoryWhenWritable() async throws {
        let files = FakeFiles()
        files.directories.insert("/srv/project")
        let result = try await ImageUploader.upload(files: files, terminalDirectory: "/srv/project", fileName: "a.png", from: source) { _, _ in }
        XCTAssertEqual(result, ImageUploadResult(remotePath: "/srv/project/a.png", fellBackToUploadsFolder: false))
        XCTAssertTrue(files.created.isEmpty)
    }

    func testFallsBackWhenTheDirectoryIsMissingOrNotWritable() async throws {
        let files = FakeFiles()
        let missing = try await ImageUploader.upload(files: files, terminalDirectory: "/gone", fileName: "a.png", from: source) { _, _ in }
        XCTAssertEqual(missing, ImageUploadResult(remotePath: "/home/me/.seance/uploads/a.png", fellBackToUploadsFolder: true))
        XCTAssertEqual(files.created, ["/home/me/.seance", "/home/me/.seance/uploads"])

        files.directories.insert("/srv/ro")
        files.unwritable.insert("/srv/ro")
        let denied = try await ImageUploader.upload(files: files, terminalDirectory: "/srv/ro", fileName: "b.png", from: source) { _, _ in }
        XCTAssertEqual(denied.remotePath, "/home/me/.seance/uploads/b.png")
        XCTAssertTrue(denied.fellBackToUploadsFolder)
    }

    func testNoTerminalDirectoryUsesTheUploadsFolderWithoutAFallbackNote() async throws {
        let result = try await ImageUploader.upload(files: FakeFiles(), terminalDirectory: nil, fileName: "a.png", from: source) { _, _ in }
        XCTAssertEqual(result, ImageUploadResult(remotePath: "/home/me/.seance/uploads/a.png", fellBackToUploadsFolder: false))
    }

    func testFailuresAfterBytesWereReadDoNotFallBack() async {
        let files = FakeFiles()
        files.directories.insert("/srv/project")
        files.failAfterBytes = true
        do {
            _ = try await ImageUploader.upload(files: files, terminalDirectory: "/srv/project", fileName: "a.png", from: source) { _, _ in }
            XCTFail("expected the write error to propagate")
        } catch {
            XCTAssertTrue(files.written.isEmpty)
            XCTAssertTrue(files.created.isEmpty)
        }
    }
}

final class ImageUploadPreparerTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImageUploadTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func jpegWithGPS(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }())
        let image = renderer.image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.77, kCGImagePropertyGPSLongitude: -122.4],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Phone"],
        ]
        CGImageDestinationAddImage(destination, image.cgImage!, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testPhotoMetadataIsStrippedAndConvertedToJPEG() throws {
        let source = try jpegWithGPS(width: 400, height: 300)
        XCTAssertNotNil(try properties(of: write(source))[kCGImagePropertyGPSDictionary], "fixture must carry GPS")
        let prepared = try ImageUploadPreparer.prepare(data: source, source: .library, directory: directory)
        XCTAssertEqual(prepared.fileExtension, "jpg")
        let found = try properties(of: prepared.url)
        XCTAssertNil(found[kCGImagePropertyGPSDictionary])
        XCTAssertNil(found[kCGImagePropertyExifDictionary].flatMap { ($0 as? [CFString: Any])?[kCGImagePropertyExifUserComment] })
        XCTAssertNil((found[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertEqual(found[kCGImagePropertyPixelWidth] as? Int, 400)
    }

    func testCameraPhotosAreDownscaledButLibraryPhotosAreNot() throws {
        let source = try jpegWithGPS(width: 4_000, height: 3_000)
        let camera = try ImageUploadPreparer.prepare(data: source, source: .camera, directory: directory)
        XCTAssertEqual(try properties(of: camera.url)[kCGImagePropertyPixelWidth] as? Int, 2_048)
        let library = try ImageUploadPreparer.prepare(data: source, source: .library, directory: directory)
        XCTAssertEqual(try properties(of: library.url)[kCGImagePropertyPixelWidth] as? Int, 4_000)
    }

    func testScreenshotsStayPNG() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in
            UIColor.blue.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }
        let prepared = try ImageUploadPreparer.prepare(data: try XCTUnwrap(image.pngData()), source: .library, directory: directory)
        XCTAssertEqual(prepared.fileExtension, "png")
    }

    func testUnreadableDataIsRejected() {
        XCTAssertThrowsError(try ImageUploadPreparer.prepare(data: Data("not an image".utf8), source: .library, directory: directory)) {
            XCTAssertEqual($0 as? ImageUploadError, .unsupportedImage)
        }
    }

    private func write(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.jpg")
        try data.write(to: url)
        return url
    }
}

final class ShareInboxTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareInboxTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testBatchesListFilesInOrderAndCanBeRemoved() throws {
        let inbox = ShareInbox(root: root)
        let batch = try inbox.makeBatch()
        XCTAssertTrue(inbox.pendingBatchIDs().isEmpty, "empty batches are not pending")
        for name in ["01-b.png", "00-a.png"] {
            try Data([1]).write(to: batch.directory.appendingPathComponent(name))
        }
        XCTAssertEqual(inbox.pendingBatchIDs(), [batch.id])
        XCTAssertEqual(inbox.files(in: batch.id).map(\.lastPathComponent), ["00-a.png", "01-b.png"])
        inbox.remove(batch.id)
        XCTAssertTrue(inbox.pendingBatchIDs().isEmpty)
    }

    func testStaleBatchesArePurged() throws {
        let inbox = ShareInbox(root: root)
        let batch = try inbox.makeBatch()
        try Data([1]).write(to: batch.directory.appendingPathComponent("00-a.png"))
        inbox.purgeStale(now: Date())
        XCTAssertEqual(inbox.pendingBatchIDs(), [batch.id])
        inbox.purgeStale(now: Date().addingTimeInterval(ShareInbox.staleAfter + 60))
        XCTAssertTrue(inbox.pendingBatchIDs().isEmpty)
    }

    func testOpenURLCarriesTheBatchID() throws {
        let id = UUID()
        let url = try XCTUnwrap(ShareInbox.openURL(batchID: id))
        XCTAssertEqual(url.scheme, "seance-shell")
        XCTAssertEqual(url.host, "upload")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, id.uuidString)
    }
}
