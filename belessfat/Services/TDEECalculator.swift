import Foundation
import SwiftData

@MainActor
enum TDEECalculator {
    /// 3500 kcal ≈ 1 lb body weight
    static let kcalPerPound = 3500.0
    static let lookbackDays = 28
    static let weightSmoothingWindow = 7

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

    /// Pure calculation from the current 28-day window — never writes to the context.
    static func estimate(context: ModelContext) -> Estimate? {
        let end = DateHelpers.startOfDay(Date())
        guard let start = Calendar.current.date(byAdding: .day, value: -(lookbackDays - 1), to: end) else { return nil }

        let days = DateHelpers.daysBetween(start, end)
        guard days.count >= weightSmoothingWindow else { return nil }

        let loggedCalories = days.map { DiaryService.totals(for: $0, context: context).calories }.filter { $0 > 0 }
        guard loggedCalories.count >= 3 else { return nil }
        let averageDailyCalories = loggedCalories.reduce(0, +) / Double(loggedCalories.count)

        let weights = GoalService.weightEntries(from: start, to: end, context: context)
        guard weights.count >= 2,
              let dailyWeightChange = regressionDailyWeightChange(days: days, entries: weights) else { return nil }

        let dailyCalorieBalance = dailyWeightChange * kcalPerPound
        let estimatedTDEE = max(averageDailyCalories - dailyCalorieBalance, 800)

        let isProvisional = loggedCalories.count < 7 || weights.count < 5

        return Estimate(
            averageDailyCalories: averageDailyCalories,
            dailyWeightChangeLbs: dailyWeightChange,
            estimatedTDEE: estimatedTDEE,
            dayCount: loggedCalories.count,
            weightEntryCount: weights.count,
            lookbackDays: lookbackDays,
            isProvisional: isProvisional
        )
    }

    /// Linear regression slope (lbs/day) on 7-day smoothed, forward-filled daily weights.
    private static func regressionDailyWeightChange(days: [Date], entries: [WeightEntry]) -> Double? {
        let sorted = entries.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return nil }

        var forwardFilled: [Double?] = []
        var entryIndex = 0
        var latest: Double?
        for day in days {
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
