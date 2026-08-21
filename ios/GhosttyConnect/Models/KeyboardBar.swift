import Foundation

enum KeyboardModifier: String, Codable, CaseIterable, Hashable {
    case control
    case alt
    case shift

    var label: String {
        switch self {
        case .control: "Ctrl"
        case .alt: "Alt"
        case .shift: "Shift"
        }
    }
}

enum KeyboardBarItemID: String, Codable, CaseIterable, Identifiable {
    case escape
    case control
    case alt
    case tab
    case shift
    case up
    case down
    case left
    case right

    var id: Self { self }

    var label: String {
        switch self {
        case .escape: "ESC"
        case .control: "CTRL"
        case .alt: "ALT"
        case .tab: "TAB"
        case .shift: "SHIFT"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .control: "Control"
        case .alt: "Alt"
        case .tab: "Tab"
        case .shift: "Shift"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .left: "Left arrow"
        case .right: "Right arrow"
        }
    }

    var modifier: KeyboardModifier? {
        switch self {
        case .control: .control
        case .alt: .alt
        case .shift: .shift
        default: nil
        }
    }

    var key: TerminalKey? {
        switch self {
        case .escape: .escape
        case .tab: .tab
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .control, .alt, .shift: nil
        }
    }
}

enum KeyboardActionKey: String, Codable, CaseIterable, Identifiable {
    case escape, tab, backspace, up, down, left, right
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine
    case space

    var id: Self { self }

    var label: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .backspace: "Backspace"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .left: "Left arrow"
        case .right: "Right arrow"
        case .space: "Space"
        case .zero: "0"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        default: rawValue.uppercased()
        }
    }

    var terminalKey: TerminalKey {
        switch self {
        case .escape: .escape
        case .tab: .tab
        case .backspace: .backspace
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .space: .character(" ")
        case .zero: .character("0")
        case .one: .character("1")
        case .two: .character("2")
        case .three: .character("3")
        case .four: .character("4")
        case .five: .character("5")
        case .six: .character("6")
        case .seven: .character("7")
        case .eight: .character("8")
        case .nine: .character("9")
        default: .character(rawValue.uppercased())
        }
    }

    func text(shifted: Bool) -> String {
        guard case .character(let value) = terminalKey else { return "" }
        guard shifted else { return value.lowercased() }
        switch self {
        case .zero: return ")"
        case .one: return "!"
        case .two: return "@"
        case .three: return "#"
        case .four: return "$"
        case .five: return "%"
        case .six: return "^"
        case .seven: return "&"
        case .eight: return "*"
        case .nine: return "("
        default: return value.uppercased()
        }
    }
}

struct KeyboardAction: Codable, Equatable, Identifiable {
    static let maximumLabelBytes = 48

    var id: UUID
    var label: String
    var key: KeyboardActionKey
    var modifiers: Set<KeyboardModifier>

    init(
        id: UUID = UUID(),
        label: String,
        key: KeyboardActionKey,
        modifiers: Set<KeyboardModifier>
    ) {
        self.id = id
        self.label = Self.normalizedLabel(label)
        self.key = key
        self.modifiers = modifiers
    }

    var isValid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !modifiers.isEmpty
    }

    var event: TerminalInputEvent {
        .key(
            key.terminalKey,
            text: key.text(shifted: modifiers.contains(.shift)),
            modifiers: TerminalKeyModifiers(modifiers)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case key
        case modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            key: try container.decode(KeyboardActionKey.self, forKey: .key),
            modifiers: try Self.decodeModifiers(from: container)
        )
    }

    private static func normalizedLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = ""
        for scalar in trimmed.unicodeScalars {
            let value = String(scalar)
            guard output.utf8.count + value.utf8.count <= maximumLabelBytes else { break }
            output.append(contentsOf: value)
        }
        return output
    }

    private static func decodeModifiers(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Set<KeyboardModifier> {
        var values = try container.nestedUnkeyedContainer(forKey: .modifiers)
        var modifiers: Set<KeyboardModifier> = []
        var count = 0
        while !values.isAtEnd {
            guard count < KeyboardModifier.allCases.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modifiers,
                    in: container,
                    debugDescription: "Too many keyboard modifiers."
                )
            }
            modifiers.insert(try values.decode(KeyboardModifier.self))
            count += 1
        }
        return modifiers
    }
}

enum KeyboardBarItem: Hashable, Identifiable {
    case builtIn(KeyboardBarItemID)
    case action(UUID)

    var id: String {
        switch self {
        case .builtIn(let item): "built-in:\(item.rawValue)"
        case .action(let id): "action:\(id.uuidString.lowercased())"
        }
    }
}

extension KeyboardBarItem: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value.hasPrefix("built-in:"),
           let item = KeyboardBarItemID(rawValue: String(value.dropFirst("built-in:".count))) {
            self = .builtIn(item)
        } else if value.hasPrefix("action:"),
                  let id = UUID(uuidString: String(value.dropFirst("action:".count))) {
            self = .action(id)
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown keyboard bar item."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

struct KeyboardBarConfig: Codable, Equatable {
    static let currentVersion = 2
    static let maximumEncodedBytes = 16_384
    static let maximumActions = 16
    static let maximumItems = KeyboardBarItemID.allCases.count + maximumActions
    static let defaults = KeyboardBarConfig(
        enabled: true,
        items: KeyboardBarItemID.allCases.map(KeyboardBarItem.builtIn)
    )

    var enabled: Bool
    private(set) var items: [KeyboardBarItem]
    private(set) var actions: [KeyboardAction]

    init(
        enabled: Bool = true,
        items: [KeyboardBarItem] = KeyboardBarItemID.allCases.map(KeyboardBarItem.builtIn),
        actions: [KeyboardAction] = []
    ) {
        self.enabled = enabled
        self.actions = Self.normalizedActions(actions)
        self.items = Self.normalizedItems(items, actionIDs: Set(self.actions.map(\.id)))
    }

    func action(id: UUID) -> KeyboardAction? { actions.first { $0.id == id } }

    mutating func moveItems(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    mutating func removeItems(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    mutating func append(_ item: KeyboardBarItem) {
        guard items.count < Self.maximumItems, !items.contains(item) else { return }
        switch item {
        case .builtIn:
            items.append(item)
        case .action(let id):
            if action(id: id) != nil { items.append(item) }
        }
    }

    @discardableResult
    mutating func saveAction(_ action: KeyboardAction, addToBar: Bool) -> Bool {
        let normalized = KeyboardAction(
            id: action.id,
            label: action.label,
            key: action.key,
            modifiers: action.modifiers
        )
        guard normalized.isValid else { return false }
        if let index = actions.firstIndex(where: { $0.id == normalized.id }) {
            actions[index] = normalized
        } else if actions.count < Self.maximumActions {
            actions.append(normalized)
        } else {
            return false
        }
        if addToBar { append(.action(normalized.id)) }
        return true
    }

    mutating func deleteAction(id: UUID) {
        actions.removeAll { $0.id == id }
        items.removeAll { $0 == .action(id) }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case enabled
        case itemIDs
        case items
        case actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        switch version {
        case 1:
            var ids: [String] = []
            var idContainer = try container.nestedUnkeyedContainer(forKey: .itemIDs)
            while !idContainer.isAtEnd {
                guard ids.count < KeyboardBarItemID.allCases.count else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .itemIDs,
                        in: container,
                        debugDescription: "Too many keyboard bar items."
                    )
                }
                ids.append(try idContainer.decode(String.self))
            }
            actions = []
            items = Self.normalizedItems(
                ids.compactMap(KeyboardBarItemID.init(rawValue:)).map(KeyboardBarItem.builtIn),
                actionIDs: []
            )
        case Self.currentVersion:
            var decodedActions: [KeyboardAction] = []
            var actionContainer = try container.nestedUnkeyedContainer(forKey: .actions)
            while !actionContainer.isAtEnd {
                guard decodedActions.count < Self.maximumActions else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .actions,
                        in: container,
                        debugDescription: "Too many custom keyboard actions."
                    )
                }
                decodedActions.append(try actionContainer.decode(KeyboardAction.self))
            }
            actions = Self.normalizedActions(decodedActions)
            var decodedItems: [KeyboardBarItem] = []
            var itemContainer = try container.nestedUnkeyedContainer(forKey: .items)
            while !itemContainer.isAtEnd {
                guard decodedItems.count < Self.maximumItems else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .items,
                        in: container,
                        debugDescription: "Too many keyboard bar items."
                    )
                }
                decodedItems.append(try itemContainer.decode(KeyboardBarItem.self))
            }
            items = Self.normalizedItems(
                decodedItems,
                actionIDs: Set(actions.map(\.id))
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported keyboard bar configuration version."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(items, forKey: .items)
        try container.encode(actions, forKey: .actions)
    }

    private static func normalizedActions(_ actions: [KeyboardAction]) -> [KeyboardAction] {
        var seen: Set<UUID> = []
        return actions
            .filter { $0.isValid && seen.insert($0.id).inserted }
            .prefix(maximumActions)
            .map { $0 }
    }

    private static func normalizedItems(
        _ items: [KeyboardBarItem],
        actionIDs: Set<UUID>
    ) -> [KeyboardBarItem] {
        var seen: Set<KeyboardBarItem> = []
        return items.filter { item in
            guard seen.insert(item).inserted else { return false }
            if case .action(let id) = item { return actionIDs.contains(id) }
            return true
        }
        .prefix(maximumItems)
        .map { $0 }
    }
}

struct KeyboardBarRuntimeState: Equatable {
    private(set) var activeModifiers: Set<KeyboardModifier> = []

    mutating func toggle(_ modifier: KeyboardModifier) {
        if activeModifiers.contains(modifier) { activeModifiers.remove(modifier) }
        else { activeModifiers.insert(modifier) }
    }

    mutating func consume() {
        activeModifiers.removeAll()
    }
}
