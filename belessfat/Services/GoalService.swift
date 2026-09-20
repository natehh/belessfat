import Foundation
import SwiftData

@MainActor
enum GoalService {
    static func settings(context: ModelContext) -> UserSettings {
        let descriptor = FetchDescriptor<UserSettings>()
        let all = (try? context.fetch(descriptor)) ?? []
        if all.count > 1 {
            for duplicate in all.dropFirst() {
                context.delete(duplicate)
            }
        }
        if let existing = all.first {
            existing.normalizeDefaults()
            try? context.save()
            return existing
        }
        let settings = UserSettings()
        context.insert(settings)
        try? context.save()
        return settings
    }

    static func weightEntry(for date: Date, context: ModelContext) -> WeightEntry? {
        let day = DateHelpers.startOfDay(date)
        let all = (try? context.fetch(FetchDescriptor<WeightEntry>())) ?? []
        return all.first { DateHelpers.isSameDay($0.date, day) }
    }

    static func saveWeight(_ lbs: Double, for date: Date, context: ModelContext) {
        let day = DateHelpers.startOfDay(date)
        let recordedAt = Date()
        if let existing = weightEntry(for: day, context: context) {
            existing.weightLbs = lbs
            existing.recordedAt = recordedAt
            existing.source = .manual
        } else {
            context.insert(WeightEntry(date: day, weightLbs: lbs, recordedAt: recordedAt, source: .manual))
        }
        try? context.save()
    }

    /// Applies a HealthKit sample if it is newer than the local value for that day.
    /// Legacy rows with no `recordedAt` use the calendar day, not `Date()`, so a just-logged
    /// HealthKit weigh-in can still win. Older samples on that day do not clobber a timestamped save.
    @discardableResult
    static func applyHealthKitWeight(_ lbs: Double, recordedAt: Date, for date: Date, context: ModelContext) -> Bool {
        let day = DateHelpers.startOfDay(date)
        if let existing = weightEntry(for: day, context: context) {
            let localTime = existing.recordedAt ?? existing.date
            guard recordedAt > localTime else { return false }
            existing.weightLbs = lbs
            existing.recordedAt = recordedAt
            existing.source = .healthKit
        } else {
            context.insert(WeightEntry(date: day, weightLbs: lbs, recordedAt: recordedAt, source: .healthKit))
        }
        try? context.save()
        return true
    }

    static func weightEntries(from start: Date, to end: Date, context: ModelContext) -> [WeightEntry] {
        let startDay = DateHelpers.startOfDay(start)
        let endDay = DateHelpers.startOfDay(end)
        let all = (try? context.fetch(FetchDescriptor<WeightEntry>(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []
        return all.filter { $0.date >= startDay && $0.date <= endDay }
    }

    static func sevenDayAverageWeight(for date: Date, context: ModelContext) -> Double? {
        let day = DateHelpers.startOfDay(date)
        guard let start = Calendar.current.date(byAdding: .day, value: -6, to: day) else { return nil }
        let entries = weightEntries(from: start, to: day, context: context)
        guard !entries.isEmpty else { return nil }
        return entries.map(\.weightLbs).reduce(0, +) / Double(entries.count)
    }

    static func mostRecentWeight(onOrBefore date: Date, context: ModelContext) -> Double? {
        let day = DateHelpers.startOfDay(date)
        let all = (try? context.fetch(FetchDescriptor<WeightEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))) ?? []
        return all.first { $0.date <= day }?.weightLbs
    }

    static func activeGoal(context: ModelContext) -> WeightGoal? {
        let all = (try? context.fetch(FetchDescriptor<WeightGoal>(
            sortBy: [SortDescriptor(\.targetDate, order: .reverse)]
        ))) ?? []
        return all.first(where: \.isActive) ?? all.first
    }

    static func goalMetrics(
        currentWeight: Double?,
        goal: WeightGoal?,
        entries: [WeightEntry],
        asOf date: Date = Date()
    ) -> GoalMetrics {
        guard let goal else {
            return GoalMetrics()
        }
        let current = currentWeight ?? goal.startWeightLbs
        let weeklyChange = MacroCalculator.averageWeeklyWeightChange(
            startWeight: goal.startWeightLbs,
            currentWeight: current,
            startDate: goal.startDate,
            asOf: date
        )
        let weeklyPercent = MacroCalculator.averageWeeklyPercentBodyWeightChange(
            startWeight: goal.startWeightLbs,
            currentWeight: current,
            startDate: goal.startDate,
            asOf: date
        )
        return GoalMetrics(
            progressPercent: MacroCalculator.weightProgressPercent(current: current, start: goal.startWeightLbs, goal: goal.goalWeightLbs),
            timePercent: DateHelpers.timeProgressPercent(from: goal.startDate, to: goal.targetDate),
            weeklyChangeLbs: weeklyChange,
            weeklyPercentBodyWeight: weeklyPercent,
            projectedFinishDate: weeklyChange.map { MacroCalculator.projectedFinishDate(current: current, goal: goal.goalWeightLbs, weeklyRate: $0) } ?? nil,
            movingAverage: MacroCalculator.movingAverage(entries: entries)
        )
    }
}

struct GoalMetrics {
    var progressPercent: Double = 0
    var timePercent: Double = 0
    var weeklyChangeLbs: Double?
    var weeklyPercentBodyWeight: Double?
    var projectedFinishDate: Date?
    var movingAverage: [(date: Date, value: Double)] = []
}
