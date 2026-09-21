import Foundation
import SwiftData

@Model
final class Food {
    var id: UUID
    var name: String
    var brand: String?
    var sourceRaw: String
    var barcode: String?
    var externalId: String?

    var caloriesPer100g: Double
    var proteinPer100g: Double
    var carbsPer100g: Double
    var fatPer100g: Double

    var servingSizeGrams: Double
    var servingDescription: String?
    var caloriesPerServing: Double
    var proteinPerServing: Double
    var carbsPerServing: Double
    var fatPerServing: Double

    var smallServingGrams: Double?
    var mediumServingGrams: Double?
    var largeServingGrams: Double?
    var teaspoonGrams: Double?
    var tablespoonGrams: Double?
    var cupGrams: Double?

    var isAlcohol: Bool
    var createdAt: Date

    var source: FoodSource {
        get { FoodSource(rawValue: sourceRaw) ?? .custom }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        name: String,
        brand: String? = nil,
        source: FoodSource = .custom,
        barcode: String? = nil,
        externalId: String? = nil,
        caloriesPer100g: Double = 0,
        proteinPer100g: Double = 0,
        carbsPer100g: Double = 0,
        fatPer100g: Double = 0,
        servingSizeGrams: Double = 100,
        servingDescription: String? = nil,
        caloriesPerServing: Double = 0,
        proteinPerServing: Double = 0,
        carbsPerServing: Double = 0,
        fatPerServing: Double = 0,
        smallServingGrams: Double? = nil,
        mediumServingGrams: Double? = nil,
        largeServingGrams: Double? = nil,
        teaspoonGrams: Double? = nil,
        tablespoonGrams: Double? = nil,
        cupGrams: Double? = nil,
        isAlcohol: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.brand = brand
        self.sourceRaw = source.rawValue
        self.barcode = barcode
        self.externalId = externalId
        self.caloriesPer100g = caloriesPer100g
        self.proteinPer100g = proteinPer100g
        self.carbsPer100g = carbsPer100g
        self.fatPer100g = fatPer100g
        self.servingSizeGrams = servingSizeGrams
        self.servingDescription = servingDescription
        self.caloriesPerServing = caloriesPerServing
        self.proteinPerServing = proteinPerServing
        self.carbsPerServing = carbsPerServing
        self.fatPerServing = fatPerServing
        self.smallServingGrams = smallServingGrams
        self.mediumServingGrams = mediumServingGrams
        self.largeServingGrams = largeServingGrams
        self.teaspoonGrams = teaspoonGrams
        self.tablespoonGrams = tablespoonGrams
        self.cupGrams = cupGrams
        self.isAlcohol = isAlcohol
        self.createdAt = Date()
    }

    var displayName: String {
        if let brand, !brand.isEmpty {
            return "\(name) (\(brand))"
        }
        return name
    }

    func macros(for quantity: Double, unit: ServingUnitType) -> MacroTotals {
        if unit == .serving, caloriesPerServing > 0 || proteinPerServing > 0 || carbsPerServing > 0 || fatPerServing > 0 {
            return MacroTotals(
                calories: caloriesPerServing * quantity,
                protein: proteinPerServing * quantity,
                carbs: carbsPerServing * quantity,
                fat: fatPerServing * quantity
            )
        }
        let grams = ServingConverter.gramsAmount(quantity: quantity, unit: unit, food: self)
        let factor = grams / 100.0
        return MacroTotals(
            calories: caloriesPer100g * factor,
            protein: proteinPer100g * factor,
            carbs: carbsPer100g * factor,
            fat: fatPer100g * factor
        )
    }

    var availableServingUnits: [ServingUnitType] {
        if hasMeaningfulServingUnit, servingSizeGrams <= 0 {
            return [.serving]
        }
        var units: [ServingUnitType] = []
        if servingSizeGrams > 0 {
            units.append(contentsOf: [.grams, .ounces])
        }
        if teaspoonGrams != nil { units.append(.teaspoon) }
        if tablespoonGrams != nil { units.append(.tablespoon) }
        if cupGrams != nil { units.append(.cup) }
        if hasMeaningfulServingUnit {
            units.append(.serving)
        }
        if smallServingGrams != nil { units.append(.small) }
        if mediumServingGrams != nil { units.append(.medium) }
        if largeServingGrams != nil { units.append(.large) }
        return units.isEmpty ? [.serving] : units
    }

    /// Quantity and unit used when last-logged serving is unknown.
    func defaultLoggingAmount() -> (quantity: Double, unit: ServingUnitType) {
        let available = availableServingUnits
        let unit: ServingUnitType
        if source == .usda, available.contains(.grams) {
            unit = .grams
        } else if available.contains(.tablespoon) {
            unit = .tablespoon
        } else if available.contains(.teaspoon) {
            unit = .teaspoon
        } else if available.contains(.medium) {
            unit = .medium
        } else if available.contains(.serving) {
            unit = .serving
        } else if available.contains(.cup) {
            unit = .cup
        } else {
            unit = available.first ?? .grams
        }
        let quantity: Double
        switch unit {
        case .grams: quantity = 100
        default: quantity = 1
        }
        return (quantity, unit)
    }

    private var hasMeaningfulServingUnit: Bool {
        guard caloriesPerServing > 0 || proteinPerServing > 0 || carbsPerServing > 0 || fatPerServing > 0 else { return false }
        if let desc = servingDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return true
        }
        guard servingSizeGrams > 0 else { return false }
        let hasVolumeUnits = tablespoonGrams != nil || teaspoonGrams != nil || cupGrams != nil
        if hasVolumeUnits {
            return false
        }
        return servingSizeGrams != 100
    }
}

extension Food: Identifiable {}

struct MacroTotals: Equatable {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double

    static let zero = MacroTotals(calories: 0, protein: 0, carbs: 0, fat: 0)

    static func + (lhs: MacroTotals, rhs: MacroTotals) -> MacroTotals {
        MacroTotals(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat
        )
    }
}
