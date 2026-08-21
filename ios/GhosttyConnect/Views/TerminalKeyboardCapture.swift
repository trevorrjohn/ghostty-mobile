import SwiftUI
import UIKit

enum TerminalInputEncoder {
    static func encode(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
    }

    static let backspace = "\u{7f}"
}

struct TerminalKeyboardCapture: UIViewRepresentable {
    @Binding var isFocused: Bool
    let onInput: (TerminalInputEvent) -> Void

    func makeUIView(context: Context) -> TerminalKeyboardInputView {
        let view = TerminalKeyboardInputView()
        view.onInput = onInput
        view.onFocusChange = { isFocused = $0 }
        return view
    }

    func updateUIView(_ view: TerminalKeyboardInputView, context: Context) {
        view.onInput = onInput
        view.onFocusChange = { isFocused = $0 }
        guard view.isFirstResponder != isFocused else { return }
        DispatchQueue.main.async {
            if isFocused { _ = view.becomeFirstResponder() }
            else { _ = view.resignFirstResponder() }
        }
    }
}

final class TerminalKeyboardInputView: UIView, UIKeyInput {
    var onInput: ((TerminalInputEvent) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    func insertText(_ text: String) {
        onInput?(.text(TerminalInputEncoder.encode(text)))
    }

    func deleteBackward() {
        onInput?(.key(.backspace))
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  let inputEvent = Self.event(
                    input: key.charactersIgnoringModifiers,
                    flags: key.modifierFlags
                  ) else {
                unhandled.insert(press)
                continue
            }
            onInput?(inputEvent)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    static func event(input: String, flags: UIKeyModifierFlags) -> TerminalInputEvent? {
        guard !flags.contains(.command) else { return nil }
        let modifiers = TerminalKeyModifiers(flags)
        if let key = namedKey(input) { return .key(key, modifiers: modifiers) }
        guard let actionKey = characterKey(input) else { return nil }
        return .key(
            actionKey.terminalKey,
            text: actionKey.text(shifted: modifiers.contains(.shift)),
            modifiers: modifiers
        )
    }

    private static func namedKey(_ input: String) -> TerminalKey? {
        switch input {
        case UIKeyCommand.inputEscape: .escape
        case "\t": .tab
        case "\r": .enter
        case "\u{8}": .backspace
        case UIKeyCommand.inputDelete: .delete
        case UIKeyCommand.inputHome: .home
        case UIKeyCommand.inputEnd: .end
        case UIKeyCommand.inputPageUp: .pageUp
        case UIKeyCommand.inputPageDown: .pageDown
        case UIKeyCommand.inputUpArrow: .up
        case UIKeyCommand.inputDownArrow: .down
        case UIKeyCommand.inputLeftArrow: .left
        case UIKeyCommand.inputRightArrow: .right
        case UIKeyCommand.f1: .function(1)
        case UIKeyCommand.f2: .function(2)
        case UIKeyCommand.f3: .function(3)
        case UIKeyCommand.f4: .function(4)
        case UIKeyCommand.f5: .function(5)
        case UIKeyCommand.f6: .function(6)
        case UIKeyCommand.f7: .function(7)
        case UIKeyCommand.f8: .function(8)
        case UIKeyCommand.f9: .function(9)
        case UIKeyCommand.f10: .function(10)
        case UIKeyCommand.f11: .function(11)
        case UIKeyCommand.f12: .function(12)
        default: nil
        }
    }

    private static func characterKey(_ input: String) -> KeyboardActionKey? {
        if input.count == 1,
           input.lowercased().first?.isLetter == true,
           let letter = KeyboardActionKey(rawValue: input.lowercased()) {
            return letter
        }
        let digits: [String: KeyboardActionKey] = [
            "0": .zero, "1": .one, "2": .two, "3": .three, "4": .four,
            "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine,
        ]
        return input == " " ? .space : digits[input]
    }
}

private extension TerminalKeyModifiers {
    init(_ flags: UIKeyModifierFlags) {
        var modifiers: TerminalKeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.alt) }
        self = modifiers
    }
}
