import SwiftUI
import UIKit

/// UITextField wrapper with a reliable Done button above the decimal pad.
struct DecimalPadTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var showsSignToggle: Bool = false
    var onCommit: (() -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.keyboardType = .decimalPad
        field.textAlignment = .right
        field.placeholder = placeholder
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged), for: .editingChanged)

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        var items: [UIBarButtonItem] = []
        if showsSignToggle {
            items.append(UIBarButtonItem(
                title: "±",
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.toggleSign)
            ))
        }
        items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
        items.append(UIBarButtonItem(
            title: "Done",
            style: .done,
            target: context.coordinator,
            action: #selector(Coordinator.doneTapped)
        ))
        toolbar.items = items
        field.inputAccessoryView = toolbar
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.field = uiView
        if !uiView.isFirstResponder, uiView.text != text {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DecimalPadTextField
        weak var field: UITextField?

        init(parent: DecimalPadTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        @objc func toggleSign() {
            let current = (field?.text ?? parent.text).trimmingCharacters(in: .whitespaces)
            let next: String
            if current.hasPrefix("-") {
                next = String(current.dropFirst())
            } else if current.hasPrefix("+") {
                next = "-" + current.dropFirst()
            } else if current.isEmpty {
                next = "-"
            } else {
                next = "-" + current
            }
            field?.text = next
            parent.text = next
        }

        @objc func doneTapped() {
            field?.resignFirstResponder()
            parent.onCommit?()
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onEditingChanged?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.text = textField.text ?? ""
            parent.onEditingChanged?(false)
            parent.onCommit?()
        }
    }
}

// Legacy helper for screens that still use SwiftUI TextField + .decimalPad
extension View {
    func keyboardDismissToolbar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            }
        }
    }
}
