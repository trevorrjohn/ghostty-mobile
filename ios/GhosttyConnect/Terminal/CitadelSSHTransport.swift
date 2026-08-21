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
    case sessionClosed

    var errorDescription: String? {
        switch self {
        case .alreadyConnected: "An SSH session is already connected."
        case .notConnected: "The SSH session is not connected."
        case .missingPassword: "A password is required."
        case .unsupportedAuthentication: "SSH key authentication is not implemented yet. Use a password profile."
        case .invalidPrivateKey: "The imported private key is invalid or unsupported. Import an OpenSSH Ed25519 or RSA key."
        case .sessionClosed: "The SSH server closed the terminal session."
        }
    }
}

actor CitadelSSHTransport: SSHTransport {
    nonisolated let output: AsyncThrowingStream<Data, Error>

    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var sessionTask: Task<Void, Never>?

    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { continuation = $0 }
        outputContinuation = continuation
    }

    func connect(to host: Host, credential: SSHCredential) async throws {
        guard client == nil else { throw SSHTransportError.alreadyConnected }
        let authenticationMethod = try CitadelAuthenticationFactory.make(
            username: host.username,
            credential: credential
        )

        let settings = SSHClientSettings(
            host: host.hostname,
            port: host.port,
            authenticationMethod: { authenticationMethod },
            hostKeyValidator: .custom(KeychainHostKeyValidator(host: host.hostname, port: host.port))
        )
        let client: SSHClient
        do {
            client = try await SSHClient.connect(to: settings)
        } catch {
            throw Self.connectionError(error, host: host)
        }
        self.client = client

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
                    await self?.setWriter(outbound)
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
                self?.outputContinuation.finish()
            } catch {
                await readiness.resolve(.failure(error))
                self?.outputContinuation.finish(throwing: error)
            }
        }

        do {
            try await readiness.wait()
        } catch {
            try? await client.close()
            self.client = nil
            throw error
        }
    }

    func write(_ data: Data) async throws {
        guard let writer else { throw SSHTransportError.notConnected }
        try await writer.write(ByteBuffer(bytes: data))
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {
        guard let writer else { throw SSHTransportError.notConnected }
        try await writer.changeSize(
            cols: max(1, columns),
            rows: max(1, rows),
            pixelWidth: max(0, pixelWidth),
            pixelHeight: max(0, pixelHeight)
        )
    }

    func disconnect() async {
        sessionTask?.cancel()
        sessionTask = nil
        writer = nil
        if let client {
            try? await client.close()
            self.client = nil
        }
        outputContinuation.finish()
    }

    private func setWriter(_ writer: TTYStdinWriter) {
        self.writer = writer
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
                throw SSHTransportError.invalidPrivateKey
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
