import Foundation

enum KeyboardModifier: String, Codable, CaseIterable, Hashable {
    case control
    case alt
    case shift
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

struct KeyboardBarConfig: Codable, Equatable {
    static let currentVersion = 1
    static let maximumItems = KeyboardBarItemID.allCases.count
    static let defaults = KeyboardBarConfig(enabled: true, itemIDs: KeyboardBarItemID.allCases)

    var enabled: Bool
    var itemIDs: [KeyboardBarItemID]

    init(enabled: Bool = true, itemIDs: [KeyboardBarItemID] = KeyboardBarItemID.allCases) {
        self.enabled = enabled
        self.itemIDs = Self.normalized(itemIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case enabled
        case itemIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported keyboard bar configuration version."
            )
        }
        enabled = try container.decode(Bool.self, forKey: .enabled)
        let rawIDs = try container.decode([String].self, forKey: .itemIDs)
        itemIDs = Self.normalized(rawIDs.compactMap(KeyboardBarItemID.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(itemIDs.map(\.rawValue), forKey: .itemIDs)
    }

    private static func normalized(_ ids: [KeyboardBarItemID]) -> [KeyboardBarItemID] {
        var seen: Set<KeyboardBarItemID> = []
        return ids.filter { seen.insert($0).inserted }.prefix(maximumItems).map { $0 }
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
