import Foundation

enum SFTPEntryKind: String, Sendable {
    case file = "File"
    case directory = "Directory"
    case symbolicLink = "Symbolic link"
    case unsupported = "Unsupported entry"
}

struct SFTPEntry: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let kind: SFTPEntryKind
    let size: UInt64?
    let modifiedAt: Date?
    let accessedAt: Date?
    let permissions: UInt32?

    var isSupported: Bool { kind != .unsupported }
}

enum SFTPSort: String, CaseIterable, Identifiable, Sendable {
    case nameAscending
    case nameDescending
    case updatedDescending
    case updatedAscending
    case accessedDescending
    case accessedAscending
    case sizeDescending
    case sizeAscending

    var id: Self { self }

    var label: String {
        switch self {
        case .nameAscending: "Name: A to Z"
        case .nameDescending: "Name: Z to A"
        case .updatedDescending: "Updated: newest first"
        case .updatedAscending: "Updated: oldest first"
        case .accessedDescending: "Accessed: newest first"
        case .accessedAscending: "Accessed: oldest first"
        case .sizeDescending: "Size: largest first"
        case .sizeAscending: "Size: smallest first"
        }
    }
}

struct SFTPDirectory: Sendable {
    let path: String
    let entries: [SFTPEntry]
}

struct SFTPTransfer: Equatable, Sendable {
    enum Direction: Sendable { case upload, download }
    let direction: Direction
    let name: String
    var completed: UInt64
    var total: UInt64?
}

enum SFTPBrowserStatus: Equatable {
    case disconnected
    case connecting
    case verifyingHost
    case loading
    case ready
    case failed(String)
}

enum SFTPBrowserError: LocalizedError {
    case notConnected
    case invalidName
    case unsupportedEntry
    case destinationExists
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notConnected: "The file browser is not connected."
        case .invalidName: "Use a non-empty name without slash, backslash, NUL, . or ..."
        case .unsupportedEntry: "This remote entry type is not supported."
        case .destinationExists: "An entry with that name already exists."
        case .tooLarge: "The remote file exceeds the allowed transfer size."
        }
    }
}

func validRemoteChildName(_ name: String) -> Bool {
    let bytes = name.data(using: .utf8)?.count ?? Int.max
    return !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
        !name.contains("\\") && !name.contains("\0") && bytes <= 255
}

func remoteChildPath(parent: String, name: String) -> String {
    parent == "/" ? "/\(name)" : "\(parent)/\(name)"
}

func sftpEntryKind(name: String, permissions: UInt32?) -> SFTPEntryKind {
    guard validRemoteChildName(name) else { return .unsupported }
    return switch permissions.map({ $0 & 0o170000 }) {
    case 0o100000: .file
    case 0o040000: .directory
    case 0o120000: .symbolicLink
    default: .unsupported
    }
}

func filteredSFTPEntries(
    _ entries: [SFTPEntry],
    query: String,
    sort: SFTPSort,
    showHidden: Bool
) -> [SFTPEntry] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = entries
        .filter { showHidden || !$0.name.hasPrefix(".") }
        .compactMap { entry in fuzzySFTPScore(entry.name, query: needle).map { (entry, $0) } }
    return candidates
        .sorted { leftValue, rightValue in
            let (left, leftScore) = leftValue
            let (right, rightScore) = rightValue
            if left.kind == .directory, right.kind != .directory { return true }
            if left.kind != .directory, right.kind == .directory { return false }
            if !needle.isEmpty, leftScore != rightScore { return leftScore < rightScore }
            let result: ComparisonResult
            switch sort {
            case .nameAscending, .nameDescending:
                result = left.name.localizedCaseInsensitiveCompare(right.name)
            case .updatedDescending, .updatedAscending:
                result = compareOptional(left.modifiedAt, right.modifiedAt)
            case .accessedDescending, .accessedAscending:
                result = compareOptional(left.accessedAt, right.accessedAt)
            case .sizeDescending, .sizeAscending:
                result = compareOptional(left.size, right.size)
            }
            if result == .orderedSame { return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending }
            switch sort {
            case .nameAscending, .updatedAscending, .accessedAscending, .sizeAscending:
                return result == .orderedAscending
            case .nameDescending, .updatedDescending, .accessedDescending, .sizeDescending:
                return result == .orderedDescending
            }
        }
        .map(\.0)
}

private func fuzzySFTPScore(_ candidate: String, query: String) -> Int? {
    let needle = query.lowercased()
    let value = candidate.lowercased()
    guard !needle.isEmpty else { return 0 }
    if value == needle { return 0 }
    if value.hasPrefix(needle) { return 10 + value.count - needle.count }
    if let range = value.range(of: needle) {
        return 100 + value.distance(from: value.startIndex, to: range.lowerBound) * 10 + value.count - needle.count
    }
    var queryIndex = needle.startIndex
    var first: Int?
    var previous: Int?
    var gaps = 0
    for (index, character) in value.enumerated() where queryIndex < needle.endIndex && character == needle[queryIndex] {
        if first == nil { first = index }
        if let previous { gaps += index - previous - 1 }
        previous = index
        queryIndex = needle.index(after: queryIndex)
    }
    guard queryIndex == needle.endIndex, let first else { return nil }
    return 1_000 + first * 10 + gaps * 5 + value.count
}

private func compareOptional<T: Comparable>(_ left: T?, _ right: T?) -> ComparisonResult {
    switch (left, right) {
    case (.none, .none): .orderedSame
    case (.none, .some): .orderedDescending
    case (.some, .none): .orderedAscending
    case (.some(let left), .some(let right)):
        left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }
}
