import XCTest
@testable import GhosttyConnect

final class SSHKeyInspectorTests: XCTestCase {
    func testRecognizesEncryptedPEM() throws {
        let key = Data("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,00000000000000000000000000000000\n\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n-----END RSA PRIVATE KEY-----".utf8)
        XCTAssertEqual(try SSHKeyInspector.inspect(key), SSHKeyDetails(suggestedName: "RSA key", requiresPassphrase: true))
    }

    func testRejectsHeaderOnlyEncryptedPEM() {
        let key = Data("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n-----END RSA PRIVATE KEY-----".utf8)

        XCTAssertThrowsError(try SSHKeyInspector.inspect(key))
    }

    func testCreatesUniqueNames() throws {
        let key = Data("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,00000000000000000000000000000000\n\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n-----END RSA PRIVATE KEY-----".utf8)
        XCTAssertEqual(try SSHKeyInspector.inspect(key, existingNames: ["RSA key"]).suggestedName, "RSA key 2")
    }

    func testRejectsMalformedDERPayload() {
        let key = Data("-----BEGIN PRIVATE KEY-----\nAQID\n-----END PRIVATE KEY-----".utf8)

        XCTAssertThrowsError(try SSHKeyInspector.inspect(key))
    }

    func testRejectsNonKeyDERSequence() {
        let key = Data("-----BEGIN PRIVATE KEY-----\nMAG/\n-----END PRIVATE KEY-----".utf8)

        XCTAssertThrowsError(try SSHKeyInspector.inspect(key))
    }

    func testRejectsOversizedDERLengthWithoutCrashing() {
        let bytes: [UInt8] = [0x30, 0x88, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        let encoded = Data(bytes).base64EncodedString()
        let key = Data("-----BEGIN PRIVATE KEY-----\n\(encoded)\n-----END PRIVATE KEY-----".utf8)

        XCTAssertThrowsError(try SSHKeyInspector.inspect(key))
    }

    func testIgnoresUnsupportedPEMBeforeSupportedBlock() throws {
        let key = Data("-----BEGIN FAKE PRIVATE KEY-----\nAQID\n-----END FAKE PRIVATE KEY-----\n-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,00000000000000000000000000000000\n\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n-----END RSA PRIVATE KEY-----".utf8)

        XCTAssertEqual(try SSHKeyInspector.inspect(key).suggestedName, "RSA key")
    }

    func testCreatesCaseInsensitiveUniqueNames() {
        XCTAssertEqual(SSHKeyInspector.uniqueName("Work", ["work", "WORK 2"]), "Work 3")
    }
}
