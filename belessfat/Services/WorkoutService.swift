import Foundation
import SwiftData
import HealthKit

struct SwimSegmentDraft: Identifiable, Equatable {
    var id = UUID()
    var stroke: SwimStroke = .freestyle
    var lengths: Double = 0

    init(stroke: SwimStroke = .freestyle, lengths: Int = 0) {
        self.stroke = stroke
        self.lengths = Double(lengths)
    }

    var lengthsInt: Int { max(0, Int(lengths.rounded())) }
}

@MainActor
enum WorkoutService {
    static func settings(context: ModelContext) -> WorkoutSettings {
        let descriptor = FetchDescriptor<WorkoutSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let settings = WorkoutSettings()
        context.insert(settings)
        try? context.save()
        return settings
    }

    static func sessions(for date: Date, context: ModelContext) -> [WorkoutSession] {
        let day = DateHelpers.startOfDay(date)
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date == day },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func sessions(from start: Date, to end: Date, context: ModelContext) -> [WorkoutSession] {
        let startDay = DateHelpers.startOfDay(start)
        let endDay = DateHelpers.startOfDay(end)
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= startDay && $0.date <= endDay },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func templates(context: ModelContext) -> [WorkoutTemplate] {
        let descriptor = FetchDescriptor<WorkoutTemplate>(
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func allExercises(context: ModelContext) -> [Exercise] {
        let descriptor = FetchDescriptor<Exercise>(
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func loggedExercises(from start: Date, to end: Date, context: ModelContext) -> [Exercise] {
        let sessions = sessions(from: start, to: end, context: context)
        var seen = Set<UUID>()
        var exercises: [Exercise] = []
        for session in sessions where session.workoutType == .strength {
            for setLog in session.setLogs {
                guard let exercise = setLog.exercise, !seen.contains(exercise.id) else { continue }
                seen.insert(exercise.id)
                exercises.append(exercise)
            }
        }
        return exercises.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func exercise(withWgerId id: Int, context: ModelContext) -> Exercise? {
        let descriptor = FetchDescriptor<Exercise>(
            predicate: #Predicate { $0.wgerId == id }
        )
        return try? context.fetch(descriptor).first
    }

    static func cacheExercise(from searchResult: WgerClient.SearchResult, context: ModelContext) async throws -> Exercise {
        if let existing = exercise(withWgerId: searchResult.id, context: context) {
            return existing
        }
        let info = try await WgerClient.fetchExerciseInfo(id: searchResult.id)
        let exercise = WgerClient.makeExercise(from: info, fallbackName: searchResult.name)
        context.insert(exercise)
        try context.save()
        return exercise
    }

    static func createCustomExercise(
        name: String,
        categoryName: String?,
        metValue: Double?,
        context: ModelContext
    ) -> Exercise {
        let exercise = Exercise(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryName: categoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
            metValue: metValue,
            isCustom: true
        )
        context.insert(exercise)
        try? context.save()
        return exercise
    }

    static func createTemplate(name: String, context: ModelContext) -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name)
        context.insert(template)
        try? context.save()
        return template
    }

    static func addExercise(_ exercise: Exercise, to template: WorkoutTemplate, context: ModelContext) {
        let order = template.exercises.count
        let item = WorkoutTemplateExercise(exercise: exercise, sortOrder: order)
        item.template = template
        template.exercises.append(item)
        context.insert(item)
        try? context.save()
    }

    static func removeTemplateExercise(_ item: WorkoutTemplateExercise, context: ModelContext) {
        context.delete(item)
        try? context.save()
    }

    static func reorderTemplateExercises(
        in template: WorkoutTemplate,
        fromOffsets: IndexSet,
        toOffset: Int,
        context: ModelContext
    ) {
        var items = template.sortedExercises
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, item) in items.enumerated() {
            item.sortOrder = index
        }
        try? context.save()
    }

    static func deleteTemplate(_ template: WorkoutTemplate, context: ModelContext) {
        context.delete(template)
        try? context.save()
    }

    static func deleteSession(_ session: WorkoutSession, healthKit: HealthKitService, context: ModelContext) async {
        if session.healthKitSyncId != nil || session.healthKitStepSampleId != nil {
            await healthKit.deleteSyncedWorkout(
                workoutId: session.healthKitSyncId,
                stepSampleId: session.healthKitStepSampleId
            )
        }
        context.delete(session)
        try? context.save()
    }

    static func bodyWeightLbs(context: ModelContext) -> Double {
        let descriptor = FetchDescriptor<WeightEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let latest = try? context.fetch(descriptor).first {
            return latest.weightLbs
        }
        return 170
    }

    /// Removes any HealthKit samples previously written for this session and clears the stored ids.
    /// Call before rewriting (resync) or when a user turns sync off, so nothing is left orphaned.
    static func clearHealthKitSamples(for session: WorkoutSession, healthKit: HealthKitService) async {
        guard session.healthKitSyncId != nil || session.healthKitStepSampleId != nil else { return }
        await healthKit.deleteSyncedWorkout(
            workoutId: session.healthKitSyncId,
            stepSampleId: session.healthKitStepSampleId
        )
        session.healthKitSyncId = nil
        session.healthKitStepSampleId = nil
    }

    static func finalizeStrengthSession(
        _ session: WorkoutSession,
        context: ModelContext,
        healthKit: HealthKitService
    ) async {
        let settings = WorkoutService.settings(context: context)
        let weight = bodyWeightLbs(context: context)
        session.estimatedCalories = WorkoutCalorieCalculator.strengthCalories(
            session: session,
            weightLbs: weight,
            settings: settings
        )
        session.estimatedSteps = 0

        // Remove any prior samples so an edit/resync doesn't duplicate in Apple Health.
        await clearHealthKitSamples(for: session, healthKit: healthKit)
        try? context.save()

        guard session.syncToHealthKit, session.estimatedCalories > 0 else { return }
        let (start, end) = session.healthKitTimeRange
        if let result = await healthKit.saveWorkout(
            activityType: .traditionalStrengthTraining,
            start: start,
            end: end,
            calories: session.estimatedCalories,
            steps: nil
        ) {
            session.healthKitSyncId = result.workoutUUID?.uuidString
            session.healthKitStepSampleId = result.stepSampleUUID?.uuidString
            try? context.save()
        }
    }

    static func finalizeCardioSession(
        _ session: WorkoutSession,
        context: ModelContext,
        healthKit: HealthKitService
    ) async {
        let settings = WorkoutService.settings(context: context)
        let weight = bodyWeightLbs(context: context)

        switch session.workoutType {
        case .tennisSingles, .tennisDoubles:
            session.estimatedSteps = WorkoutCalorieCalculator.tennisSteps(
                durationMinutes: session.durationMinutes,
                workoutType: session.workoutType,
                settings: settings
            )
            session.estimatedCalories = WorkoutCalorieCalculator.tennisCalories(
                durationMinutes: session.durationMinutes,
                workoutType: session.workoutType,
                weightLbs: weight
            )
        case .treadmill:
            let speed = session.treadmillSpeedMph ?? 0
            let incline = session.treadmillInclinePercent ?? 0
            session.estimatedSteps = WorkoutCalorieCalculator.treadmillSteps(
                speedMph: speed,
                durationMinutes: session.durationMinutes,
                strideLengthFeet: settings.strideLengthFeet
            )
            session.estimatedCalories = WorkoutCalorieCalculator.treadmillCalories(
                speedMph: speed,
                durationMinutes: session.durationMinutes,
                inclinePercent: incline,
                weightLbs: weight
            )
        case .swimming:
            session.estimatedSteps = 0
            session.estimatedCalories = WorkoutCalorieCalculator.swimmingCalories(
                durationMinutes: session.durationMinutes,
                weightLbs: weight,
                poolLength: session.poolLength,
                segments: session.sortedSwimSegments.map { ($0.stroke, $0.lengths) }
            )
        default:
            break
        }

        // Remove any prior samples so an edit/resync doesn't duplicate in Apple Health.
        await clearHealthKitSamples(for: session, healthKit: healthKit)
        try? context.save()

        guard session.syncToHealthKit else { return }

        let (start, end) = session.healthKitTimeRange
        let activityType: HKWorkoutActivityType
        switch session.workoutType {
        case .tennisSingles, .tennisDoubles:
            activityType = .tennis
        case .treadmill:
            activityType = (session.treadmillSpeedMph ?? 0) >= 4.0 ? .running : .walking
        case .swimming:
            activityType = .swimming
        default:
            return
        }

        let steps = session.estimatedSteps > 0 ? session.estimatedSteps : nil
        if let result = await healthKit.saveWorkout(
            activityType: activityType,
            start: start,
            end: end,
            calories: session.estimatedCalories > 0 ? session.estimatedCalories : nil,
            steps: steps
        ) {
            session.healthKitSyncId = result.workoutUUID?.uuidString
            session.healthKitStepSampleId = result.stepSampleUUID?.uuidString
            try? context.save()
        }
    }

    static func replaceSwimSegments(
        on session: WorkoutSession,
        drafts: [SwimSegmentDraft],
        context: ModelContext
    ) {
        for existing in session.swimSegments {
            context.delete(existing)
        }
        session.swimSegments = []
        for (index, draft) in drafts.enumerated() where draft.lengthsInt > 0 {
            let segment = SwimSegment(stroke: draft.stroke, lengths: draft.lengthsInt, sortOrder: index)
            segment.session = session
            session.swimSegments.append(segment)
            context.insert(segment)
        }
        try? context.save()
    }

    static func applyWorkoutEnd(_ end: Date, to session: WorkoutSession) {
        session.workoutEndAt = end
        session.date = DateHelpers.startOfDay(end)
    }

    static func defaultWorkoutEnd(for diaryDate: Date) -> Date {
        let now = Date()
        guard !DateHelpers.isSameDay(diaryDate, now) else { return now }

        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: now)
        var day = calendar.dateComponents([.year, .month, .day], from: diaryDate)
        day.hour = time.hour
        day.minute = time.minute
        guard let combined = calendar.date(from: day) else { return now }
        return combined > now ? now : combined
    }

    static func createStrengthSession(
        date: Date,
        template: WorkoutTemplate?,
        syncToHealthKit: Bool,
        durationMinutes: Double,
        workoutEndAt: Date,
        context: ModelContext
    ) -> WorkoutSession {
        let session = WorkoutSession(
            date: date,
            workoutType: .strength,
            durationMinutes: durationMinutes,
            syncToHealthKit: syncToHealthKit
        )
        applyWorkoutEnd(workoutEndAt, to: session)
        session.template = template
        context.insert(session)
        try? context.save()
        return session
    }

    static func lastSession(
        for template: WorkoutTemplate,
        excluding: WorkoutSession? = nil,
        context: ModelContext
    ) -> WorkoutSession? {
        let templateId = template.id
        let excludingId = excluding?.id
        let strengthType = WorkoutType.strength.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.workoutTypeRaw == strengthType },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let sessions = (try? context.fetch(descriptor)) ?? []
        return sessions.first { session in
            session.template?.id == templateId &&
            session.id != excludingId &&
            !session.setLogs.isEmpty
        }
    }

    static func seedSessionFromTemplate(
        _ session: WorkoutSession,
        template: WorkoutTemplate,
        context: ModelContext
    ) {
        guard session.setLogs.isEmpty else { return }

        if let previous = lastSession(for: template, excluding: session, context: context) {
            if previous.durationMinutes > 0 {
                session.durationMinutes = previous.durationMinutes
            }
            for (index, item) in template.sortedExercises.enumerated() {
                guard let exercise = item.exercise else { continue }
                let previousLogs = previousLogs(for: exercise, in: previous)
                if previousLogs.isEmpty {
                    addSetLog(
                        to: session,
                        exercise: exercise,
                        exerciseSortOrder: index,
                        setIndex: 0,
                        reps: 0,
                        weightLbs: nil,
                        isWarmup: false,
                        context: context
                    )
                } else {
                    for log in previousLogs {
                        addSetLog(
                            to: session,
                            exercise: exercise,
                            exerciseSortOrder: index,
                            setIndex: log.setIndex,
                            reps: log.reps,
                            weightLbs: log.weightLbs,
                            isWarmup: log.isWarmup,
                            context: context
                        )
                    }
                }
            }
        } else {
            for (index, item) in template.sortedExercises.enumerated() {
                guard let exercise = item.exercise else { continue }
                addSetLog(
                    to: session,
                    exercise: exercise,
                    exerciseSortOrder: index,
                    setIndex: 0,
                    reps: 0,
                    weightLbs: nil,
                    isWarmup: false,
                    context: context
                )
            }
        }
        try? context.save()
    }

    private static func previousLogs(for exercise: Exercise, in session: WorkoutSession) -> [WorkoutSetLog] {
        session.sortedSetLogs.filter { log in
            log.exercise?.id == exercise.id ||
            log.snapshotExerciseName?.caseInsensitiveCompare(exercise.name) == .orderedSame
        }
    }

    static func addSetLog(
        to session: WorkoutSession,
        exercise: Exercise,
        exerciseSortOrder: Int,
        setIndex: Int,
        reps: Int,
        weightLbs: Double?,
        isWarmup: Bool,
        context: ModelContext
    ) {
        let log = WorkoutSetLog(
            exercise: exercise,
            exerciseSortOrder: exerciseSortOrder,
            setIndex: setIndex,
            reps: reps,
            weightLbs: weightLbs,
            isWarmup: isWarmup
        )
        log.session = session
        session.setLogs.append(log)
        context.insert(log)
        try? context.save()
    }

    static func deleteSetLogs(_ logs: [WorkoutSetLog], from session: WorkoutSession, context: ModelContext) {
        guard !logs.isEmpty else { return }
        let groupKeys = Set(logs.map(exerciseGroupKey(for:)))
        for log in logs {
            context.delete(log)
        }
        try? context.save()
        for key in groupKeys {
            let remaining = session.sortedSetLogs
                .filter { exerciseGroupKey(for: $0) == key }
                .sorted { $0.setIndex < $1.setIndex }
            for (index, log) in remaining.enumerated() {
                log.setIndex = index
            }
        }
        try? context.save()
    }

    private static func exerciseGroupKey(for log: WorkoutSetLog) -> String {
        if let exerciseId = log.exercise?.id {
            return exerciseId.uuidString
        }
        return log.snapshotExerciseName ?? log.id.uuidString
    }
}
