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
    /// Kept after the template is deleted so the log still has a title.
    var templateName: String?
    var templateID: UUID?
    var syncToHealthKit: Bool
    var treadmillSpeedMph: Double?
    var treadmillInclinePercent: Double?
    var poolLengthRaw: String?
    var swimDistanceUnitRaw: String?
    var estimatedSteps: Int
    var estimatedCalories: Double
    var healthKitSyncId: String?
    var healthKitStepSampleId: String?
    var workoutEndAt: Date?
    var startedAt: Date?
    /// When a finished live workout is resumed, elapsed time continues from `durationMinutes` plus time since this date.
    var resumedAt: Date?
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
        self.resumedAt = nil
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

    var swimDistanceUnit: SwimDistanceUnit {
        get {
            if let swimDistanceUnitRaw, let unit = SwimDistanceUnit(rawValue: swimDistanceUnitRaw) {
                return unit
            }
            return poolLength == .yards25 ? .yards : .meters
        }
        set { swimDistanceUnitRaw = newValue.rawValue }
    }

    /// Distance typed for this swim, or the old lengths × pool length for earlier logs.
    var swimDistanceLabel: String? {
        let segments = sortedSwimSegments
        guard !segments.isEmpty else { return nil }
        if segments.contains(where: { $0.distance != nil }) {
            let total = segments.reduce(0.0) { $0 + ($1.distance ?? 0) }
            guard total > 0 else { return nil }
            return swimDistanceUnit.format(total)
        }
        guard swimTotalLengths > 0 else { return nil }
        return "\(swimTotalLengths) lengths · \(poolLength.distanceLabel(lengths: swimTotalLengths))"
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
            if let templateName = templateName?.trimmingCharacters(in: .whitespacesAndNewlines), !templateName.isEmpty {
                return templateName
            }
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

    /// Active time, excluding any gap between finishing and resuming.
    func activeElapsed(at now: Date = Date()) -> TimeInterval {
        if isInProgress, let resumedAt {
            return max(0, durationMinutes * 60 + now.timeIntervalSince(resumedAt))
        }
        if isInProgress, let startedAt {
            return max(0, now.timeIntervalSince(startedAt))
        }
        return max(0, durationMinutes * 60)
    }

    var healthKitTimeRange: (start: Date, end: Date) {
        let end = effectiveWorkoutEnd
        if isLive {
            let durationSec = max(durationMinutes * 60, 1)
            return (end.addingTimeInterval(-durationSec), end)
        }
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
    var distance: Double?
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
        self.distance = nil
        self.sortOrder = sortOrder
    }

    func meters(unit: SwimDistanceUnit, pool: PoolLength) -> Double {
        if let distance {
            return unit.meters(from: distance)
        }
        return Double(lengths) * pool.meters
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
