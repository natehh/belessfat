import SwiftUI
import SwiftData

struct WorkoutTemplateListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showNewTemplate = false
    @State private var editingTemplate: WorkoutTemplate?

    private var templates: [WorkoutTemplate] {
        WorkoutService.templates(context: context)
    }

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No Templates",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Create a workout template to reuse exercises.")
                    )
                } else {
                    ForEach(templates, id: \.id) { template in
                        Button {
                            editingTemplate = template
                        } label: {
                            VStack(alignment: .leading) {
                                Text(template.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("\(template.exercises.count) exercises")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            WorkoutService.deleteTemplate(templates[index], context: context)
                        }
                    }
                }
            }
            .navigationTitle("Workout Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewTemplate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Template", isPresented: $showNewTemplate) {
                TextField("Template name", text: Binding(
                    get: { newTemplateName },
                    set: { newTemplateName = $0 }
                ))
                Button("Create") { createTemplate() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $editingTemplate) { template in
                WorkoutTemplateEditView(template: template)
            }
        }
    }

    @State private var newTemplateName = ""

    private func createTemplate() {
        let name = newTemplateName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let template = WorkoutService.createTemplate(name: name, context: context)
        newTemplateName = ""
        editingTemplate = template
    }
}

struct WorkoutTemplateEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Bindable var template: WorkoutTemplate
    @State private var showExerciseSearch = false
    @State private var showCustomExercise = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $template.name)
                }
                Section("Exercises") {
                    ForEach(template.sortedExercises, id: \.id) { item in
                        HStack {
                            Text(item.exercise?.name ?? "Unknown")
                            Spacer()
                            if let met = item.exercise?.effectiveMET {
                                Text("MET \(met, format: .number.precision(.fractionLength(1)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        WorkoutService.reorderTemplateExercises(
                            in: template,
                            fromOffsets: from,
                            toOffset: to,
                            context: context
                        )
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            WorkoutService.removeTemplateExercise(template.sortedExercises[index], context: context)
                        }
                    }
                    Button("Add from Catalog") { showExerciseSearch = true }
                    Button("Create Custom Exercise") { showCustomExercise = true }
                }
            }
            .navigationTitle("Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showExerciseSearch) {
                ExerciseSearchView { exercise in
                    WorkoutService.addExercise(exercise, to: template, context: context)
                }
            }
            .sheet(isPresented: $showCustomExercise) {
                CustomExerciseFormView { exercise in
                    WorkoutService.addExercise(exercise, to: template, context: context)
                }
            }
        }
    }
}

extension WorkoutTemplate: Identifiable {}
