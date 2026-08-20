import CryptoKit
import Foundation

enum KeyInspectionError: LocalizedError {
    case tooLarge
    case unsupported

    var errorDescription: String? {
        switch self {
        case .tooLarge: "Private keys must be 1 MiB or smaller."
        case .unsupported: "This file is not a supported OpenSSH, PEM, or PKCS#8 private key."
        }
    }
}

struct SSHKeyDetails: Equatable {
    let suggestedName: String
    let requiresPassphrase: Bool
}

enum SSHKeyInspector {
    static func inspect(_ data: Data, existingNames: [String] = []) throws -> SSHKeyDetails {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("-----BEGIN "), text.contains("PRIVATE KEY-----"), text.contains("-----END ") else {
            throw KeyInspectionError.unsupported
        }
        let openSSH = openSSHData(text)
        let openSSHEncrypted = openSSH.flatMap { data -> Bool? in
            var value = data
            return readSSHString(&value).map { String(decoding: $0, as: UTF8.self) != "none" }
        } ?? false
        let encrypted = text.contains("BEGIN ENCRYPTED PRIVATE KEY") ||
            text.contains("BEGIN SSH2 ENCRYPTED PRIVATE KEY") ||
            text.localizedCaseInsensitiveContains("Proc-Type: 4,ENCRYPTED") ||
            text.localizedCaseInsensitiveContains("DEK-Info:") ||
            openSSHEncrypted

        let base: String
        if text.contains("BEGIN RSA PRIVATE KEY") { base = "RSA key" }
        else if text.contains("BEGIN EC PRIVATE KEY") { base = "ECDSA key" }
        else if text.contains("BEGIN DSA PRIVATE KEY") { base = "DSA key" }
        else if text.contains("BEGIN ENCRYPTED PRIVATE KEY") { base = "Encrypted key" }
        else if text.contains("BEGIN PRIVATE KEY") { base = "PKCS#8 key" }
        else if let fingerprint = openSSHFingerprint(text) { base = fingerprint }
        else { base = "SSH key" }

        return SSHKeyDetails(suggestedName: unique(base, existingNames), requiresPassphrase: encrypted)
    }

    private static func openSSHData(_ text: String) -> Data? {
        guard let begin = text.range(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
              let end = text.range(of: "-----END OPENSSH PRIVATE KEY-----") else { return nil }
        let encoded = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard var data = Data(base64Encoded: String(encoded)), data.starts(with: Data("openssh-key-v1\0".utf8)) else { return nil }
        data.removeFirst(15)
        return data
    }

    private static func openSSHFingerprint(_ text: String) -> String? {
        guard var data = openSSHData(text), readSSHString(&data) != nil else { return nil }
        _ = readSSHString(&data)
        _ = readSSHString(&data)
        guard readUInt32(&data) ?? 0 > 0, let publicKey = readSSHString(&data) else { return nil }
        var keyData = publicKey
        guard let algorithmData = readSSHString(&keyData) else { return nil }
        let algorithm = String(decoding: algorithmData, as: UTF8.self)
        let label = algorithm == "ssh-ed25519" ? "Ed25519 key" : algorithm == "ssh-rsa" ? "RSA key" : algorithm.hasPrefix("ecdsa-") ? "ECDSA key" : "SSH key"
        let digest = Data(SHA256.hash(data: publicKey)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "\(label) \(digest.prefix(12))"
    }

    private static func readSSHString(_ data: inout Data) -> Data? {
        guard let length = readUInt32(&data), length <= data.count else { return nil }
        let value = data.prefix(Int(length))
        data.removeFirst(Int(length))
        return Data(value)
    }

    private static func readUInt32(_ data: inout Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let value = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        data.removeFirst(4)
        return value
    }

    private static func unique(_ base: String, _ names: [String]) -> String {
        guard names.contains(base) else { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }
}
