import SwiftUI
import SwiftData

struct WorkoutSettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var healthKit: HealthKitService

    @State private var showTemplates = false
    @State private var showMyExercises = false

    private var settings: WorkoutSettings {
        WorkoutService.settings(context: context)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if healthKit.isAvailable {
                        LabeledContent("HealthKit Write Access") {
                            Text(healthKit.canWrite ? "Authorized" : "Not authorized")
                                .foregroundStyle(healthKit.canWrite ? .green : .secondary)
                        }
                        Button("Authorize HealthKit") {
                            Task { await healthKit.requestWriteAuthorization(context: context) }
                        }
                        if let message = healthKit.lastSyncMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("HealthKit is not available on this device.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("HealthKit")
                } footer: {
                    Text(HealthKitCopy.workoutWriteDescription)
                }

                Section("Calorie Estimation") {
                    Stepper(value: Binding(
                        get: { settings.defaultSecondsPerSet },
                        set: { settings.defaultSecondsPerSet = $0; save() }
                    ), in: 30...180, step: 5) {
                        Text("Seconds per set: \(settings.defaultSecondsPerSet)")
                    }
                    Stepper(value: Binding(
                        get: { settings.defaultStrengthMET },
                        set: { settings.defaultStrengthMET = $0; save() }
                    ), in: 3...8, step: 0.5) {
                        Text("Default strength MET: \(settings.defaultStrengthMET, format: .number.precision(.fractionLength(1)))")
                    }
                }

                Section("Tennis Step Estimates") {
                    Stepper(value: Binding(
                        get: { settings.tennisSinglesStepsPerMin },
                        set: { settings.tennisSinglesStepsPerMin = $0; save() }
                    ), in: 50...200, step: 5) {
                        Text("Singles: \(Int(settings.tennisSinglesStepsPerMin)) steps/min")
                    }
                    Stepper(value: Binding(
                        get: { settings.tennisDoublesStepsPerMin },
                        set: { settings.tennisDoublesStepsPerMin = $0; save() }
                    ), in: 30...120, step: 5) {
                        Text("Doubles: \(Int(settings.tennisDoublesStepsPerMin)) steps/min")
                    }
                }

                Section("Treadmill") {
                    Stepper(value: Binding(
                        get: { settings.strideLengthFeet },
                        set: { settings.strideLengthFeet = $0; save() }
                    ), in: 1.5...4.0, step: 0.1) {
                        Text("Stride length: \(settings.strideLengthFeet, format: .number.precision(.fractionLength(1))) ft")
                    }
                }

                Section("Templates & Exercises") {
                    Button("Manage Workout Templates") { showTemplates = true }
                    Button("My Exercises") { showMyExercises = true }
                }
            }
            .navigationTitle("Workout Settings")
            .onAppear { healthKit.refreshWriteAuthorization() }
            .sheet(isPresented: $showTemplates) {
                WorkoutTemplateListView()
            }
            .sheet(isPresented: $showMyExercises) {
                MyExercisesListView()
            }
        }
    }

    private func save() {
        try? context.save()
    }
}

struct MyExercisesListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var editingExercise: Exercise?

    private var exercises: [Exercise] {
        WorkoutService.allExercises(context: context)
    }

    var body: some View {
        NavigationStack {
            List {
                if exercises.isEmpty {
                    ContentUnavailableView(
                        "No Exercises",
                        systemImage: "dumbbell",
                        description: Text("Exercises are cached when you search wger or create custom ones.")
                    )
                } else {
                    ForEach(exercises, id: \.id) { exercise in
                        Button {
                            editingExercise = exercise
                        } label: {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(exercise.name)
                                        .foregroundStyle(.primary)
                                    if exercise.isCustom {
                                        Text("Custom")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.orange.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                }
                                HStack {
                                    if let category = exercise.categoryName {
                                        Text(category)
                                    }
                                    if let met = exercise.effectiveMET {
                                        Text("MET \(met, format: .number.precision(.fractionLength(1)))")
                                    } else {
                                        Text("No calorie data")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("My Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingExercise) { exercise in
                ExerciseEditView(exercise: exercise)
            }
        }
    }
}

struct ExerciseEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Bindable var exercise: Exercise
    @State private var metText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    if exercise.isCustom {
                        TextField("Name", text: $exercise.name)
                        TextField("Category", text: Binding(
                            get: { exercise.categoryName ?? "" },
                            set: { exercise.categoryName = $0.isEmpty ? nil : $0 }
                        ))
                    } else {
                        LabeledContent("Name", value: exercise.name)
                        if let category = exercise.categoryName {
                            LabeledContent("Category", value: category)
                        }
                    }
                }
                Section("MET (Calorie Burn)") {
                    TextField("MET value", text: $metText)
                        .keyboardType(.decimalPad)
                    Text("Leave blank to use category default or exclude from calorie calculations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let met = exercise.metValue {
                    metText = met.formatted(.number.precision(.fractionLength(1)))
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        exercise.metValue = metText.isEmpty ? nil : Double(metText)
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

extension Exercise: Identifiable {}
