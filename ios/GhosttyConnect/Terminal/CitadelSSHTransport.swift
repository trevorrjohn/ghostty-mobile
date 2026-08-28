import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

enum SSHTransportError: LocalizedError {
    case alreadyConnected
    case notConnected
    case missingPassword
    case unsupportedAuthentication
    case invalidPrivateKey
    case keyDecryptionFailed
    case sessionClosed

    var errorDescription: String? {
        switch self {
        case .alreadyConnected: "An SSH session is already connected."
        case .notConnected: "The SSH session is not connected."
        case .missingPassword: "A password is required."
        case .unsupportedAuthentication: "SSH key authentication is not implemented yet. Use a password profile."
        case .invalidPrivateKey: "The imported private key is invalid or unsupported. Import an OpenSSH Ed25519 or RSA key."
        case .keyDecryptionFailed: "The private-key passphrase was incorrect."
        case .sessionClosed: "The SSH server closed the terminal session."
        }
    }
}

actor CitadelSSHTransport: SSHTransport {
    nonisolated let output: AsyncThrowingStream<Data, Error>
    nonisolated let hostTrustRequests: AsyncStream<HostTrustRequest>

    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let hostTrustContinuation: AsyncStream<HostTrustRequest>.Continuation
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var connectTask: Task<SSHClient, Error>?
    private var sessionTask: Task<Void, Never>?
    private var hostKeyValidator: KeychainHostKeyValidator?
    private var connectionAttemptID: UUID?
    private var clientSessionID: UUID?
    private var disconnectRequested = false
    private var outputFinished = false
    private var sessionEndingCleanly = false
    private var hasStarted = false

    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { continuation = $0 }
        outputContinuation = continuation
        var hostTrustContinuation: AsyncStream<HostTrustRequest>.Continuation!
        hostTrustRequests = AsyncStream { hostTrustContinuation = $0 }
        self.hostTrustContinuation = hostTrustContinuation
    }

    func connect(to host: Host, credential: SSHCredential) async throws {
        guard !hasStarted, client == nil, connectionAttemptID == nil else {
            throw SSHTransportError.alreadyConnected
        }
        hasStarted = true
        let authenticationMethod = try CitadelAuthenticationFactory.make(
            username: host.username,
            credential: credential
        )
        let attemptID = UUID()
        connectionAttemptID = attemptID
        disconnectRequested = false

        let validator = KeychainHostKeyValidator(host: host.hostname, port: host.port) { [hostTrustContinuation] request in
            if case .terminated = hostTrustContinuation.yield(request) {
                request.answer(accepted: false)
            }
        }
        hostKeyValidator = validator
        let settings = SSHClientSettings(
            host: host.hostname,
            port: host.port,
            authenticationMethod: { authenticationMethod },
            hostKeyValidator: .custom(validator)
        )
        let client: SSHClient
        let connectTask = Task { try await SSHClient.connect(to: settings) }
        self.connectTask = connectTask
        do {
            client = try await connectTask.value
        } catch {
            validator.cancelPendingRequest()
            if connectionAttemptID == attemptID {
                connectionAttemptID = nil
                hostKeyValidator = nil
                self.connectTask = nil
            }
            throw Self.connectionError(error, host: host)
        }
        guard connectionAttemptID == attemptID else {
            try? await client.close()
            throw CancellationError()
        }
        self.connectTask = nil
        connectionAttemptID = nil
        self.client = client
        let clientSessionID = UUID()
        self.clientSessionID = clientSessionID
        client.onDisconnect { [weak self] in
            Task { await self?.parentDisconnected(clientSessionID: clientSessionID) }
        }
        guard client.isConnected else {
            parentDisconnected(clientSessionID: clientSessionID)
            throw SSHTransportError.sessionClosed
        }

        let readiness = PTYReadiness()
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )

        sessionTask = Task { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    guard await self?.setWriter(outbound, clientSessionID: clientSessionID) == true else {
                        throw CancellationError()
                    }
                    await readiness.resolve(.success(()))
                    for try await event in inbound {
                        switch event {
                        case .stdout(var buffer), .stderr(var buffer):
                            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                                self?.outputContinuation.yield(Data(bytes))
                            }
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                await self?.beginCleanSessionEnd(clientSessionID: clientSessionID)
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await self?.finishCleanSessionEnd(clientSessionID: clientSessionID)
            } catch {
                await readiness.resolve(.failure(error))
                guard !Task.isCancelled else { return }
                await self?.finishOutput(throwing: error)
            }
        }

        do {
            try await readiness.wait()
            guard self.clientSessionID == clientSessionID, self.client === client, client.isConnected else {
                throw SSHTransportError.sessionClosed
            }
        } catch {
            if self.client === client {
                self.clientSessionID = nil
                self.client = nil
            }
            try? await client.close()
            throw error
        }
    }

    func write(_ data: Data) async throws {
        if sessionEndingCleanly { return }
        guard let writer else { throw SSHTransportError.notConnected }
        try await writer.write(ByteBuffer(bytes: data))
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {
        if sessionEndingCleanly { return }
        guard let writer else { throw SSHTransportError.notConnected }
        try await writer.changeSize(
            cols: max(1, columns),
            rows: max(1, rows),
            pixelWidth: max(0, pixelWidth),
            pixelHeight: max(0, pixelHeight)
        )
    }

    func disconnect() async {
        disconnectRequested = true
        connectTask?.cancel()
        connectTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        sessionEndingCleanly = true
        writer = nil
        hostKeyValidator?.cancelPendingRequest()
        hostKeyValidator = nil
        connectionAttemptID = nil
        clientSessionID = nil
        let client = self.client
        self.client = nil
        finishOutput()
        if let client {
            try? await client.close()
        }
    }

    private func setWriter(_ writer: TTYStdinWriter, clientSessionID: UUID) -> Bool {
        guard self.clientSessionID == clientSessionID, !disconnectRequested else { return false }
        self.writer = writer
        return true
    }

    private func beginCleanSessionEnd(clientSessionID: UUID) {
        guard self.clientSessionID == clientSessionID, !disconnectRequested else { return }
        sessionEndingCleanly = true
        writer = nil
    }

    private func finishCleanSessionEnd(clientSessionID: UUID) {
        guard self.clientSessionID == clientSessionID, sessionEndingCleanly, !disconnectRequested else { return }
        finishOutput()
    }

    private func parentDisconnected(clientSessionID: UUID) {
        guard self.clientSessionID == clientSessionID else { return }
        sessionTask?.cancel()
        sessionTask = nil
        sessionEndingCleanly = true
        writer = nil
        self.client = nil
        self.clientSessionID = nil
        if disconnectRequested {
            finishOutput()
        } else {
            finishOutput(throwing: SSHTransportError.sessionClosed)
        }
    }

    private func finishOutput(throwing error: Error? = nil) {
        guard !outputFinished else { return }
        outputFinished = true
        if let error {
            outputContinuation.finish(throwing: error)
        } else {
            outputContinuation.finish()
        }
    }

    private static func connectionError(_ error: Error, host: Host) -> Error {
        switch error {
        case SSHClientError.unsupportedPasswordAuthentication:
            return SSHConnectionError.passwordNotSupported(host.destination)
        case SSHClientError.unsupportedPrivateKeyAuthentication:
            return SSHConnectionError.publicKeyNotSupported(host.destination)
        case SSHClientError.allAuthenticationOptionsFailed, is AuthenticationFailed:
            return SSHConnectionError.authenticationFailed(host.destination)
        default:
            return error
        }
    }
}

enum SSHConnectionError: LocalizedError {
    case passwordNotSupported(String)
    case publicKeyNotSupported(String)
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .passwordNotSupported(let destination):
            "\(destination) does not allow password authentication. Use an SSH key profile."
        case .publicKeyNotSupported(let destination):
            "\(destination) does not allow public-key authentication."
        case .authenticationFailed(let destination):
            "Authentication failed for \(destination). Check the username and credential."
        }
    }
}

enum SSHFailureClassifier {
    static func classify(_ error: Error, destination: String) -> SessionFailure {
        switch error {
        case is SSHHostKeyRejectedError:
            return SessionFailure(kind: .hostTrust, message: error.localizedDescription)
        case SSHConnectionError.authenticationFailed,
             SSHTransportError.missingPassword,
             SSHTransportError.keyDecryptionFailed:
            return SessionFailure(kind: .authentication, message: error.localizedDescription)
        case SSHConnectionError.passwordNotSupported,
             SSHConnectionError.publicKeyNotSupported,
             SSHTransportError.unsupportedAuthentication,
             SSHTransportError.invalidPrivateKey:
            return SessionFailure(kind: .configuration, message: error.localizedDescription)
        case SSHTransportError.sessionClosed:
            return SessionFailure(kind: .network, message: "The SSH session to \(destination) closed unexpectedly.")
        case SSHTransportError.alreadyConnected,
             SSHTransportError.notConnected:
            return SessionFailure(kind: .protocolFailure, message: error.localizedDescription)
        case is CancellationError:
            return SessionFailure(kind: .network, message: "The connection to \(destination) was cancelled.")
        default:
            return SessionFailure(
                kind: .network,
                message: "Could not connect to \(destination). Check the network, hostname, and SSH port."
            )
        }
    }
}

enum CitadelAuthenticationFactory {
    static func make(username: String, credential: SSHCredential) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            guard !password.isEmpty else { throw SSHTransportError.missingPassword }
            return .passwordBased(username: username, password: password)
        case .privateKey(let data, let passphrase):
            guard let keyString = String(data: data, encoding: .utf8) else {
                throw SSHTransportError.invalidPrivateKey
            }
            let decryptionKey = passphrase?.data(using: .utf8)
            do {
                switch try SSHKeyDetection.detectPrivateKeyType(from: keyString) {
                case .ed25519:
                    let key = try Curve25519.Signing.PrivateKey(
                        sshEd25519: data,
                        decryptionKey: decryptionKey
                    )
                    return .ed25519(username: username, privateKey: key)
                case .rsa:
                    let key = try Insecure.RSA.PrivateKey(
                        sshRsa: data,
                        decryptionKey: decryptionKey
                    )
                    return .rsa(username: username, privateKey: key)
                default:
                    throw SSHTransportError.unsupportedAuthentication
                }
            } catch let error as SSHTransportError {
                throw error
            } catch {
                throw passphrase == nil ? SSHTransportError.invalidPrivateKey : SSHTransportError.keyDecryptionFailed
            }
        }
    }
}

private actor PTYReadiness {
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        if let result {
            try result.get()
            return
        }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        }
    }
}
