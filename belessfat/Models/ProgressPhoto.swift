import Foundation
import SwiftData

@Model
final class ProgressPhoto {
    var id: UUID
    var date: Date
    var createdAt: Date
    var imageFilename: String
    /// Logged weight on `date`, if one existed when the photo was taken.
    var weightLbs: Double?
    /// 7-day average ending on `date`; stored only when no daily weight was logged.
    var weight7DayAvgLbs: Double?
    /// AI body-fat % for this photo’s day batch (same value on all photos that day).
    var bodyFatPercent: Double?
    var bodyFatEstimatedAt: Date?

    init(
        date: Date,
        imageFilename: String,
        weightLbs: Double? = nil,
        weight7DayAvgLbs: Double? = nil,
        bodyFatPercent: Double? = nil,
        bodyFatEstimatedAt: Date? = nil
    ) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.createdAt = Date()
        self.imageFilename = imageFilename
        self.weightLbs = weightLbs
        self.weight7DayAvgLbs = weight7DayAvgLbs
        self.bodyFatPercent = bodyFatPercent
        self.bodyFatEstimatedAt = bodyFatEstimatedAt
    }

    var weightLabel: String? {
        if let weightLbs {
            return "\(weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs"
        }
        if let weight7DayAvgLbs {
            return "7-day avg \(weight7DayAvgLbs.formatted(.number.precision(.fractionLength(1)))) lbs"
        }
        return nil
    }

    var bodyFatLabel: String? {
        guard let bodyFatPercent else { return nil }
        return "\(bodyFatPercent.formatted(.number.precision(.fractionLength(1))))% BF"
    }
}

extension ProgressPhoto: Identifiable {}
