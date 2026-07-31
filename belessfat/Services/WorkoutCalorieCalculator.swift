import Foundation
import SwiftData

enum WorkoutCalorieCalculator {
    /// kcal = MET × weightKg × durationHours
    static func calories(met: Double, weightLbs: Double, durationMinutes: Double) -> Double {
        guard met > 0, weightLbs > 0, durationMinutes > 0 else { return 0 }
        let weightKg = weightLbs / 2.20462
        let hours = durationMinutes / 60.0
        return met * weightKg * hours
    }

    static func estimatedDurationMinutes(
        setCount: Int,
        settings: WorkoutSettings,
        userDurationMinutes: Double?
    ) -> Double {
        if let userDurationMinutes, userDurationMinutes > 0 {
            return userDurationMinutes
        }
        guard setCount > 0 else { return 0 }
        return Double(setCount * settings.defaultSecondsPerSet) / 60.0
    }

    static func strengthCalories(
        session: WorkoutSession,
        weightLbs: Double,
        settings: WorkoutSettings
    ) -> Double {
        let workingSets = session.setLogs.filter { !$0.isWarmup }
        guard !workingSets.isEmpty else { return 0 }

        let duration = estimatedDurationMinutes(
            setCount: workingSets.count,
            settings: settings,
            userDurationMinutes: session.durationMinutes > 0 ? session.durationMinutes : nil
        )
        guard duration > 0 else { return 0 }

        var metWeightedSets = 0.0
        var totalMET = 0.0
        for setLog in workingSets {
            guard let exercise = setLog.exercise, let met = exercise.effectiveMET else { continue }
            metWeightedSets += 1
            totalMET += met
        }
        guard metWeightedSets > 0 else { return 0 }

        let averageMET = totalMET / metWeightedSets
        return calories(met: averageMET, weightLbs: weightLbs, durationMinutes: duration)
    }

    static func tennisSteps(durationMinutes: Double, workoutType: WorkoutType, settings: WorkoutSettings) -> Int {
        let stepsPerMin: Double
        switch workoutType {
        case .tennisSingles: stepsPerMin = settings.tennisSinglesStepsPerMin
        case .tennisDoubles: stepsPerMin = settings.tennisDoublesStepsPerMin
        default: return 0
        }
        return Int((durationMinutes * stepsPerMin).rounded())
    }

    static func tennisCalories(
        durationMinutes: Double,
        workoutType: WorkoutType,
        weightLbs: Double
    ) -> Double {
        let met: Double
        switch workoutType {
        case .tennisSingles: met = 8.0
        case .tennisDoubles: met = 6.0
        default: met = 7.3
        }
        return calories(met: met, weightLbs: weightLbs, durationMinutes: durationMinutes)
    }

    static func treadmillSteps(
        speedMph: Double,
        durationMinutes: Double,
        strideLengthFeet: Double
    ) -> Int {
        guard speedMph > 0, durationMinutes > 0, strideLengthFeet > 0 else { return 0 }
        let hours = durationMinutes / 60.0
        let distanceFeet = speedMph * 5280 * hours
        return Int((distanceFeet / strideLengthFeet).rounded())
    }

    static func treadmillCalories(
        speedMph: Double,
        durationMinutes: Double,
        inclinePercent: Double,
        weightLbs: Double
    ) -> Double {
        guard speedMph > 0, durationMinutes > 0, weightLbs > 0 else { return 0 }
        // Approximate MET from speed and incline (ACSM walking/running formulas simplified).
        let baseMET: Double
        if speedMph < 4.0 {
            baseMET = 2.0 + speedMph * 0.7
        } else {
            baseMET = 3.5 + speedMph * 0.8
        }
        let inclineBonus = inclinePercent * 0.04
        let met = baseMET + inclineBonus
        return calories(met: met, weightLbs: weightLbs, durationMinutes: durationMinutes)
    }
}
