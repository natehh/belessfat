import SwiftUI
import SwiftData
import UIKit

struct AddWorkoutSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var healthKit: HealthKitService

    let date: Date

    @State private var workoutType: WorkoutType = .strength
    @State private var selectedTemplate: WorkoutTemplate?
    @State private var useEmptySession = true
    @State private var syncToHealthKit = true
    @State private var durationMinutes = 45.0
    @State private var workoutEndAt = Date()

    // Cardio fields
    @State private var treadmillSpeed = 3.5
    @State private var treadmillIncline = 0.0

    @State private var createdStrengthSession: WorkoutSession?

    private var templates: [WorkoutTemplate] {
        WorkoutService.templates(context: context)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout Type") {
                    Picker("Type", selection: $workoutType) {
                        ForEach(WorkoutType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                }

                if workoutType == .strength {
                    strengthSection
                } else if workoutType == .treadmill {
                    treadmillSection
                } else {
                    cardioSection
                }

                WorkoutTimeSection(
                    workoutEndAt: $workoutEndAt,
                    durationMinutes: durationMinutes,
                    syncToHealthKit: syncToHealthKit,
                    includesSteps: workoutType != .strength
                )

                Section("HealthKit") {
                    Toggle("Sync to HealthKit", isOn: $syncToHealthKit)
                    if syncToHealthKit {
                        Text(HealthKitCopy.workoutWriteDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { createWorkout() }
                }
            }
            .sheet(item: $createdStrengthSession) { session in
                StrengthWorkoutLogView(session: session, isNew: true, initialWorkoutEndAt: workoutEndAt)
            }
            .onAppear {
                workoutEndAt = WorkoutService.defaultWorkoutEnd(for: date)
            }
        }
    }

    private var strengthSection: some View {
        Group {
            Section("Template") {
                Toggle("Empty Session", isOn: $useEmptySession)
                if !useEmptySession {
                    Picker("Template", selection: $selectedTemplate) {
                        Text("Select…").tag(nil as WorkoutTemplate?)
                        ForEach(templates, id: \.id) { template in
                            Text(template.name).tag(template as WorkoutTemplate?)
                        }
                    }
                }
            }
            Section("Duration") {
                NumericStepperField(
                    title: "Duration",
                    value: $durationMinutes,
                    range: 5...180,
                    step: 5,
                    suffix: "min"
                )
                Text("Used for calorie estimation. You can adjust after logging sets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cardioSection: some View {
        Section("Duration") {
            NumericStepperField(
                title: "Duration",
                value: $durationMinutes,
                range: 5...240,
                step: 5,
                suffix: "min"
            )
        }
    }

    private var treadmillSection: some View {
        Group {
            Section("Treadmill") {
                NumericStepperField(
                    title: "Speed",
                    value: $treadmillSpeed,
                    range: 0.5...12,
                    step: 0.5,
                    suffix: "mph",
                    format: "%.1f"
                )
                NumericStepperField(
                    title: "Duration",
                    value: $durationMinutes,
                    range: 5...240,
                    step: 5,
                    suffix: "min"
                )
                NumericStepperField(
                    title: "Incline",
                    value: $treadmillIncline,
                    range: 0...15,
                    step: 0.5,
                    suffix: "%",
                    format: "%.1f"
                )
            }
            if !syncToHealthKit {
                Section {
                    Text("Steps won't be synced. Use this when your phone is already tracking steps on the treadmill.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func createWorkout() {
        // Resign any active text field before mutating the hierarchy so the keyboard
        // window tears down cleanly instead of hanging when the sheet is dismissed.
        dismissKeyboard()

        switch workoutType {
        case .strength:
            let template = useEmptySession ? nil : selectedTemplate
            let session = WorkoutService.createStrengthSession(
                date: date,
                template: template,
                syncToHealthKit: syncToHealthKit,
                durationMinutes: durationMinutes,
                workoutEndAt: workoutEndAt,
                context: context
            )
            createdStrengthSession = session
        case .tennisSingles, .tennisDoubles, .treadmill:
            let session = WorkoutSession(
                date: date,
                workoutType: workoutType,
                durationMinutes: durationMinutes,
                syncToHealthKit: syncToHealthKit
            )
            if workoutType == .treadmill {
                session.treadmillSpeedMph = treadmillSpeed
                session.treadmillInclinePercent = treadmillIncline
            }
            WorkoutService.applyWorkoutEnd(workoutEndAt, to: session)
            context.insert(session)
            try? context.save()
            Task {
                await WorkoutService.finalizeCardioSession(session, context: context, healthKit: healthKit)
            }
            // Defer dismissal one runloop so the keyboard finishes resigning first.
            DispatchQueue.main.async { dismiss() }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
