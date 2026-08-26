import Foundation

enum ContextualSelectionKind: Equatable {
    case link
    case path
    case output
    case word
}

struct ContextualSelection: Equatable {
    let kind: ContextualSelectionKind
    let value: String

    init(kind: ContextualSelectionKind, value: String = "") {
        self.kind = kind
        self.value = value
    }

    var copyLabel: String {
        switch kind {
        case .link: "Copy Link"
        case .path: "Copy Path"
        case .output: "Copy Block"
        case .word: "Copy"
        }
    }

    static func safeWebURL(_ value: String) -> URL? {
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: value),
              url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

struct TerminalTokenMatch: Equatable {
    let kind: ContextualSelectionKind
    let text: String
    let startColumn: Int
    let endColumn: Int
}

enum TerminalTokenMatcher {
    private static let maximumTokenBytes = 1024
    private static let leadingPunctuation = Set<Character>("([{<\"'")
    private static let trailingPunctuation = Set<Character>(")]}>,;.?!\"'")

    static func match(snapshot: TerminalSnapshot, column: Int, row: Int) -> TerminalTokenMatch? {
        guard row >= 0, row < snapshot.rows, column >= 0, column < snapshot.columns else { return nil }
        let offset = row * snapshot.columns
        let cells = snapshot.cells[offset..<(offset + snapshot.columns)].map { cell in
            cell.invisible ? "" : cell.text
        }
        return match(cells: cells, column: column)
    }

    static func match(cells: [String], column: Int) -> TerminalTokenMatch? {
        guard cells.indices.contains(column), !cells[column].allSatisfy(\.isWhitespace) else { return nil }
        var start = column
        var end = column
        while start > 0, !cells[start - 1].allSatisfy(\.isWhitespace) { start -= 1 }
        while end + 1 < cells.count, !cells[end + 1].allSatisfy(\.isWhitespace) { end += 1 }
        while start <= end, cells[start].first.map(leadingPunctuation.contains) == true { start += 1 }
        while end >= start, cells[end].last.map(trailingPunctuation.contains) == true { end -= 1 }
        guard start <= end, (start...end).contains(column) else { return nil }

        let text = cells[start...end].joined()
        guard !text.isEmpty, text.utf8.count <= maximumTokenBytes else { return nil }
        let lowercased = text.lowercased()
        let kind: ContextualSelectionKind
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            kind = .link
        } else if !text.contains("://") && (
            text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") ||
                text.hasPrefix("../") || text.contains("/")
        ) {
            kind = .path
        } else {
            return nil
        }
        return TerminalTokenMatch(kind: kind, text: text, startColumn: start, endColumn: end)
    }
}
