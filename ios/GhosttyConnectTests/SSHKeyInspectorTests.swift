import XCTest
@testable import GhosttyConnect

final class SSHKeyInspectorTests: XCTestCase {
    func testRecognizesEncryptedPEM() throws {
        let key = Data("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n-----END RSA PRIVATE KEY-----".utf8)
        XCTAssertEqual(try SSHKeyInspector.inspect(key), SSHKeyDetails(suggestedName: "RSA key", requiresPassphrase: true))
    }

    func testCreatesUniqueNames() throws {
        let key = Data("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----".utf8)
        XCTAssertEqual(try SSHKeyInspector.inspect(key, existingNames: ["PKCS#8 key"]).suggestedName, "PKCS#8 key 2")
    }
}
