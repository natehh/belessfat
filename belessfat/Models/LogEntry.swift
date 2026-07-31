import Foundation
import SwiftData

@Model
final class LogEntry {
    var id: UUID
    var date: Date
    var mealCategoryRaw: String
    var quantity: Double
    var servingUnitRaw: String
    var food: Food?
    var recipe: Recipe?
    var createdAt: Date

    /// Preserved when the linked food/recipe is deleted so diary history stays intact.
    var snapshotName: String?
    var snapshotCaloriesPerQuantity: Double = 0
    var snapshotProteinPerQuantity: Double = 0
    var snapshotCarbsPerQuantity: Double = 0
    var snapshotFatPerQuantity: Double = 0

    var hasSnapshot: Bool { snapshotName != nil }

    var mealCategory: MealCategory {
        get { MealCategory(rawValue: mealCategoryRaw) ?? .uncategorized }
        set { mealCategoryRaw = newValue.rawValue }
    }

    var servingUnit: ServingUnitType {
        get { ServingUnitType(rawValue: servingUnitRaw) ?? .grams }
        set { servingUnitRaw = newValue.rawValue }
    }

    init(
        date: Date,
        mealCategory: MealCategory,
        quantity: Double,
        servingUnit: ServingUnitType,
        food: Food? = nil,
        recipe: Recipe? = nil
    ) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.mealCategoryRaw = mealCategory.rawValue
        self.quantity = quantity
        self.servingUnitRaw = servingUnit.rawValue
        self.food = food
        self.recipe = recipe
        self.createdAt = Date()
    }

    var displayName: String {
        if let snapshotName { return snapshotName }
        if let recipe { return recipe.name }
        if let food { return food.displayName }
        return "Unknown"
    }

    var macros: MacroTotals {
        if hasSnapshot {
            return MacroTotals(
                calories: snapshotCaloriesPerQuantity * quantity,
                protein: snapshotProteinPerQuantity * quantity,
                carbs: snapshotCarbsPerQuantity * quantity,
                fat: snapshotFatPerQuantity * quantity
            )
        }
        if let recipe {
            let perServing = recipe.macrosPerServing
            return MacroTotals(
                calories: perServing.calories * quantity,
                protein: perServing.protein * quantity,
                carbs: perServing.carbs * quantity,
                fat: perServing.fat * quantity
            )
        }
        if let food {
            return food.macros(for: quantity, unit: servingUnit)
        }
        return .zero
    }

    /// Copies name and macros from the linked food/recipe, then unlinks it.
    func freezeFromLink() {
        guard !hasSnapshot else { return }

        let totals: MacroTotals
        let name: String
        if let recipe {
            name = recipe.name
            let perServing = recipe.macrosPerServing
            totals = MacroTotals(
                calories: perServing.calories * quantity,
                protein: perServing.protein * quantity,
                carbs: perServing.carbs * quantity,
                fat: perServing.fat * quantity
            )
        } else if let food {
            name = food.displayName
            totals = food.macros(for: quantity, unit: servingUnit)
        } else {
            return
        }

        let divisor = max(quantity, 0.01)
        snapshotName = name
        snapshotCaloriesPerQuantity = totals.calories / divisor
        snapshotProteinPerQuantity = totals.protein / divisor
        snapshotCarbsPerQuantity = totals.carbs / divisor
        snapshotFatPerQuantity = totals.fat / divisor
        food = nil
        recipe = nil
    }
}
