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
    var estimatedSteps: Int
    var estimatedCalories: Double
    var healthKitSyncId: String?
    var healthKitStepSampleId: String?
    var workoutEndAt: Date?
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \WorkoutSetLog.session)
    var setLogs: [WorkoutSetLog]

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
        self.createdAt = Date()
        self.setLogs = []
    }

    var displayTitle: String {
        switch workoutType {
        case .strength:
            return template?.name ?? "Weight Training"
        case .tennisSingles: return "Tennis (Singles)"
        case .tennisDoubles: return "Tennis (Doubles)"
        case .treadmill: return "Treadmill"
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

    var healthKitTimeRange: (start: Date, end: Date) {
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
    var snapshotExerciseName: String?
    var session: WorkoutSession?

    init(
        exercise: Exercise?,
        exerciseSortOrder: Int,
        setIndex: Int,
        reps: Int,
        weightLbs: Double? = nil,
        isWarmup: Bool = false
    ) {
        self.id = UUID()
        self.exercise = exercise
        self.exerciseSortOrder = exerciseSortOrder
        self.setIndex = setIndex
        self.reps = reps
        self.weightLbs = weightLbs
        self.isWarmup = isWarmup
        if let exercise {
            self.snapshotExerciseName = exercise.name
        }
    }

    var displayExerciseName: String {
        snapshotExerciseName ?? exercise?.name ?? "Unknown Exercise"
    }

    var volume: Double {
        guard let weightLbs, !isWarmup else { return 0 }
        return Double(reps) * weightLbs
    }

    func freezeFromExercise() {
        guard snapshotExerciseName == nil, let exercise else { return }
        snapshotExerciseName = exercise.name
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
