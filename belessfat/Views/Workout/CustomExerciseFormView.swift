import SwiftUI
import SwiftData

struct CustomExerciseFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let onSave: (Exercise) -> Void

    @State private var name = ""
    @State private var categoryName = ""
    @State private var includeMET = false
    @State private var metText = "5.0"

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Name", text: $name)
                    TextField("Category (optional)", text: $categoryName)
                }
                Section("Calorie Metadata") {
                    Toggle("Include MET value", isOn: $includeMET)
                    if includeMET {
                        TextField("MET", text: $metText)
                            .keyboardType(.decimalPad)
                        Text("MET × body weight × duration determines calories burned. Without MET, this exercise won't count toward workout calories.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Exercise can be logged but won't contribute to calorie burn.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Custom Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let met = includeMET ? Double(metText) : nil
        let exercise = WorkoutService.createCustomExercise(
            name: name,
            categoryName: categoryName.isEmpty ? nil : categoryName,
            metValue: met,
            context: context
        )
        onSave(exercise)
        dismiss()
    }
}
