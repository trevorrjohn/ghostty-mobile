import SwiftUI
import UIKit

/// A transient, cursor-aware draft. It never emits input until the user explicitly sends it.
struct TerminalTextInput: UIViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let insertNewline: Int

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardAppearance = .dark
        view.accessibilityLabel = "Terminal text input"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if context.coordinator.lastInsertion != insertNewline {
            context.coordinator.lastInsertion = insertNewline
            if view.text.utf8.count < 16_384 {
                view.insertText("\n")
            }
        }
        if isFocused && !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isFocused && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(110, max(44, height)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TerminalTextInput
        var lastInsertion: Int

        init(_ parent: TerminalTextInput) {
            self.parent = parent
            lastInsertion = parent.insertNewline
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let candidate = (textView.text as NSString).replacingCharacters(in: range, with: text)
            return candidate.utf8.count <= 16_384
        }
    }
}
