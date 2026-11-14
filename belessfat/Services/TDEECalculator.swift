import Foundation
import SwiftData

@MainActor
enum TDEECalculator {
    /// 3500 kcal ≈ 1 lb body weight
    static let kcalPerPound = 3500.0
    static let lookbackDays = 28
    static let weightSmoothingWindow = 7

    struct DayPoint: Identifiable, Equatable {
        var id: Date { date }
        var date: Date
        var calories: Double?
        var weightLbs: Double?
        var isIncluded: Bool

        var detail: String {
            var parts: [String] = []
            if let calories {
                parts.append("\(Int(calories.rounded())) kcal")
            }
            if let weightLbs {
                parts.append("\(weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs")
            }
            return parts.joined(separator: " · ")
        }
    }

    struct Result {
        var estimate: Estimate?
        var days: [DayPoint]
        var lookbackDays: Int
        var excludedCount: Int

        var usesAllDays: Bool { excludedCount == 0 }
    }

    struct Estimate {
        var averageDailyCalories: Double
        var dailyWeightChangeLbs: Double
        var estimatedTDEE: Double
        var dayCount: Int
        var weightEntryCount: Int
        var lookbackDays: Int
        var isProvisional: Bool

        var weeklyWeightChangeLbs: Double {
            dailyWeightChangeLbs * 7
        }

        /// Positive = eating above estimated maintenance (surplus).
        var calorieGap: Double {
            averageDailyCalories - estimatedTDEE
        }

        var weightTrendLabel: String {
            let weekly = weeklyWeightChangeLbs
            if abs(weekly) < 0.15 {
                return "Holding steady"
            }
            if weekly < 0 {
                let amount = abs(weekly).formatted(.number.precision(.fractionLength(1)))
                return "Down \(amount) lbs/week"
            }
            let amount = weekly.formatted(.number.precision(.fractionLength(1)))
            return "Up \(amount) lbs/week"
        }

        var eatVsBurnLabel: String {
            let gap = Int(abs(calorieGap).rounded())
            if gap < 50 {
                return "About even with maintenance"
            }
            if calorieGap > 0 {
                return "+\(gap) kcal/day above maintenance"
            }
            return "\(gap) kcal/day below maintenance"
        }
    }

    /// Pure calculation from the current 28-day window — never writes weight or food logs.
    static func estimate(context: ModelContext) -> Result? {
        let end = DateHelpers.startOfDay(Date())
        guard let start = Calendar.current.date(byAdding: .day, value: -(lookbackDays - 1), to: end) else { return nil }

        let days = DateHelpers.daysBetween(start, end)
        guard days.count >= weightSmoothingWindow else { return nil }

        let excluded = TDEEExcludedDays.pruned(to: start...end)
        let weights = GoalService.weightEntries(from: start, to: end, context: context)
        var weightByDay: [Date: Double] = [:]
        for entry in weights {
            weightByDay[DateHelpers.startOfDay(entry.date)] = entry.weightLbs
        }

        var points: [DayPoint] = []
        for day in days {
            let calories = DiaryService.totals(for: day, context: context).calories
            let weight = weightByDay[day]
            let hasFood = calories > 0
            guard hasFood || weight != nil else { continue }
            points.append(DayPoint(
                date: day,
                calories: hasFood ? calories : nil,
                weightLbs: weight,
                isIncluded: !excluded.contains(day)
            ))
        }
        guard !points.isEmpty else { return nil }

        let includedDays = Set(points.filter(\.isIncluded).map(\.date))
        let loggedCalories = points.compactMap { point -> Double? in
            guard includedDays.contains(point.date) else { return nil }
            guard CalorieTrackingDays.shared.countsTowardCalorieAverages(
                on: point.date,
                hasFood: point.calories != nil
            ) else { return nil }
            return point.calories
        }
        let includedWeights = weights.filter { includedDays.contains(DateHelpers.startOfDay($0.date)) }
        let averageDailyCalories = loggedCalories.isEmpty
            ? nil
            : loggedCalories.reduce(0, +) / Double(loggedCalories.count)
        let dailyWeightChange = regressionDailyWeightChange(days: days, entries: includedWeights, skipping: excluded)

        let estimate: Estimate?
        if let averageDailyCalories, loggedCalories.count >= 3,
           includedWeights.count >= 2, let dailyWeightChange {
            let dailyCalorieBalance = dailyWeightChange * kcalPerPound
            estimate = Estimate(
                averageDailyCalories: averageDailyCalories,
                dailyWeightChangeLbs: dailyWeightChange,
                estimatedTDEE: max(averageDailyCalories - dailyCalorieBalance, 800),
                dayCount: loggedCalories.count,
                weightEntryCount: includedWeights.count,
                lookbackDays: lookbackDays,
                isProvisional: loggedCalories.count < 7 || includedWeights.count < 5
            )
        } else {
            estimate = nil
        }

        return Result(
            estimate: estimate,
            days: points.reversed(),
            lookbackDays: lookbackDays,
            excludedCount: points.filter { !$0.isIncluded }.count
        )
    }

    /// Linear regression slope (lbs/day) on 7-day smoothed, forward-filled daily weights.
    /// Skipped days contribute neither a weigh-in nor a point on the line.
    private static func regressionDailyWeightChange(
        days: [Date],
        entries: [WeightEntry],
        skipping excluded: Set<Date>
    ) -> Double? {
        let sorted = entries.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return nil }

        var forwardFilled: [Double?] = []
        var entryIndex = 0
        var latest: Double?
        for day in days {
            if excluded.contains(day) {
                forwardFilled.append(nil)
                continue
            }
            while entryIndex < sorted.count, sorted[entryIndex].date <= day {
                latest = sorted[entryIndex].weightLbs
                entryIndex += 1
            }
            forwardFilled.append(latest)
        }

        let smoothed = movingAverageNullable(forwardFilled, window: weightSmoothingWindow)
        var points: [(x: Double, y: Double)] = []
        for (index, value) in smoothed.enumerated() {
            if let value {
                points.append((Double(index), value))
            }
        }
        guard points.count >= weightSmoothingWindow else { return nil }
        return linearRegressionSlope(points)
    }

    private static func movingAverageNullable(_ values: [Double?], window: Int) -> [Double?] {
        values.indices.map { index in
            guard values[index] != nil else { return nil }
            let start = max(0, index - window + 1)
            let slice = (start...index).compactMap { values[$0] }
            guard !slice.isEmpty else { return nil }
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    private static func linearRegressionSlope(_ points: [(x: Double, y: Double)]) -> Double? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let sumX = points.map(\.x).reduce(0, +)
        let sumY = points.map(\.y).reduce(0, +)
        let sumXY = points.reduce(0) { $0 + $1.x * $1.y }
        let sumXX = points.reduce(0) { $0 + $1.x * $1.x }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 0.0001 else { return nil }
        return (n * sumXY - sumX * sumY) / denominator
    }
}

enum TDEEExcludedDays {
    private static let key = "tdeeExcludedDayStarts"

    static func current() -> Set<Date> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(date(from:)))
    }

    /// Drops exclusions that have aged out of the active window.
    static func pruned(to window: ClosedRange<Date>) -> Set<Date> {
        let kept = current().filter { window.contains($0) }
        if kept.count != current().count {
            replace(with: kept)
        }
        return kept
    }

    static func setIncluded(_ included: Bool, day: Date) {
        var days = current()
        let day = DateHelpers.startOfDay(day)
        if included {
            days.remove(day)
        } else {
            days.insert(day)
        }
        replace(with: days)
    }

    static func replace(with days: Set<Date>) {
        let values = days.map(string(from:)).sorted()
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(values, forKey: key)
        }
    }

    private static func string(from date: Date) -> String {
        formatter.string(from: DateHelpers.startOfDay(date))
    }

    private static func date(from string: String) -> Date? {
        formatter.date(from: string).map(DateHelpers.startOfDay)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
