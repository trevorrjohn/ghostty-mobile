import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

enum KnownHostDecision: Equatable {
    case unknown
    case trusted
    case changed

    static func decide(stored: String?, presented: String) -> KnownHostDecision {
        guard let stored, !stored.isEmpty else { return .unknown }
        return stored == presented ? .trusted : .changed
    }
}

struct SSHHostKeyRejectedError: LocalizedError {
    let destination: String

    var errorDescription: String? {
        "The SSH host key for \(destination) was not trusted."
    }
}

private struct SSHHostKeyRequestInProgressError: LocalizedError {
    var errorDescription: String? { "SSH host-key verification is already in progress." }
}

private struct SSHHostKeyValidationCancelledError: LocalizedError {
    var errorDescription: String? { "SSH host-key verification was cancelled." }
}

struct SSHHostKeyDetails: Equatable {
    let algorithm: String
    let fingerprint: String

    static func inspect(openSSHKey: String) throws -> SSHHostKeyDetails {
        let fields = openSSHKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let keyData = Data(base64Encoded: String(fields[1])) else {
            throw SSHHostKeyFormatError()
        }
        let fingerprint = Data(SHA256.hash(data: keyData)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return SSHHostKeyDetails(
            algorithm: String(fields[0]),
            fingerprint: "SHA256:\(fingerprint)"
        )
    }
}

private struct SSHHostKeyFormatError: LocalizedError {
    var errorDescription: String? { "The SSH server presented an invalid host key." }
}

protocol KnownHostStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ key: String, account: String) throws
}

struct KeychainKnownHostStore: KnownHostStore {
    private let store: SecureStore

    init(store: SecureStore = SecureStore()) {
        self.store = store
    }

    func read(account: String) throws -> String? {
        try store.read(String.self, account: account, default: "").nilIfEmpty
    }

    func write(_ key: String, account: String) throws {
        try store.write(key, account: account)
    }
}

final class KeychainHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let account: String
    private let destination: String
    private let store: any KnownHostStore
    private let requestApproval: @Sendable (HostTrustRequest) -> Void
    private let lock = NSLock()
    private var pendingRequest: HostTrustRequest?
    private var cancelled = false

    init(
        host: String,
        port: Int,
        store: any KnownHostStore = KeychainKnownHostStore(),
        requestApproval: @escaping @Sendable (HostTrustRequest) -> Void
    ) {
        destination = "\(host):\(port)"
        account = Self.account(host: host, port: port)
        self.store = store
        self.requestApproval = requestApproval
    }

    static func account(host: String, port: Int) -> String {
        "known-host:\(host):\(port)"
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        validate(presented: String(openSSHPublicKey: hostKey)) { result in
            validationCompletePromise.completeWith(result)
        }
    }

    internal func validate(
        presented: String,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        do {
            lock.lock()
            let isCancelled = cancelled
            lock.unlock()
            guard !isCancelled else {
                completion(.failure(SSHHostKeyValidationCancelledError()))
                return
            }
            let stored = try store.read(account: account)
            switch KnownHostDecision.decide(stored: stored, presented: presented) {
            case .trusted:
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    completion(.failure(SSHHostKeyValidationCancelledError()))
                    return
                }
                completion(.success(()))
                lock.unlock()
            case .unknown, .changed:
                let details = try SSHHostKeyDetails.inspect(openSSHKey: presented)
                let status: HostTrustStatus = stored == nil ? .unknown : .changed
                let requestID = UUID()
                let request = HostTrustRequest(
                    id: requestID,
                    destination: destination,
                    algorithm: details.algorithm,
                    fingerprint: details.fingerprint,
                    previousFingerprint: try stored.map {
                        try SSHHostKeyDetails.inspect(openSSHKey: $0).fingerprint
                    },
                    status: status
                ) { [weak self] accepted in
                    self?.complete(
                        accepted: accepted,
                        requestID: requestID,
                        presented: presented,
                        completion: completion
                    )
                }
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    completion(.failure(SSHHostKeyValidationCancelledError()))
                    return
                }
                guard pendingRequest == nil else {
                    lock.unlock()
                    completion(.failure(SSHHostKeyRequestInProgressError()))
                    return
                }
                pendingRequest = request
                lock.unlock()
                requestApproval(request)
            }
        } catch {
            completion(.failure(error))
        }
    }

    func cancelPendingRequest() {
        lock.lock()
        cancelled = true
        let request = pendingRequest
        lock.unlock()
        request?.answer(accepted: false)
    }

    private func complete(
        accepted: Bool,
        requestID: UUID,
        presented: String,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        lock.lock()
        guard pendingRequest?.id == requestID else {
            lock.unlock()
            return
        }
        guard !cancelled else {
            pendingRequest = nil
            lock.unlock()
            completion(.failure(SSHHostKeyValidationCancelledError()))
            return
        }
        pendingRequest = nil
        guard accepted else {
            lock.unlock()
            completion(.failure(SSHHostKeyRejectedError(destination: destination)))
            return
        }
        do {
            try store.write(presented, account: account)
            lock.unlock()
            completion(.success(()))
        } catch {
            lock.unlock()
            completion(.failure(error))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
