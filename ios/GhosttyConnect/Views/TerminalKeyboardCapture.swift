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
    let onInput: (String) -> Void

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
    var onInput: ((String) -> Void)?
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
        onInput?(TerminalInputEncoder.encode(text))
    }

    func deleteBackward() {
        onInput?(TerminalInputEncoder.backspace)
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

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(sendEscape)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(sendUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(sendDown)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(sendLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(sendRight)),
            UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(sendControlC)),
            UIKeyCommand(input: "d", modifierFlags: .control, action: #selector(sendControlD)),
            UIKeyCommand(input: "z", modifierFlags: .control, action: #selector(sendControlZ)),
        ]
    }

    @objc private func sendEscape() { onInput?("\u{1b}") }
    @objc private func sendUp() { onInput?("\u{1b}[A") }
    @objc private func sendDown() { onInput?("\u{1b}[B") }
    @objc private func sendLeft() { onInput?("\u{1b}[D") }
    @objc private func sendRight() { onInput?("\u{1b}[C") }
    @objc private func sendControlC() { onInput?("\u{03}") }
    @objc private func sendControlD() { onInput?("\u{04}") }
    @objc private func sendControlZ() { onInput?("\u{1a}") }
}
