import Foundation

struct ItermInlineImage: Equatable {
    let options: [String: String]
    let data: Data
}

final class ItermInlineImageParser {
    private static let prefix = Array("\u{1b}]1337;".utf8)
    private static let supportedOptions = Set(["name", "size", "width", "height", "preserveAspectRatio", "inline"])
    private static let maxHeaderBytes = 4_096
    private static let maxImageBytes = 4 * 1_024 * 1_024
    private static let maxEncodedBytes = 6 * 1_024 * 1_024

    private let onBytes: (Data) -> Void
    private let onImage: (ItermInlineImage) -> Void
    private var plain: [UInt8] = []
    private var control: [UInt8] = []
    private var prefixIndex = 0
    private var capturing = false
    private var pendingEscape = false
    private var draining = false
    private var multipart: (options: [String: String], encoded: [UInt8])?

    init(onBytes: @escaping (Data) -> Void, onImage: @escaping (ItermInlineImage) -> Void) {
        self.onBytes = onBytes
        self.onImage = onImage
    }

    func feed(_ data: Data) {
        data.forEach(accept)
        flushPlain()
    }

    func reset() {
        plain.removeAll(keepingCapacity: true)
        control.removeAll(keepingCapacity: true)
        prefixIndex = 0
        capturing = false
        pendingEscape = false
        draining = false
        multipart = nil
    }

    private func accept(_ byte: UInt8) {
        if capturing {
            if pendingEscape && byte == 0x5c { finish(terminator: [0x1b, 0x5c]); return }
            if pendingEscape {
                appendControl(0x1b)
                pendingEscape = false
                if byte == 0x07 { finish(terminator: [0x07]) }
                else if byte == 0x1b { pendingEscape = true }
                else { appendControl(byte) }
            } else if byte == 0x07 { finish(terminator: [0x07]) }
            else if byte == 0x1b { pendingEscape = true }
            else { appendControl(byte) }
            return
        }

        if byte == Self.prefix[prefixIndex] {
            prefixIndex += 1
            if prefixIndex == Self.prefix.count {
                flushPlain()
                prefixIndex = 0
                capturing = true
                control.removeAll(keepingCapacity: true)
            }
            return
        }
        if prefixIndex > 0 {
            plain.append(contentsOf: Self.prefix.prefix(prefixIndex))
            prefixIndex = 0
            if byte == Self.prefix[0] { prefixIndex = 1; return }
        }
        plain.append(byte)
    }

    private func appendControl(_ byte: UInt8) {
        guard !draining else { return }
        guard control.count < Self.maxEncodedBytes + Self.maxHeaderBytes else {
            draining = true
            control.removeAll()
            multipart = nil
            return
        }
        control.append(byte)
    }

    private func finish(terminator: [UInt8]) {
        if !draining && !handleControl(control) {
            plain.append(contentsOf: Self.prefix)
            plain.append(contentsOf: control)
            plain.append(contentsOf: terminator)
        }
        control.removeAll(keepingCapacity: true)
        capturing = false
        pendingEscape = false
        draining = false
    }

    private func handleControl(_ bytes: [UInt8]) -> Bool {
        if let remainder = remainder(bytes, after: "File=") {
            guard let separator = remainder.firstIndex(of: 0x3a), separator <= Self.maxHeaderBytes else { return true }
            guard let options = parseOptions(Array(remainder[..<separator])) else { return true }
            complete(options: options, encoded: Array(remainder[remainder.index(after: separator)...]))
            return true
        }
        if let options = remainder(bytes, after: "MultipartFile=").flatMap(parseOptions) {
            multipart = (options, [])
            return true
        }
        if let part = remainder(bytes, after: "FilePart=") {
            guard var current = multipart, current.encoded.count <= Self.maxEncodedBytes - part.count else { multipart = nil; return true }
            current.encoded.append(contentsOf: part)
            multipart = current
            return true
        }
        if bytes == Array("FileEnd".utf8) {
            if let multipart { complete(options: multipart.options, encoded: multipart.encoded) }
            multipart = nil
            return true
        }
        return false
    }

    private func complete(options: [String: String], encoded: [UInt8]) {
        guard options["inline"] == "1" else { return }
        let declared = options["size"].flatMap(Int.init)
        if let declared, !(0...Self.maxImageBytes).contains(declared) { return }
        let compact = encoded.filter { $0 != 0x0a && $0 != 0x0d }
        guard compact.count <= Self.maxEncodedBytes,
              compact.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47 || byte == 61
              }),
              let data = Data(base64Encoded: Data(compact)),
              data.count <= Self.maxImageBytes,
              declared == nil || declared == data.count else { return }
        onImage(ItermInlineImage(options: options, data: data))
    }

    private func parseOptions(_ bytes: [UInt8]) -> [String: String]? {
        guard bytes.count <= Self.maxHeaderBytes, let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        if text.isEmpty { return [:] }
        var options: [String: String] = [:]
        for argument in text.split(separator: ";", omittingEmptySubsequences: false) {
            guard let equals = argument.firstIndex(of: "=") else { return nil }
            let key = String(argument[..<equals])
            guard !key.isEmpty, Self.supportedOptions.contains(key), options[key] == nil else { return nil }
            options[key] = String(argument[argument.index(after: equals)...])
        }
        return options
    }

    private func remainder(_ bytes: [UInt8], after prefix: String) -> [UInt8]? {
        let prefixBytes = Array(prefix.utf8)
        guard bytes.starts(with: prefixBytes) else { return nil }
        return Array(bytes.dropFirst(prefixBytes.count))
    }

    private func flushPlain() {
        guard !plain.isEmpty else { return }
        onBytes(Data(plain))
        plain.removeAll(keepingCapacity: true)
    }
}
