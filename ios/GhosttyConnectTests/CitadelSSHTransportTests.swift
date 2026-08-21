import Citadel
import Crypto
import XCTest
@testable import GhosttyConnect

final class CitadelSSHTransportTests: XCTestCase {
    func testRejectsEmptyPasswordBeforeConnecting() async {
        let host = Host()
        let transport = CitadelSSHTransport()

        do {
            try await transport.connect(to: host, credential: .password(""))
            XCTFail("Expected missing password")
        } catch SSHTransportError.missingPassword {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await transport.disconnect()
    }

    func testRejectsInvalidPrivateKeyBeforeConnecting() async {
        let host = Host()
        let transport = CitadelSSHTransport()

        do {
            try await transport.connect(to: host, credential: .privateKey(Data("invalid".utf8), passphrase: nil))
            XCTFail("Expected invalid private key")
        } catch SSHTransportError.invalidPrivateKey {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await transport.disconnect()
    }

    func testCreatesAuthenticationFromOpenSSHEd25519Key() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let data = Data(privateKey.makeSSHRepresentation().utf8)

        _ = try CitadelAuthenticationFactory.make(
            username: "tester",
            credential: .privateKey(data, passphrase: nil)
        )
    }
}
