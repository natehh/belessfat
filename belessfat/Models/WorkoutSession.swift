import Foundation
import SwiftData

@Model
final class WorkoutSession {
    var id: UUID
    var date: Date
    var workoutTypeRaw: String
    var durationMinutes: Double
    var notes: String?
    var template: WorkoutTemplate?
    var syncToHealthKit: Bool
    var treadmillSpeedMph: Double?
    var treadmillInclinePercent: Double?
    var poolLengthRaw: String?
    var estimatedSteps: Int
    var estimatedCalories: Double
    var healthKitSyncId: String?
    var healthKitStepSampleId: String?
    var workoutEndAt: Date?
    var startedAt: Date?
    var isLive: Bool = false
    var isInProgress: Bool = false
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \WorkoutSetLog.session)
    var setLogs: [WorkoutSetLog]
    @Relationship(deleteRule: .cascade, inverse: \SwimSegment.session)
    var swimSegments: [SwimSegment]

    var workoutType: WorkoutType {
        get { WorkoutType(rawValue: workoutTypeRaw) ?? .strength }
        set { workoutTypeRaw = newValue.rawValue }
    }

    init(
        date: Date,
        workoutType: WorkoutType,
        durationMinutes: Double = 0,
        syncToHealthKit: Bool = false
    ) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.workoutTypeRaw = workoutType.rawValue
        self.durationMinutes = durationMinutes
        self.syncToHealthKit = syncToHealthKit
        self.estimatedSteps = 0
        self.estimatedCalories = 0
        self.workoutEndAt = Date()
        self.startedAt = nil
        self.isLive = false
        self.isInProgress = false
        self.createdAt = Date()
        self.setLogs = []
        self.swimSegments = []
    }

    var poolLength: PoolLength {
        get { PoolLength(rawValue: poolLengthRaw ?? "") ?? .yards25 }
        set { poolLengthRaw = newValue.rawValue }
    }

    var sortedSwimSegments: [SwimSegment] {
        swimSegments.sorted { $0.sortOrder < $1.sortOrder }
    }

    var swimTotalLengths: Int {
        swimSegments.reduce(0) { $0 + $1.lengths }
    }

    var displayTitle: String {
        switch workoutType {
        case .strength:
            return template?.name ?? "Weight Training"
        case .tennisSingles: return "Tennis (Singles)"
        case .tennisDoubles: return "Tennis (Doubles)"
        case .treadmill: return "Treadmill"
        case .swimming: return "Swimming"
        }
    }

    var sortedSetLogs: [WorkoutSetLog] {
        setLogs.sorted {
            if $0.exerciseSortOrder != $1.exerciseSortOrder {
                return $0.exerciseSortOrder < $1.exerciseSortOrder
            }
            return $0.setIndex < $1.setIndex
        }
    }

    /// End time used for HealthKit sync; falls back to creation time for older sessions.
    var effectiveWorkoutEnd: Date {
        workoutEndAt ?? createdAt
    }

    var effectiveWorkoutStart: Date {
        if let startedAt { return startedAt }
        let durationSec = max(durationMinutes * 60, 60)
        return effectiveWorkoutEnd.addingTimeInterval(-durationSec)
    }

    var completedSetCount: Int {
        setLogs.filter(\.isCompleted).count
    }

    var incompleteSetCount: Int {
        guard isLive else { return 0 }
        return setLogs.filter { !$0.isCompleted }.count
    }

    var setsShortOfPlannedReps: Int {
        setLogs.filter(\.fellShortOfPlan).count
    }

    var didCompleteAllPlannedSets: Bool {
        guard isLive, !setLogs.isEmpty else { return true }
        return setLogs.allSatisfy(\.isCompleted)
    }

    var healthKitTimeRange: (start: Date, end: Date) {
        if isLive, let startedAt {
            let end = max(effectiveWorkoutEnd, startedAt.addingTimeInterval(1))
            return (startedAt, end)
        }
        let end = effectiveWorkoutEnd
        let durationSec = max(durationMinutes * 60, 60)
        let start = end.addingTimeInterval(-durationSec)
        return (start, end)
    }
}

@Model
final class WorkoutSetLog {
    var id: UUID
    var exercise: Exercise?
    var exerciseSortOrder: Int
    var setIndex: Int
    var reps: Int
    var weightLbs: Double?
    var isWarmup: Bool
    var notes: String?
    var snapshotExerciseName: String?
    var completedAt: Date?
    var plannedReps: Int = 0
    var plannedWeightLbs: Double?
    var session: WorkoutSession?

    init(
        exercise: Exercise?,
        exerciseSortOrder: Int,
        setIndex: Int,
        reps: Int,
        weightLbs: Double? = nil,
        isWarmup: Bool = false,
        notes: String? = nil,
        plannedReps: Int = 0,
        plannedWeightLbs: Double? = nil
    ) {
        self.id = UUID()
        self.exercise = exercise
        self.exerciseSortOrder = exerciseSortOrder
        self.setIndex = setIndex
        self.reps = reps
        self.weightLbs = weightLbs
        self.isWarmup = isWarmup
        self.notes = Self.normalizedNotes(notes)
        self.completedAt = nil
        self.plannedReps = plannedReps
        self.plannedWeightLbs = plannedWeightLbs
        if let exercise {
            self.snapshotExerciseName = exercise.name
        }
    }

    /// Live sessions only count a set as done once it has been checked. After-the-fact
    /// and older sessions treat every logged set as completed.
    var isCompleted: Bool {
        if session?.isLive == true {
            return completedAt != nil
        }
        return true
    }

    var fellShortOfPlan: Bool {
        guard isCompleted, plannedReps > 0 else { return false }
        return reps < plannedReps
    }

    var hasNotes: Bool {
        !(notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    static func normalizedNotes(_ notes: String?) -> String? {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var displayExerciseName: String {
        snapshotExerciseName ?? exercise?.name ?? "Unknown Exercise"
    }

    var volume: Double {
        guard isCompleted, let weightLbs, !isWarmup else { return 0 }
        return Double(reps) * weightLbs
    }

    func freezeFromExercise() {
        guard snapshotExerciseName == nil, let exercise else { return }
        snapshotExerciseName = exercise.name
    }
}

@Model
final class SwimSegment {
    var id: UUID
    var strokeRaw: String
    var lengths: Int
    var sortOrder: Int
    var session: WorkoutSession?

    var stroke: SwimStroke {
        get { SwimStroke(rawValue: strokeRaw) ?? .freestyle }
        set { strokeRaw = newValue.rawValue }
    }

    init(stroke: SwimStroke, lengths: Int, sortOrder: Int) {
        self.id = UUID()
        self.strokeRaw = stroke.rawValue
        self.lengths = max(0, lengths)
        self.sortOrder = sortOrder
    }
}

@Model
final class WorkoutSettings {
    var id: UUID
    var defaultSecondsPerSet: Int
    var tennisSinglesStepsPerMin: Double
    var tennisDoublesStepsPerMin: Double
    var strideLengthFeet: Double
    var defaultStrengthMET: Double

    init() {
        self.id = UUID()
        self.defaultSecondsPerSet = 60
        self.tennisSinglesStepsPerMin = 130
        self.tennisDoublesStepsPerMin = 70
        self.strideLengthFeet = 2.5
        self.defaultStrengthMET = ExerciseMETDefaults.defaultStrengthMET
    }
}
