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

    /// One point per day that has a body-fat reading. The newest source that day wins.
    static func bodyFatSamples(from start: Date, to end: Date, context: ModelContext) -> [BodyFatSample] {
        let entries = (try? context.fetch(FetchDescriptor<BodyFatEntry>())) ?? []
        let photos = (try? context.fetch(FetchDescriptor<ProgressPhoto>())) ?? []
        return bodyFatSamples(from: start, to: end, entries: entries, photos: photos)
    }

    static func bodyFatSamples(
        from start: Date,
        to end: Date,
        entries: [BodyFatEntry],
        photos: [ProgressPhoto]
    ) -> [BodyFatSample] {
        DateHelpers.daysBetween(start, end).compactMap { day in
            guard let reading = resolvedBodyFat(on: day, entries: entries, photos: photos) else { return nil }
            return BodyFatSample(date: day, percent: reading.percent)
        }
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

    static func bodyFatEntry(for date: Date, context: ModelContext) -> BodyFatEntry? {
        let day = DateHelpers.startOfDay(date)
        let all = (try? context.fetch(FetchDescriptor<BodyFatEntry>())) ?? []
        return all.first { DateHelpers.isSameDay($0.date, day) }
    }

    static func saveBodyFat(_ percent: Double, for date: Date, context: ModelContext) {
        let day = DateHelpers.startOfDay(date)
        let recordedAt = Date()
        if let existing = bodyFatEntry(for: day, context: context) {
            existing.percent = percent
            existing.recordedAt = recordedAt
            existing.source = .manual
        } else {
            context.insert(BodyFatEntry(date: day, percent: percent, recordedAt: recordedAt, source: .manual))
        }
        try? context.save()
    }

    /// Applies a HealthKit body-fat sample when it is newer than the stored value for that day.
    @discardableResult
    static func applyHealthKitBodyFat(_ percent: Double, recordedAt: Date, for date: Date, context: ModelContext) -> Bool {
        let day = DateHelpers.startOfDay(date)
        if let existing = bodyFatEntry(for: day, context: context) {
            let localTime = existing.recordedAt ?? existing.date
            guard recordedAt > localTime else { return false }
            existing.percent = percent
            existing.recordedAt = recordedAt
            existing.source = .healthKit
        } else {
            context.insert(BodyFatEntry(date: day, percent: percent, recordedAt: recordedAt, source: .healthKit))
        }
        try? context.save()
        return true
    }

    /// Newest body-fat value for a calendar day across a manual/HealthKit entry and progress-photo estimates.
    static func resolvedBodyFat(
        on date: Date,
        entries: [BodyFatEntry],
        photos: [ProgressPhoto]
    ) -> BodyFatReading? {
        candidates(on: date, entries: entries, photos: photos).max { $0.recordedAt < $1.recordedAt }
    }

    static func mostRecentBodyFat(
        onOrBefore date: Date,
        entries: [BodyFatEntry],
        photos: [ProgressPhoto]
    ) -> BodyFatReading? {
        let day = DateHelpers.startOfDay(date)
        var readings: [BodyFatReading] = []
        for entry in entries where entry.date <= day {
            readings.append(reading(from: entry))
        }
        for photo in photos where photo.date <= day && photo.bodyFatPercent != nil {
            readings.append(reading(from: photo))
        }
        return readings.max { $0.recordedAt < $1.recordedAt }
    }

    private static func candidates(
        on date: Date,
        entries: [BodyFatEntry],
        photos: [ProgressPhoto]
    ) -> [BodyFatReading] {
        var readings: [BodyFatReading] = []
        if let entry = entries.first(where: { DateHelpers.isSameDay($0.date, date) }) {
            readings.append(reading(from: entry))
        }
        let dayPhotos = photos.filter { DateHelpers.isSameDay($0.date, date) && $0.bodyFatPercent != nil }
        if let photo = dayPhotos.max(by: { photoTime($0) < photoTime($1) }) {
            readings.append(reading(from: photo))
        }
        return readings
    }

    private static func reading(from entry: BodyFatEntry) -> BodyFatReading {
        BodyFatReading(
            percent: entry.percent,
            recordedAt: entry.recordedAt ?? entry.date,
            source: entry.source
        )
    }

    private static func reading(from photo: ProgressPhoto) -> BodyFatReading {
        BodyFatReading(
            percent: photo.bodyFatPercent ?? 0,
            recordedAt: photoTime(photo),
            source: .progressPhoto
        )
    }

    private static func photoTime(_ photo: ProgressPhoto) -> Date {
        photo.bodyFatEstimatedAt ?? photo.createdAt
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

struct BodyFatSample: Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var percent: Double
}

struct GoalMetrics {
    var progressPercent: Double = 0
    var timePercent: Double = 0
    var weeklyChangeLbs: Double?
    var weeklyPercentBodyWeight: Double?
    var projectedFinishDate: Date?
    var movingAverage: [(date: Date, value: Double)] = []
}
