import SwiftUI
import SwiftData
import UIKit

struct StrengthWorkoutLogView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var healthKit: HealthKitService

    @Bindable var session: WorkoutSession
    var isNew: Bool = false
    var initialWorkoutEndAt: Date?

    @State private var showExerciseSearch = false
    @State private var showCustomExercise = false
    @State private var durationMinutes: Double = 45
    @State private var workoutEndAt = Date()
    @State private var syncToHealthKit = true
    @State private var prefilledFromLastSession = false

    private struct ExerciseGroup: Identifiable {
        let id: String
        let exercise: Exercise?
        let name: String
        let sortOrder: Int
        var sets: [WorkoutSetLog]
    }

    private func groupKey(for log: WorkoutSetLog) -> String {
        if let exerciseId = log.exercise?.id {
            return exerciseId.uuidString
        }
        return log.snapshotExerciseName ?? log.id.uuidString
    }

    private var exerciseGroups: [ExerciseGroup] {
        var groupMap: [String: ExerciseGroup] = [:]
        for log in session.sortedSetLogs {
            let key = groupKey(for: log)
            if var existing = groupMap[key] {
                existing.sets.append(log)
                groupMap[key] = existing
            } else {
                groupMap[key] = ExerciseGroup(
                    id: key,
                    exercise: log.exercise,
                    name: log.displayExerciseName,
                    sortOrder: log.exerciseSortOrder,
                    sets: [log]
                )
            }
        }
        return groupMap.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    NumericStepperField(
                        title: "Duration",
                        value: $durationMinutes,
                        range: 5...180,
                        step: 5,
                        suffix: "min"
                    )
                    Toggle("Sync calories to HealthKit", isOn: $syncToHealthKit)
                    if prefilledFromLastSession, let templateName = session.template?.name {
                        Text("Prefilled from your last \(templateName) workout.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                WorkoutTimeSection(
                    workoutEndAt: $workoutEndAt,
                    durationMinutes: durationMinutes,
                    syncToHealthKit: syncToHealthKit,
                    includesSteps: false
                )

                ForEach(exerciseGroups) { group in
                    Section(group.name) {
                        let sets = group.sets.sorted(by: { $0.setIndex < $1.setIndex })
                        ForEach(sets, id: \.id) { setLog in
                            SetLogRow(setLog: setLog)
                        }
                        .onDelete { offsets in
                            deleteSets(sets, at: offsets)
                        }
                        Button("Add Set") {
                            addSet(for: group)
                        }
                    }
                }

                Section {
                    Button("Add Exercise") { showExerciseSearch = true }
                    Button("Create Custom Exercise") { showCustomExercise = true }
                }
            }
            .navigationTitle(session.template?.name ?? "Weight Training")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismissKeyboard()
                        if isNew { context.delete(session) }
                        DispatchQueue.main.async { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSession() }
                }
            }
            .onAppear {
                syncToHealthKit = session.syncToHealthKit
                if isNew, let template = session.template {
                    let hadPrevious = WorkoutService.lastSession(for: template, excluding: session, context: context) != nil
                    WorkoutService.seedSessionFromTemplate(session, template: template, context: context)
                    prefilledFromLastSession = hadPrevious
                }
                durationMinutes = session.durationMinutes > 0 ? session.durationMinutes : 45
                workoutEndAt = initialWorkoutEndAt ?? session.effectiveWorkoutEnd
            }
            .sheet(isPresented: $showExerciseSearch) {
                ExerciseSearchView { exercise in
                    addExercise(exercise)
                }
            }
            .sheet(isPresented: $showCustomExercise) {
                CustomExerciseFormView { exercise in
                    addExercise(exercise)
                }
            }
        }
    }

    private func addExercise(_ exercise: Exercise) {
        let sortOrder = (session.setLogs.map(\.exerciseSortOrder).max() ?? -1) + 1
        WorkoutService.addSetLog(
            to: session,
            exercise: exercise,
            exerciseSortOrder: sortOrder,
            setIndex: 0,
            reps: 8,
            weightLbs: nil,
            isWarmup: false,
            context: context
        )
    }

    private func addSet(for group: ExerciseGroup) {
        guard let exercise = group.exercise else { return }
        let nextIndex = (group.sets.map(\.setIndex).max() ?? -1) + 1
        let last = group.sets.last
        WorkoutService.addSetLog(
            to: session,
            exercise: exercise,
            exerciseSortOrder: group.sortOrder,
            setIndex: nextIndex,
            reps: last?.reps ?? 8,
            weightLbs: last?.weightLbs,
            isWarmup: false,
            notes: last?.notes,
            context: context
        )
    }

    private func deleteSets(_ sets: [WorkoutSetLog], at offsets: IndexSet) {
        let logs = offsets.compactMap { index in
            sets.indices.contains(index) ? sets[index] : nil
        }
        WorkoutService.deleteSetLogs(logs, from: session, context: context)
    }

    private func saveSession() {
        dismissKeyboard()
        session.durationMinutes = durationMinutes
        session.syncToHealthKit = syncToHealthKit
        WorkoutService.applyWorkoutEnd(workoutEndAt, to: session)
        for log in session.setLogs {
            log.freezeFromExercise()
        }
        try? context.save()
        Task {
            await WorkoutService.finalizeStrengthSession(session, context: context, healthKit: healthKit)
            dismiss()
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

struct SetLogRow: View {
    @Bindable var setLog: WorkoutSetLog
    @State private var repsText = ""
    @State private var weightText = ""
    @State private var showNotes = false
    @State private var notesDraft = ""

    var body: some View {
        HStack {
            Text("Set \(setLog.setIndex + 1)")
                .frame(width: 50, alignment: .leading)
            TextField("Reps", text: $repsText)
                .keyboardType(.numberPad)
                .frame(width: 50)
                .multilineTextAlignment(.trailing)
                .onAppear { repsText = setLog.reps > 0 ? "\(setLog.reps)" : "" }
                .onChange(of: repsText) { _, new in
                    setLog.reps = Int(new) ?? 0
                }
            TextField("lbs", text: $weightText)
                .keyboardType(.decimalPad)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .onAppear {
                    if let w = setLog.weightLbs { weightText = w.formatted(.number.precision(.fractionLength(0...1))) }
                }
                .onChange(of: weightText) { _, new in
                    setLog.weightLbs = Double(new)
                }
            Toggle("W", isOn: $setLog.isWarmup)
                .labelsHidden()
                .toggleStyle(.button)
                .tint(setLog.isWarmup ? .orange : .secondary)
            Button {
                notesDraft = setLog.notes ?? ""
                showNotes = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "note.text")
                        .font(.body)
                    if setLog.hasNotes {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .offset(x: 2, y: -2)
                    }
                }
                .foregroundStyle(setLog.hasNotes ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(setLog.hasNotes ? "Edit set notes" : "Add set notes")
        }
        .sheet(isPresented: $showNotes) {
            NavigationStack {
                TextField("Notes for this set", text: $notesDraft, axis: .vertical)
                    .lineLimit(5...12)
                    .padding()
                    .navigationTitle("Set \(setLog.setIndex + 1) Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showNotes = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                setLog.notes = WorkoutSetLog.normalizedNotes(notesDraft)
                                showNotes = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }
}

struct CardioWorkoutDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var healthKit: HealthKitService

    @Bindable var session: WorkoutSession

    @State private var durationMinutes: Double = 30
    @State private var workoutEndAt = Date()
    @State private var treadmillSpeed = 3.5
    @State private var treadmillIncline = 0.0
    @State private var poolLength: PoolLength = .yards25
    @State private var swimSegments: [SwimSegmentDraft] = [SwimSegmentDraft()]
    @State private var syncToHealthKit = true
    @State private var isSaving = false

    private var isTreadmill: Bool { session.workoutType == .treadmill }
    private var isSwimming: Bool { session.workoutType == .swimming }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    LabeledContent("Type", value: session.workoutType.displayName)
                    NumericStepperField(
                        title: "Duration",
                        value: $durationMinutes,
                        range: 5...240,
                        step: 5,
                        suffix: "min"
                    )
                }

                if isTreadmill {
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
                            title: "Incline",
                            value: $treadmillIncline,
                            range: 0...15,
                            step: 0.5,
                            suffix: "%",
                            format: "%.1f"
                        )
                    }
                }

                if isSwimming {
                    SwimSegmentsEditor(poolLength: $poolLength, segments: $swimSegments)
                }

                WorkoutTimeSection(
                    workoutEndAt: $workoutEndAt,
                    durationMinutes: durationMinutes,
                    syncToHealthKit: syncToHealthKit,
                    includesSteps: session.workoutType.writesHealthKitSteps
                )

                Section("HealthKit") {
                    Toggle("Sync to HealthKit", isOn: $syncToHealthKit)
                }

                Section("Current Estimates") {
                    if session.estimatedCalories > 0 {
                        LabeledContent("Calories", value: "\(Int(session.estimatedCalories)) kcal")
                    }
                    if session.estimatedSteps > 0 {
                        LabeledContent("Est. Steps", value: "\(session.estimatedSteps)")
                    }
                    Text("Editing the end time re-writes the samples in HealthKit at the new time. Use a window where your phone wasn't counting steps so they aren't deduplicated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(session.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismissKeyboard()
                        DispatchQueue.main.async { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveEdits() }
                        .disabled(isSaving)
                }
            }
            .onAppear {
                durationMinutes = session.durationMinutes > 0 ? session.durationMinutes : 30
                workoutEndAt = session.effectiveWorkoutEnd
                treadmillSpeed = session.treadmillSpeedMph ?? 3.5
                treadmillIncline = session.treadmillInclinePercent ?? 0
                poolLength = session.poolLength
                let existing = session.sortedSwimSegments.map { SwimSegmentDraft(stroke: $0.stroke, lengths: $0.lengths) }
                swimSegments = existing.isEmpty ? [SwimSegmentDraft()] : existing
                syncToHealthKit = session.syncToHealthKit
            }
        }
    }

    private func saveEdits() {
        dismissKeyboard()
        isSaving = true
        session.durationMinutes = durationMinutes
        session.syncToHealthKit = syncToHealthKit
        if isTreadmill {
            session.treadmillSpeedMph = treadmillSpeed
            session.treadmillInclinePercent = treadmillIncline
        }
        if isSwimming {
            session.poolLength = poolLength
            WorkoutService.replaceSwimSegments(on: session, drafts: swimSegments, context: context)
        }
        WorkoutService.applyWorkoutEnd(workoutEndAt, to: session)
        try? context.save()
        Task {
            await WorkoutService.finalizeCardioSession(session, context: context, healthKit: healthKit)
            dismiss()
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
