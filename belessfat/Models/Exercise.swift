import Foundation
import SwiftData

@Model
final class Exercise {
    var id: UUID
    var wgerId: Int?
    var name: String
    var categoryName: String?
    var muscleNames: String?
    var equipmentNames: String?
    var metValue: Double?
    var isCustom: Bool
    var createdAt: Date

    init(
        name: String,
        wgerId: Int? = nil,
        categoryName: String? = nil,
        muscleNames: String? = nil,
        equipmentNames: String? = nil,
        metValue: Double? = nil,
        isCustom: Bool = false
    ) {
        self.id = UUID()
        self.wgerId = wgerId
        self.name = name
        self.categoryName = categoryName
        self.muscleNames = muscleNames
        self.equipmentNames = equipmentNames
        self.metValue = metValue
        self.isCustom = isCustom
        self.createdAt = Date()
    }

    var effectiveMET: Double? {
        if let metValue { return metValue }
        return ExerciseMETDefaults.met(forCategory: categoryName)
    }

    var hasCalorieMetadata: Bool {
        effectiveMET != nil
    }
}

enum ExerciseMETDefaults {
    /// Compendium-based defaults when wger exercises lack MET data.
    static func met(forCategory category: String?) -> Double? {
        guard let category else { return defaultStrengthMET }
        let lower = category.lowercased()
        if lower.contains("cardio") { return 7.0 }
        if lower.contains("stretch") || lower.contains("yoga") { return 3.0 }
        return defaultStrengthMET
    }

    static let defaultStrengthMET = 5.0
}
