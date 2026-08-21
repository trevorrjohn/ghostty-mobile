import Citadel
import Foundation
import NIOCore
import NIOSSH

enum KnownHostDecision: Equatable {
    case trustFirstUse
    case trusted
    case mismatch

    static func decide(stored: String?, presented: String) -> KnownHostDecision {
        guard let stored, !stored.isEmpty else { return .trustFirstUse }
        return stored == presented ? .trusted : .mismatch
    }
}

struct SSHHostKeyChangedError: LocalizedError {
    let destination: String

    var errorDescription: String? {
        "The SSH host key for \(destination) has changed. The connection was blocked."
    }
}

final class KeychainHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let account: String
    private let destination: String
    private let store: SecureStore

    init(host: String, port: Int, store: SecureStore = SecureStore()) {
        destination = "\(host):\(port)"
        account = Self.account(host: host, port: port)
        self.store = store
    }

    static func account(host: String, port: Int) -> String {
        "known-host:\(host):\(port)"
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let presented = String(openSSHPublicKey: hostKey)
        do {
            let stored = try store.read(String.self, account: account, default: "")
            switch KnownHostDecision.decide(stored: stored, presented: presented) {
            case .trustFirstUse:
                try store.write(presented, account: account)
                validationCompletePromise.succeed(())
            case .trusted:
                validationCompletePromise.succeed(())
            case .mismatch:
                validationCompletePromise.fail(SSHHostKeyChangedError(destination: destination))
            }
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}
