import Foundation
import SwiftData

@Model
final class Recipe {
    var id: UUID
    var name: String
    var servings: Double
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \RecipeIngredient.recipe)
    var ingredients: [RecipeIngredient]

    init(name: String, servings: Double = 1) {
        self.id = UUID()
        self.name = name
        self.servings = max(servings, 0.01)
        self.createdAt = Date()
        self.ingredients = []
    }

    var totalMacros: MacroTotals {
        ingredients.reduce(.zero) { partial, ingredient in
            guard let food = ingredient.food else { return partial }
            return partial + food.macros(for: ingredient.quantity, unit: ingredient.servingUnit)
        }
    }

    var macrosPerServing: MacroTotals {
        let total = totalMacros
        let count = max(servings, 0.01)
        return MacroTotals(
            calories: total.calories / count,
            protein: total.protein / count,
            carbs: total.carbs / count,
            fat: total.fat / count
        )
    }
}

@Model
final class RecipeIngredient {
    var id: UUID
    var quantity: Double
    var servingUnitRaw: String
    var food: Food?
    var recipe: Recipe?

    var servingUnit: ServingUnitType {
        get { ServingUnitType(rawValue: servingUnitRaw) ?? .grams }
        set { servingUnitRaw = newValue.rawValue }
    }

    init(food: Food, quantity: Double, servingUnit: ServingUnitType = .grams) {
        self.id = UUID()
        self.food = food
        self.quantity = quantity
        self.servingUnitRaw = servingUnit.rawValue
    }
}

extension RecipeIngredient: Identifiable {}
