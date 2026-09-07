import Crypto
import XCTest
@testable import GhosttyConnect

final class IdentityReferenceMigrationTests: XCTestCase {
    func testMigratesUniqueLegacyNameToStableID() throws {
        let key = StoredKey(name: "Work", data: Data(), requiresPassphrase: false)
        let data = Data("{\"hostname\":\"example.com\",\"authenticationType\":\"sshKey\",\"keyName\":\"work\"}".utf8)
        let host = try JSONDecoder().decode(Host.self, from: data)

        let result = IdentityReferenceMigration.migrate(hosts: [host], keys: [key])

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.hosts[0].identityID, key.id)
        let encoded = String(decoding: try JSONEncoder().encode(result.hosts[0]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("keyName"))
    }

    func testPreservesAmbiguousLegacyNameForRecovery() throws {
        let first = StoredKey(name: "Work", data: Data(), requiresPassphrase: false)
        let second = StoredKey(name: "work", data: Data(), requiresPassphrase: false)
        let data = Data("{\"authenticationType\":\"sshKey\",\"keyName\":\"WORK\"}".utf8)
        let host = try JSONDecoder().decode(Host.self, from: data)

        let result = IdentityReferenceMigration.migrate(hosts: [host], keys: [first, second])

        XCTAssertFalse(result.changed)
        XCTAssertNil(result.hosts[0].identityID)
        let encoded = String(decoding: try JSONEncoder().encode(result.hosts[0]), as: UTF8.self)
        XCTAssertTrue(encoded.contains("keyName"))
    }

    func testStableReferenceSurvivesRename() {
        let id = UUID()
        let host = Host(authenticationType: .sshKey, identityID: id)
        let renamed = StoredKey(id: id, name: "Renamed", data: Data(), requiresPassphrase: false)

        let result = IdentityReferenceMigration.migrate(hosts: [host], keys: [renamed])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.hosts[0].identityID, id)
    }

    func testBackfillsLegacyIdentityMetadataWithoutChangingID() throws {
        let id = UUID()
        let privateKey = Curve25519.Signing.PrivateKey()
        let key = StoredKey(
            id: id,
            name: "Legacy",
            data: Data(privateKey.makeSSHRepresentation().utf8),
            requiresPassphrase: false
        )

        let result = IdentityMetadataMigration.enrich(keys: [key])

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.keys[0].id, id)
        XCTAssertEqual(result.keys[0].algorithm, "ssh-ed25519")
        XCTAssertTrue(result.keys[0].fingerprint?.hasPrefix("SHA256:") == true)
        XCTAssertTrue(result.keys[0].publicKey?.hasPrefix("ssh-ed25519 ") == true)
    }

    func testMetadataBackfillIsIdempotent() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let details = try SSHKeyInspector.inspect(Data(privateKey.makeSSHRepresentation().utf8))
        let key = StoredKey(
            name: "Current",
            data: Data(privateKey.makeSSHRepresentation().utf8),
            requiresPassphrase: false,
            algorithm: details.algorithm,
            fingerprint: details.fingerprint,
            publicKey: details.publicKey
        )

        let result = IdentityMetadataMigration.enrich(keys: [key])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.keys, [key])
    }
}
