import SwiftUI
import UIKit

@MainActor final class AmountInput {
    weak var field: UITextField?

    func press(_ key: String) {
        guard let field else { return }
        field.insertText(key)
        field.sendActions(for: .editingChanged)
    }

    func erase() {
        guard let field else { return }
        field.deleteBackward()
        field.sendActions(for: .editingChanged)
    }
}

private final class PasteAmountField: UITextField {
    var pasteText: ((String) -> Void)?

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { pasteText?(text) }
    }
}

struct AmountField: UIViewRepresentable {
    let id: UUID
    let index: Int
    let value: String
    let invalid: Bool
    let focused: UUID?
    let input: AmountInput
    let onValue: (String) -> Void
    let onFocus: (UUID) -> Void
    let onPaste: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = PasteAmountField()
        field.delegate = context.coordinator
        field.textAlignment = .right
        field.inputView = UIView(frame: .zero)
        field.adjustsFontSizeToFitWidth = true
        field.minimumFontSize = 12
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        (field as? PasteAmountField)?.pasteText = onPaste
        if field.text != value {
            field.text = value
            if field.isFirstResponder {
                let end = field.endOfDocument
                field.selectedTextRange = field.textRange(from: end, to: end)
            }
        }
        field.placeholder = "0.00"
        field.accessibilityLabel = L.f("amountRow", index + 1)
        field.accessibilityIdentifier = "row.amount.\(index)"
        field.textColor = invalid ? .systemRed : .label
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedDigitSystemFont(ofSize: 19, weight: .semibold))
        let coordinator = context.coordinator
        if focused == id, !field.isFirstResponder {
            DispatchQueue.main.async {
                guard coordinator.parent.focused == coordinator.parent.id, field.window != nil else { return }
                field.becomeFirstResponder()
            }
        } else if focused != id, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AmountField

        init(_ parent: AmountField) { self.parent = parent }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.input.field = textField
            parent.onFocus(parent.id)
            DispatchQueue.main.async {
                guard textField.isFirstResponder else { return }
                let end = textField.endOfDocument
                textField.selectedTextRange = textField.textRange(from: end, to: end)
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.input.field === textField { parent.input.field = nil }
        }

        @objc func changed(_ sender: UITextField) {
            parent.onValue(sender.text ?? "")
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard let old = textField.text, let span = Range(range, in: old) else { return false }
            let next = old.replacingCharacters(in: span, with: string)
            return !next.contains(where: \.isNewline) && (next.count <= 4096 || next.count < old.count)
        }
    }
}

@MainActor struct AmountKeypad: View {
    let input: AmountInput
    let next: () -> Void
    let done: () -> Void

    private let layout = [["1", "2", "3", "delete"], ["4", "5", "6", "next"],
                          ["7", "8", "9", "done"], ["-", "0", ".", ""]]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(layout.indices, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(layout[row], id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 36).accessibilityHidden(true)
                        } else {
                            button(key)
                        }
                    }
                }
            }
        }
        .padding(7)
        .background(.bar)
    }

    private func button(_ key: String) -> some View {
        Button {
            switch key {
            case "delete": input.erase()
            case "next": next()
            case "done": done()
            default: input.press(key)
            }
        } label: {
            Group {
                switch key {
                case "delete": Image(systemName: "delete.left")
                case "next", "done": Text(L.t(key)).font(.caption.weight(.semibold))
                default: Text(key == "-" ? "−" : key).font(.body.monospacedDigit())
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, minHeight: 39)
            .foregroundStyle(key == "next" ? Color.white : Color.primary)
            .background(key == "next" ? Palette.blue : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key == "delete" ? L.t("backspace") : key == "-" ? L.t("minus") : key == "." ? L.t("decimal") : key == "done" || key == "next" ? L.t(key) : key)
        .accessibilityIdentifier("key." + key)
    }
}
