import Foundation
import SwiftData

@MainActor
enum ReportService {
    struct DailyReportRow: Identifiable {
        var id: Date { date }
        var date: Date
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var weight: Double?
        var steps: Int
        var activeCalories: Double
        var netCalories: Double
    }

    struct PeriodComparison {
        var caloriesDelta: Double
        var proteinDelta: Double
        var carbsDelta: Double
        var fatDelta: Double
        var weightDelta: Double?
        var stepsDelta: Double
    }

    static func dailyRows(from start: Date, to end: Date, context: ModelContext) -> [DailyReportRow] {
        let days = DateHelpers.daysBetween(start, end)
        return days.map { day in
            let totals = DiaryService.totals(for: day, context: context)
            let weight = GoalService.weightEntry(for: day, context: context)?.weightLbs
            let health = healthSnapshot(for: day, context: context)
            let active = health?.activeCalories ?? 0
            return DailyReportRow(
                date: day,
                calories: totals.calories,
                protein: totals.protein,
                carbs: totals.carbs,
                fat: totals.fat,
                weight: weight,
                steps: health?.steps ?? 0,
                activeCalories: active,
                netCalories: totals.calories - active
            )
        }
    }

    static func averages(rows: [DailyReportRow]) -> DailyReportRow? {
        guard !rows.isEmpty else { return nil }
        let count = Double(rows.count)
        return DailyReportRow(
            date: rows.first!.date,
            calories: rows.map(\.calories).reduce(0, +) / count,
            protein: rows.map(\.protein).reduce(0, +) / count,
            carbs: rows.map(\.carbs).reduce(0, +) / count,
            fat: rows.map(\.fat).reduce(0, +) / count,
            weight: rows.compactMap(\.weight).nilIfEmpty.map { $0.reduce(0, +) / Double($0.count) },
            steps: Int(Double(rows.map(\.steps).reduce(0, +)) / count),
            activeCalories: rows.map(\.activeCalories).reduce(0, +) / count,
            netCalories: rows.map(\.netCalories).reduce(0, +) / count
        )
    }

    static func comparePeriods(current: [DailyReportRow], previous: [DailyReportRow]) -> PeriodComparison? {
        guard let currentAvg = averages(rows: current), let previousAvg = averages(rows: previous) else { return nil }
        return PeriodComparison(
            caloriesDelta: currentAvg.calories - previousAvg.calories,
            proteinDelta: currentAvg.protein - previousAvg.protein,
            carbsDelta: currentAvg.carbs - previousAvg.carbs,
            fatDelta: currentAvg.fat - previousAvg.fat,
            weightDelta: {
                guard let c = currentAvg.weight, let p = previousAvg.weight else { return nil }
                return c - p
            }(),
            stepsDelta: Double(currentAvg.steps - previousAvg.steps)
        )
    }

    struct WeeklySummaryRow: Identifiable {
        var id: Int { weekNumber }
        var weekNumber: Int
        var weekOf: Date
        var stepsAverage: Double?
        var calorieAverage: Double?
        var weightAverage: Double?
        /// Average of days in the week that have a body-fat reading.
        var bodyFatAverage: Double?
        /// Week-over-week % change vs previous week's weight average. Nil for the first week.
        var weightChangePercent: Double?
    }

    /// Weekly averages from `start` through the week containing `end`, aligned to `weekStartsOn`.
    static func weeklySummaryRows(
        from start: Date,
        to end: Date,
        weekStartsOn: WeekStartDay,
        context: ModelContext
    ) -> [WeeklySummaryRow] {
        let rangeStart = DateHelpers.startOfDay(start)
        let rangeEnd = DateHelpers.startOfDay(end)
        guard rangeStart <= rangeEnd else { return [] }

        var weekStart = DateHelpers.weekStart(containing: rangeStart, weekStartsOn: weekStartsOn)
        var rows: [WeeklySummaryRow] = []
        var previousWeightAverage: Double?
        var weekNumber = 1
        let bodyFatEntries = (try? context.fetch(FetchDescriptor<BodyFatEntry>())) ?? []
        let progressPhotos = (try? context.fetch(FetchDescriptor<ProgressPhoto>())) ?? []

        while weekStart <= rangeEnd {
            let weekEnd = DateHelpers.weekEnd(containing: weekStart, weekStartsOn: weekStartsOn)
            let clampedStart = max(weekStart, rangeStart)
            let clampedEnd = min(weekEnd, rangeEnd)
            let daily = dailyRows(from: clampedStart, to: clampedEnd, context: context)

            let calorieDays = daily.filter { $0.calories > 0 }
            let calorieAverage = calorieDays.isEmpty
                ? nil
                : calorieDays.map(\.calories).reduce(0, +) / Double(calorieDays.count)

            let stepDays = daily.filter { $0.steps > 0 }
            let stepsAverage = stepDays.isEmpty
                ? nil
                : Double(stepDays.map(\.steps).reduce(0, +)) / Double(stepDays.count)

            let weights = daily.compactMap(\.weight)
            let weightAverage = weights.isEmpty
                ? nil
                : weights.reduce(0, +) / Double(weights.count)

            let bodyFats = GoalService.bodyFatSamples(
                from: clampedStart,
                to: clampedEnd,
                entries: bodyFatEntries,
                photos: progressPhotos
            ).map(\.percent)
            let bodyFatAverage = bodyFats.isEmpty
                ? nil
                : bodyFats.reduce(0, +) / Double(bodyFats.count)

            let weightChangePercent: Double?
            if let weightAverage, let previousWeightAverage, previousWeightAverage > 0 {
                weightChangePercent = ((weightAverage - previousWeightAverage) / previousWeightAverage) * 100
            } else {
                weightChangePercent = nil
            }

            rows.append(
                WeeklySummaryRow(
                    weekNumber: weekNumber,
                    weekOf: weekStart,
                    stepsAverage: stepsAverage,
                    calorieAverage: calorieAverage,
                    weightAverage: weightAverage,
                    bodyFatAverage: bodyFatAverage,
                    weightChangePercent: weightChangePercent
                )
            )

            if let weightAverage {
                previousWeightAverage = weightAverage
            }
            weekNumber += 1
            guard let next = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = next
        }

        return rows
    }

    /// Overall averages across weekly rows. Weight Δ % is the mean of week-over-week changes.
    static func weeklySummaryTotals(from rows: [WeeklySummaryRow]) -> WeeklySummaryRow? {
        guard !rows.isEmpty else { return nil }

        let steps = rows.compactMap(\.stepsAverage)
        let calories = rows.compactMap(\.calorieAverage)
        let weights = rows.compactMap(\.weightAverage)
        let bodyFats = rows.compactMap(\.bodyFatAverage)
        let weeklyChanges = rows.compactMap(\.weightChangePercent)

        return WeeklySummaryRow(
            weekNumber: 0,
            weekOf: rows.first!.weekOf,
            stepsAverage: steps.isEmpty ? nil : steps.reduce(0, +) / Double(steps.count),
            calorieAverage: calories.isEmpty ? nil : calories.reduce(0, +) / Double(calories.count),
            weightAverage: weights.isEmpty ? nil : weights.reduce(0, +) / Double(weights.count),
            bodyFatAverage: bodyFats.isEmpty ? nil : bodyFats.reduce(0, +) / Double(bodyFats.count),
            weightChangePercent: weeklyChanges.isEmpty
                ? nil
                : weeklyChanges.reduce(0, +) / Double(weeklyChanges.count)
        )
    }

    /// Earliest date to use for the weekly summary: active goal start, else earliest weight/food log.
    static func weeklySummaryAnchorDate(context: ModelContext) -> Date? {
        if let goal = GoalService.activeGoal(context: context) {
            return DateHelpers.startOfDay(goal.startDate)
        }

        let weights = (try? context.fetch(FetchDescriptor<WeightEntry>(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []
        let logs = (try? context.fetch(FetchDescriptor<LogEntry>(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []

        let candidates = [weights.first?.date, logs.first?.date].compactMap { $0 }
        guard let earliest = candidates.min() else { return nil }
        return DateHelpers.startOfDay(earliest)
    }

    private static func healthSnapshot(for date: Date, context: ModelContext) -> DailyHealthSnapshot? {
        let day = DateHelpers.startOfDay(date)
        let descriptor = FetchDescriptor<DailyHealthSnapshot>(
            predicate: #Predicate { $0.date == day }
        )
        return try? context.fetch(descriptor).first
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
