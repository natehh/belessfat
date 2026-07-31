import Foundation
import Combine
import HealthKit
import SwiftData
import os

@MainActor
final class HealthKitService: ObservableObject {
    static let workoutSourceName = "belessfat Workout"
    private static let log = Logger(subsystem: "com.belessfat.app", category: "HealthKit")

    private let store = HKHealthStore()
    @Published var isAuthorized = false
    @Published var canWrite = false
    @Published var authorizationDenied = false
    @Published var lastSyncMessage: String?
    @Published private(set) var cachedSteps = 0
    @Published private(set) var cachedActiveCalories = 0.0
    @Published private(set) var cachedDate = Date()

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    private var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        if let workout = HKObjectType.workoutType() as HKSampleType? {
            types.insert(workout)
        }
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let active = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(active)
        }
        return types
    }

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let active = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(active)
        }
        return types
    }

    func refreshAuthorizationStatus() {
        authorizationDenied = false
    }

    func requestAuthorization(context: ModelContext) async {
        await requestAuthorization(includeWrite: false, context: context)
    }

    func requestWriteAuthorization(context: ModelContext) async {
        await requestAuthorization(includeWrite: true, context: context)
    }

    private func requestAuthorization(includeWrite: Bool, context: ModelContext) async {
        guard isAvailable else { return }

        let toShare: Set<HKSampleType> = includeWrite ? shareTypes : []
        do {
            try await store.requestAuthorization(toShare: toShare, read: readTypes)
            authorizationDenied = false
            refreshWriteAuthorization()
            if includeWrite && !canWrite {
                lastSyncMessage = "Enable Steps and Workouts for belessfat in Settings › Health to sync workouts."
            }
            await sync(for: Date(), context: context)
        } catch {
            authorizationDenied = true
            lastSyncMessage = "HealthKit authorization failed."
        }
    }

    /// Reflects actual per-type share (write) status rather than assuming the request was granted.
    func refreshWriteAuthorization() {
        guard isAvailable else {
            canWrite = false
            return
        }
        canWrite = canShareSteps && canShareWorkouts
    }

    private var canShareSteps: Bool {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return false }
        return store.authorizationStatus(for: stepType) == .sharingAuthorized
    }

    private var canShareWorkouts: Bool {
        store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    func sync(for date: Date, context: ModelContext) async {
        await sync(from: date, to: date, context: context)
    }

    func sync(from start: Date, to end: Date, context: ModelContext) async {
        guard isAvailable else {
            lastSyncMessage = "HealthKit is not available on this device."
            return
        }

        let startDay = DateHelpers.startOfDay(start)
        let endDay = DateHelpers.startOfDay(end)
        let days = DateHelpers.daysBetween(startDay, endDay)
        guard !days.isEmpty else { return }

        var daysWithData = 0
        var totalSteps = 0
        for day in days {
            let steps = await fetchSteps(for: day)
            let active = await fetchActiveCalories(for: day)
            saveSnapshot(date: day, steps: steps, activeCalories: active, context: context)
            if steps > 0 || active > 0 {
                daysWithData += 1
            }
            totalSteps += steps
        }

        let today = DateHelpers.startOfDay(Date())
        if days.contains(where: { DateHelpers.isSameDay($0, today) }) {
            cachedSteps = await fetchSteps(for: today)
            cachedActiveCalories = await fetchActiveCalories(for: today)
            cachedDate = today
        }

        isAuthorized = true
        authorizationDenied = false
        if days.count == 1 {
            if totalSteps > 0 {
                lastSyncMessage = "Synced \(totalSteps) steps."
            } else {
                lastSyncMessage = "No step data returned for this day."
            }
        } else {
            lastSyncMessage = "Synced \(days.count) days (\(daysWithData) with HealthKit data, \(totalSteps) total steps)."
        }
    }

    struct WorkoutSyncResult {
        var workoutUUID: UUID?
        var stepSampleUUID: UUID?

        var didSaveAnything: Bool { workoutUUID != nil || stepSampleUUID != nil }
    }

    func saveWorkout(
        activityType: HKWorkoutActivityType,
        start: Date,
        end: Date,
        calories: Double?,
        steps: Int?
    ) async -> WorkoutSyncResult? {
        guard isAvailable else {
            Self.log.error("saveWorkout aborted: HealthKit unavailable")
            return nil
        }

        Self.log.info("saveWorkout begin: activity=\(activityType.rawValue) steps=\(steps ?? -1) calories=\(calories ?? -1) start=\(start.description) end=\(end.description)")

        // Write steps independently so a workout-builder failure can't silently drop them,
        // and vice versa. Each path reports its own outcome.
        var stepSampleUUID: UUID?
        var stepsRequested = false
        var workoutSaved = true

        if let steps, steps > 0 {
            stepsRequested = true
            stepSampleUUID = await saveSteps(steps, start: start, end: end)
        }

        var workoutUUID: UUID?
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            if let calories, calories > 0,
               let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                let sample = HKQuantitySample(
                    type: energyType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: calories),
                    start: start,
                    end: end
                )
                try await builder.addSamples([sample])
            }
            try await builder.endCollection(at: end)
            let workout = try await builder.finishWorkout()
            workoutUUID = workout?.uuid
            Self.log.info("saveWorkout: workout builder finished OK uuid=\(workout?.uuid.uuidString ?? "nil", privacy: .public)")
        } catch {
            workoutSaved = false
            Self.log.error("saveWorkout: workout builder FAILED: \(error.localizedDescription, privacy: .public)")
        }

        let stepsSaved = !stepsRequested || stepSampleUUID != nil
        switch (workoutSaved, stepsSaved) {
        case (true, true):
            lastSyncMessage = "Workout synced to Apple Health."
        case (true, false):
            lastSyncMessage = "Workout synced, but steps failed. Enable Steps for belessfat in Settings › Health."
        case (false, true):
            lastSyncMessage = "Steps synced, but the workout failed to save to Apple Health."
        case (false, false):
            lastSyncMessage = "Failed to sync to Apple Health. Enable Steps and Workouts for belessfat in Settings › Health."
        }

        let result = WorkoutSyncResult(workoutUUID: workoutUUID, stepSampleUUID: stepSampleUUID)
        return result.didSaveAnything ? result : nil
    }

    private func saveSteps(_ steps: Int, start: Date, end: Date) async -> UUID? {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            Self.log.error("saveSteps: stepCount type unavailable")
            return nil
        }
        let status = store.authorizationStatus(for: stepType)
        Self.log.info("saveSteps: authorizationStatus=\(status.rawValue) (2 == sharingAuthorized) steps=\(steps)")
        guard status == .sharingAuthorized else {
            Self.log.error("saveSteps: NOT authorized to share steps (status=\(status.rawValue)); skipping write")
            return nil
        }

        let stepSample = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: .count(), doubleValue: Double(steps)),
            start: start,
            end: end,
            metadata: [HKMetadataKeyWasUserEntered: true]
        )
        do {
            try await store.save(stepSample)
            Self.log.info("saveSteps: SUCCESS wrote \(steps) steps uuid=\(stepSample.uuid.uuidString, privacy: .public)")
            return stepSample.uuid
        } catch {
            Self.log.error("saveSteps: store.save FAILED: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Removes the specific workout and step samples belessfat previously wrote for a session.
    func deleteSyncedWorkout(workoutId: String?, stepSampleId: String?) async {
        guard isAvailable else { return }

        if let workoutId, let uuid = UUID(uuidString: workoutId) {
            let predicate = HKQuery.predicateForObject(with: uuid)
            do {
                let deleted = try await store.deleteObjects(of: .workoutType(), predicate: predicate)
                Self.log.info("deleteSyncedWorkout: removed \(deleted) workout object(s)")
            } catch {
                Self.log.error("deleteSyncedWorkout: workout delete FAILED: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let stepSampleId, let uuid = UUID(uuidString: stepSampleId),
           let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let predicate = HKQuery.predicateForObject(with: uuid)
            do {
                let deleted = try await store.deleteObjects(of: stepType, predicate: predicate)
                Self.log.info("deleteSyncedWorkout: removed \(deleted) step sample(s)")
            } catch {
                Self.log.error("deleteSyncedWorkout: step delete FAILED: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func fetchSteps(for date: Date) async -> Int {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return 0 }
        return Int(await fetchSum(for: type, date: date, unit: .count()))
    }

    func fetchActiveCalories(for date: Date) async -> Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return 0 }
        return await fetchSum(for: type, date: date, unit: .kilocalorie())
    }

    private func fetchSum(for type: HKQuantityType, date: Date, unit: HKUnit) async -> Double {
        let start = DateHelpers.startOfDay(date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                let value = stats?.sumQuantity()?.doubleValue(for: unit) ?? 0
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func saveSnapshot(date: Date, steps: Int, activeCalories: Double, context: ModelContext) {
        let day = DateHelpers.startOfDay(date)
        let descriptor = FetchDescriptor<DailyHealthSnapshot>()
        let snapshots = (try? context.fetch(descriptor)) ?? []
        if let existing = snapshots.first(where: { DateHelpers.isSameDay($0.date, day) }) {
            existing.steps = steps
            existing.activeCalories = activeCalories
        } else {
            context.insert(DailyHealthSnapshot(date: day, steps: steps, activeCalories: activeCalories))
        }
        try? context.save()
    }
}
