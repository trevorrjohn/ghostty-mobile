import Foundation

final class TmuxPassthroughParser {
    private static let prefix = Array("\u{1b}Ptmux;".utf8)
    private static let maxBytes = 7 * 1_024 * 1_024
    private let onBytes: (Data) -> Void
    private var plain: [UInt8] = []
    private var passthrough: [UInt8] = []
    private var prefixIndex = 0
    private var capturing = false
    private var pendingEscape = false
    private var draining = false

    init(onBytes: @escaping (Data) -> Void) { self.onBytes = onBytes }

    func feed(_ data: Data) {
        data.forEach(accept)
        flushPlain()
    }

    private func accept(_ byte: UInt8) {
        if capturing {
            if pendingEscape {
                pendingEscape = false
                if byte == 0x1b { append(0x1b) }
                else if byte == 0x5c { finish() }
                else { append(0x1b); append(byte) }
            } else if byte == 0x1b { pendingEscape = true }
            else { append(byte) }
            return
        }
        if byte == Self.prefix[prefixIndex] {
            prefixIndex += 1
            if prefixIndex == Self.prefix.count {
                flushPlain()
                prefixIndex = 0
                capturing = true
                passthrough.removeAll(keepingCapacity: true)
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

    private func append(_ byte: UInt8) {
        guard !draining else { return }
        guard passthrough.count < Self.maxBytes else { passthrough.removeAll(); draining = true; return }
        passthrough.append(byte)
    }

    private func finish() {
        if !draining { onBytes(Data(passthrough)) }
        passthrough.removeAll(keepingCapacity: true)
        capturing = false
        draining = false
    }

    private func flushPlain() {
        guard !plain.isEmpty else { return }
        onBytes(Data(plain))
        plain.removeAll(keepingCapacity: true)
    }
}
