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
    private static let supportedLabels = [
        "OPENSSH PRIVATE KEY",
        "RSA PRIVATE KEY",
        "EC PRIVATE KEY",
        "DSA PRIVATE KEY",
        "ENCRYPTED PRIVATE KEY",
        "PRIVATE KEY",
    ]

    static func inspect(_ data: Data, existingNames: [String] = []) throws -> SSHKeyDetails {
        let text = String(decoding: data, as: UTF8.self)
        guard let pem = privateKeyPEM(text) else {
            throw KeyInspectionError.unsupported
        }
        let isOpenSSH = pem.label == "OPENSSH PRIVATE KEY"
        let openSSHEncrypted = isOpenSSH ? openSSHEncryptionState(pem.data) : nil
        guard !isOpenSSH || openSSHEncrypted != nil else { throw KeyInspectionError.unsupported }
        let hasLegacyEncryptionHeaders = pem.text.localizedCaseInsensitiveContains("Proc-Type: 4,ENCRYPTED") ||
            pem.text.localizedCaseInsensitiveContains("DEK-Info:")
        let legacyEncryption = legacyPEMEncryption(pem.text, data: pem.data)
        let encrypted = pem.label == "ENCRYPTED PRIVATE KEY" ||
            legacyEncryption == true ||
            openSSHEncrypted == true
        guard isOpenSSH ||
                (hasLegacyEncryptionHeaders ? legacyEncryption == true : isPrivateKeyDER(pem.data, label: pem.label)) else {
            throw KeyInspectionError.unsupported
        }

        let base: String
        if pem.label == "RSA PRIVATE KEY" { base = "RSA key" }
        else if pem.label == "EC PRIVATE KEY" { base = "ECDSA key" }
        else if pem.label == "DSA PRIVATE KEY" { base = "DSA key" }
        else if pem.label == "ENCRYPTED PRIVATE KEY" { base = "Encrypted key" }
        else if pem.label == "PRIVATE KEY" { base = "PKCS#8 key" }
        else if let fingerprint = openSSHFingerprint(pem.text) { base = fingerprint }
        else { base = "SSH key" }

        return SSHKeyDetails(suggestedName: uniqueName(base, existingNames), requiresPassphrase: encrypted)
    }

    private static func openSSHData(_ text: String) -> Data? {
        guard let pem = privateKeyPEM(text),
              pem.label == "OPENSSH PRIVATE KEY",
              pem.data.starts(with: Data("openssh-key-v1\0".utf8)) else { return nil }
        var data = pem.data
        data.removeFirst(15)
        return data
    }

    private static func privateKeyPEM(_ text: String) -> (label: String, data: Data, text: String)? {
        let lines = text.components(separatedBy: .newlines)
        guard let beginIndex = lines.firstIndex(where: { line in
            supportedLabels.contains { line == "-----BEGIN \($0)-----" }
        }) else {
            return nil
        }
        let begin = lines[beginIndex]
        let label = begin.dropFirst(11).dropLast(5)
        guard let endIndex = lines[(beginIndex + 1)...].firstIndex(of: "-----END \(label)-----") else { return nil }
        let blockLines = lines[beginIndex...endIndex]
        let encoded = blockLines.dropFirst().dropLast()
            .filter { !$0.contains(":") }
            .joined()
            .filter { !$0.isWhitespace }
        guard !encoded.isEmpty, let data = Data(base64Encoded: String(encoded)), !data.isEmpty else { return nil }
        return (String(label), data, blockLines.joined(separator: "\n"))
    }

    private static func openSSHEncryptionState(_ pemData: Data) -> Bool? {
        guard pemData.starts(with: Data("openssh-key-v1\0".utf8)) else { return nil }
        var data = pemData.dropFirst(15)
        guard let cipherData = readSSHString(&data),
              let keyDerivationData = readSSHString(&data),
              readSSHString(&data) != nil,
              let keyCount = readUInt32(&data),
              keyCount > 0,
              keyCount <= 64 else { return nil }
        for _ in 0..<keyCount where readSSHString(&data) == nil { return nil }
        guard readSSHString(&data) != nil, data.isEmpty else { return nil }
        let cipher = String(decoding: cipherData, as: UTF8.self)
        let keyDerivation = String(decoding: keyDerivationData, as: UTF8.self)
        guard (cipher == "none") == (keyDerivation == "none") else { return nil }
        return cipher != "none"
    }

    private static func legacyPEMEncryption(_ text: String, data: Data) -> Bool? {
        let hasEncryptionHeader = text.localizedCaseInsensitiveContains("Proc-Type: 4,ENCRYPTED") ||
            text.localizedCaseInsensitiveContains("DEK-Info:")
        guard hasEncryptionHeader else { return false }
        guard text.localizedCaseInsensitiveContains("Proc-Type: 4,ENCRYPTED"),
              let info = text.components(separatedBy: .newlines)
                .first(where: { $0.localizedCaseInsensitiveContains("DEK-Info:") })?
                .split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces),
              let separator = info.firstIndex(of: ",") else { return nil }
        let cipher = String(info[..<separator]).uppercased()
        let iv = info[info.index(after: separator)...]
        let blockSize: Int
        let ivLength: Int
        switch cipher {
        case "AES-128-CBC", "AES-192-CBC", "AES-256-CBC":
            blockSize = 16
            ivLength = 32
        case "DES-EDE3-CBC":
            blockSize = 8
            ivLength = 16
        default:
            return nil
        }
        guard iv.count == ivLength,
              iv.allSatisfy({ $0.isHexDigit }),
              data.count >= blockSize * 2,
              data.count.isMultiple(of: blockSize) else { return nil }
        return true
    }

    private static func isPrivateKeyDER(_ data: Data, label: String) -> Bool {
        guard let outer = derElement(data, at: 0), outer.tag == 0x30, outer.nextOffset == data.count,
              let children = derChildren(data, in: outer.content), !children.isEmpty else { return false }
        switch label {
        case "RSA PRIVATE KEY":
            return children.count >= 9 && children.allSatisfy { $0.tag == 0x02 && !$0.content.isEmpty }
        case "EC PRIVATE KEY":
            return children.count >= 2 && children[0].tag == 0x02 && children[1].tag == 0x04 && !children[1].content.isEmpty
        case "DSA PRIVATE KEY":
            return children.count >= 6 && children.prefix(6).allSatisfy { $0.tag == 0x02 && !$0.content.isEmpty }
        case "PRIVATE KEY":
            return children.count >= 3 && children[0].tag == 0x02 &&
                isAlgorithmIdentifier(data, children[1]) && children[2].tag == 0x04 && !children[2].content.isEmpty
        case "ENCRYPTED PRIVATE KEY":
            return children.count == 2 && isAlgorithmIdentifier(data, children[0]) &&
                children[1].tag == 0x04 && !children[1].content.isEmpty
        default:
            return false
        }
    }

    private struct DERElement {
        let tag: UInt8
        let content: Range<Int>
        let nextOffset: Int
    }

    private static func derElement(_ data: Data, at offset: Int) -> DERElement? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let tag = data[offset]
        let firstLength = Int(data[offset + 1])
        var contentOffset = offset + 2
        let contentLength: Int
        if firstLength < 0x80 {
            contentLength = firstLength
        } else {
            let byteCount = firstLength & 0x7f
            guard byteCount > 0, byteCount <= 4, contentOffset <= data.count - byteCount,
                  data[contentOffset] != 0 else { return nil }
            contentLength = data[contentOffset..<(contentOffset + byteCount)].reduce(0) { ($0 << 8) | Int($1) }
            contentOffset += byteCount
            guard contentLength >= 0x80 else { return nil }
        }
        guard contentLength <= data.count - contentOffset else { return nil }
        return DERElement(
            tag: tag,
            content: contentOffset..<(contentOffset + contentLength),
            nextOffset: contentOffset + contentLength
        )
    }

    private static func derChildren(_ data: Data, in range: Range<Int>) -> [DERElement]? {
        var children: [DERElement] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard let child = derElement(data, at: offset), child.nextOffset <= range.upperBound else { return nil }
            children.append(child)
            offset = child.nextOffset
        }
        return offset == range.upperBound ? children : nil
    }

    private static func isAlgorithmIdentifier(_ data: Data, _ element: DERElement) -> Bool {
        guard element.tag == 0x30,
              let children = derChildren(data, in: element.content),
              let identifier = children.first else { return false }
        return identifier.tag == 0x06 && !identifier.content.isEmpty
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

    static func uniqueName(_ base: String, _ names: [String]) -> String {
        let existing = Set(names.map { $0.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}
