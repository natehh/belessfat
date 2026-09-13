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
    /// Full-recipe amounts for adjustable ingredients, JSON-encoded.
    var recipeIngredientOverridesJSON: String?

    var hasSnapshot: Bool { snapshotName != nil }
    var isOrphanedSnapshot: Bool { hasSnapshot && food == nil && recipe == nil }

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
            return recipe.macros(for: quantity, unit: servingUnit, overrides: recipeOverrideMap)
        }
        if let food {
            return food.macros(for: quantity, unit: servingUnit)
        }
        return .zero
    }

    /// Copies name and macros from the linked food/recipe (if not already snapshotted), then unlinks it.
    func freezeFromLink() {
        if !hasSnapshot {
            let totals: MacroTotals
            let name: String
            if let recipe {
                name = recipe.name
                totals = recipe.macros(for: quantity, unit: servingUnit, overrides: recipeOverrideMap)
            } else if let food {
                name = food.displayName
                totals = food.macros(for: quantity, unit: servingUnit)
            } else {
                food = nil
                recipe = nil
                return
            }

            let divisor = max(quantity, 0.01)
            snapshotName = name
            snapshotCaloriesPerQuantity = totals.calories / divisor
            snapshotProteinPerQuantity = totals.protein / divisor
            snapshotCarbsPerQuantity = totals.carbs / divisor
            snapshotFatPerQuantity = totals.fat / divisor
        }
        food = nil
        recipe = nil
    }

    /// Freeze macros per logged quantity unit (keeps recipe link for display until unlinked).
    func applyRecipeSnapshot(name: String, macrosPerQuantity: MacroTotals) {
        snapshotName = name
        snapshotCaloriesPerQuantity = macrosPerQuantity.calories
        snapshotProteinPerQuantity = macrosPerQuantity.protein
        snapshotCarbsPerQuantity = macrosPerQuantity.carbs
        snapshotFatPerQuantity = macrosPerQuantity.fat
    }

    func clearRecipeSnapshot() {
        snapshotName = nil
        snapshotCaloriesPerQuantity = 0
        snapshotProteinPerQuantity = 0
        snapshotCarbsPerQuantity = 0
        snapshotFatPerQuantity = 0
    }

    var recipeOverrideMap: [UUID: (quantity: Double, unit: ServingUnitType)] {
        get {
            guard let data = recipeIngredientOverridesJSON?.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([StoredRecipeIngredientOverride].self, from: data)
            else { return [:] }
            return Dictionary(uniqueKeysWithValues: decoded.map { item in
                (
                    item.id,
                    (
                        item.quantity,
                        ServingUnitType(rawValue: item.unit) ?? .grams
                    )
                )
            })
        }
        set {
            let items = newValue.map { id, value in
                StoredRecipeIngredientOverride(id: id, quantity: value.quantity, unit: value.unit.rawValue)
            }
            if items.isEmpty {
                recipeIngredientOverridesJSON = nil
            } else if let data = try? JSONEncoder().encode(items),
                      let json = String(data: data, encoding: .utf8) {
                recipeIngredientOverridesJSON = json
            }
        }
    }
}

private struct StoredRecipeIngredientOverride: Codable {
    var id: UUID
    var quantity: Double
    var unit: String
}
