import Foundation
import SwiftData

@MainActor
enum WorkoutReportService {
    struct DailyWorkoutRow: Identifiable {
        let id: Date
        let date: Date
        let sessionCount: Int
        let totalMinutes: Double
        let totalCalories: Double
        let totalSteps: Int
    }

    struct ExerciseTrendPoint: Identifiable {
        let id: Date
        let date: Date
        let maxWeight: Double?
        let bestReps: Int?
        let totalVolume: Double
    }

    struct PeriodSummary {
        let avgSessionsPerDay: Double
        let avgMinutesPerDay: Double
        let avgCaloriesPerDay: Double
        let totalSessions: Int
    }

    static func dailyRows(from start: Date, to end: Date, context: ModelContext) -> [DailyWorkoutRow] {
        let sessions = WorkoutService.sessions(from: start, to: end, context: context)
        let days = DateHelpers.daysBetween(DateHelpers.startOfDay(start), DateHelpers.startOfDay(end))

        return days.map { day in
            let daySessions = sessions.filter { DateHelpers.isSameDay($0.date, day) }
            return DailyWorkoutRow(
                id: day,
                date: day,
                sessionCount: daySessions.count,
                totalMinutes: daySessions.reduce(0) { $0 + $1.durationMinutes },
                totalCalories: daySessions.reduce(0) { $0 + $1.estimatedCalories },
                totalSteps: daySessions.reduce(0) { $0 + $1.estimatedSteps }
            )
        }
    }

    static func periodSummary(rows: [DailyWorkoutRow]) -> PeriodSummary {
        guard !rows.isEmpty else {
            return PeriodSummary(avgSessionsPerDay: 0, avgMinutesPerDay: 0, avgCaloriesPerDay: 0, totalSessions: 0)
        }
        let count = Double(rows.count)
        let totalSessions = rows.reduce(0) { $0 + $1.sessionCount }
        return PeriodSummary(
            avgSessionsPerDay: Double(totalSessions) / count,
            avgMinutesPerDay: rows.reduce(0) { $0 + $1.totalMinutes } / count,
            avgCaloriesPerDay: rows.reduce(0) { $0 + $1.totalCalories } / count,
            totalSessions: totalSessions
        )
    }

    static func exerciseTrend(
        exercise: Exercise,
        from start: Date,
        to end: Date,
        context: ModelContext
    ) -> [ExerciseTrendPoint] {
        let sessions = WorkoutService.sessions(from: start, to: end, context: context)
            .filter { $0.workoutType == .strength }
        let days = DateHelpers.daysBetween(DateHelpers.startOfDay(start), DateHelpers.startOfDay(end))

        return days.compactMap { day -> ExerciseTrendPoint? in
            let daySessions = sessions.filter { DateHelpers.isSameDay($0.date, day) }
            let logs = daySessions.flatMap(\.setLogs).filter {
                !$0.isWarmup && ($0.exercise?.id == exercise.id || $0.snapshotExerciseName == exercise.name)
            }
            guard !logs.isEmpty else { return nil }

            let maxWeight = logs.compactMap(\.weightLbs).max()
            let bestReps = logs.map(\.reps).max()
            let volume = logs.reduce(0) { $0 + $1.volume }

            return ExerciseTrendPoint(
                id: day,
                date: day,
                maxWeight: maxWeight,
                bestReps: bestReps,
                totalVolume: volume
            )
        }
    }
}
