import SwiftUI

struct NumericStepperField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100_000
    var step: Double = 1
    var suffix: String = ""
    var format: String? = nil
    var info: String? = nil

    @State private var text: String = ""
    @State private var isEditing = false
    @State private var showInfo = false

    private var resolvedFormat: String {
        if let format { return format }
        return step.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%g"
    }

    var body: some View {
        HStack {
            Text(title)
            if let info {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("About \(title)")
                .popover(isPresented: $showInfo) {
                    Text(info)
                        .font(.subheadline)
                        .padding()
                        .frame(maxWidth: 280)
                        .presentationCompactAdaptation(.popover)
                }
            }
            Spacer()
            DecimalPadTextField(
                text: $text,
                showsSignToggle: range.lowerBound < 0,
                onCommit: commitText,
                onEditingChanged: { isEditing = $0 }
            )
            .frame(width: 72, height: 36)
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Stepper("", onIncrement: { adjust(by: step) }, onDecrement: { adjust(by: -step) })
                .labelsHidden()
        }
        .onAppear {
            text = formatted(value)
        }
        .onChange(of: value) { _, newValue in
            guard !isEditing else { return }
            text = formatted(newValue)
        }
        .onDisappear {
            guard isEditing else { return }
            commitText()
        }
    }

    private func formatted(_ number: Double) -> String {
        String(format: resolvedFormat, number)
    }

    private func adjust(by delta: Double) {
        let clamped = min(max(value + delta, range.lowerBound), range.upperBound)
        value = clamped
        text = formatted(clamped)
    }

    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            text = formatted(value)
            return
        }
        let negative = range.lowerBound < 0 && trimmed.hasPrefix("-")
        let sanitized = trimmed.filter { "0123456789.".contains($0) }
        guard let parsed = Double(sanitized) else {
            text = formatted(value)
            return
        }
        let signed = negative ? -parsed : parsed
        let clamped = min(max(signed, range.lowerBound), range.upperBound)
        value = clamped
        text = formatted(clamped)
    }
}

struct OptionalNumericStepperField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = "0"
    var suffix: String = ""
    var step: Double = 1

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            DecimalPadTextField(text: $text, placeholder: placeholder, onCommit: normalizeText)
                .frame(width: 80, height: 36)
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Stepper("", onIncrement: { adjust(by: step) }, onDecrement: { adjust(by: -step) })
                .labelsHidden()
        }
    }

    private func currentValue() -> Double {
        parseDecimal(text) ?? 0
    }

    private func adjust(by delta: Double) {
        let next = max(0, currentValue() + delta)
        text = next == 0 ? "" : String(format: "%g", next)
    }

    private func normalizeText() {
        guard let parsed = parseDecimal(text) else { return }
        text = parsed == 0 ? "" : String(format: "%g", parsed)
    }

    private func parseDecimal(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let sanitized = trimmed.filter { "0123456789.".contains($0) }
        guard !sanitized.isEmpty, sanitized != "." else { return nil }
        return Double(sanitized)
    }
}
