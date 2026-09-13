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

    var usesCustomYield: Bool = false
    var yieldIsPerServing: Bool = false
    var yieldAmount: Double = 0
    var yieldUnitRaw: String = ServingUnitType.grams.rawValue
    var yieldGramWeight: Double = 0

    var yieldUnit: ServingUnitType {
        get { ServingUnitType(rawValue: yieldUnitRaw) ?? .grams }
        set { yieldUnitRaw = newValue.rawValue }
    }

    init(name: String, servings: Double = 1) {
        self.id = UUID()
        self.name = name
        self.servings = max(servings, 0.01)
        self.createdAt = Date()
        self.ingredients = []
    }

    var totalMacros: MacroTotals {
        macrosForFullRecipe(overrides: [:])
    }

    var macrosPerServing: MacroTotals {
        macrosPerServing(overrides: [:])
    }

    /// `overrides` maps ingredient id → full-recipe amount for adjustable ingredients.
    func macrosForFullRecipe(
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)]
    ) -> MacroTotals {
        ingredients.reduce(.zero) { partial, ingredient in
            guard let food = ingredient.food else { return partial }
            if ingredient.isAdjustableAtLog,
               let override = overrides[ingredient.id] {
                return partial + food.macros(for: override.quantity, unit: override.unit)
            }
            return partial + food.macros(for: ingredient.quantity, unit: ingredient.servingUnit)
        }
    }

    func macrosPerServing(
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)]
    ) -> MacroTotals {
        let total = macrosForFullRecipe(overrides: overrides)
        let count = max(servings, 0.01)
        return MacroTotals(
            calories: total.calories / count,
            protein: total.protein / count,
            carbs: total.carbs / count,
            fat: total.fat / count
        )
    }

    var adjustableIngredients: [RecipeIngredient] {
        ingredients.filter(\.isAdjustableAtLog)
    }

    func macros(
        for quantity: Double,
        unit: ServingUnitType,
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> MacroTotals {
        if unit == .serving {
            let perServing = macrosPerServing(overrides: overrides)
            return MacroTotals(
                calories: perServing.calories * quantity,
                protein: perServing.protein * quantity,
                carbs: perServing.carbs * quantity,
                fat: perServing.fat * quantity
            )
        }
        let grams = grams(for: quantity, unit: unit, overrides: overrides)
        let batch = batchGrams(overrides: overrides)
        guard batch > 0 else { return .zero }
        let total = macrosForFullRecipe(overrides: overrides)
        let factor = grams / batch
        return MacroTotals(
            calories: total.calories * factor,
            protein: total.protein * factor,
            carbs: total.carbs * factor,
            fat: total.fat * factor
        )
    }

    func ingredientGrams(
        _ ingredient: RecipeIngredient,
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> Double {
        guard let food = ingredient.food else { return 0 }
        if ingredient.isAdjustableAtLog, let override = overrides[ingredient.id] {
            return ServingConverter.gramsAmount(quantity: override.quantity, unit: override.unit, food: food)
        }
        return ServingConverter.gramsAmount(quantity: ingredient.quantity, unit: ingredient.servingUnit, food: food)
    }

    func ingredientTotalGrams(
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> Double {
        ingredients.reduce(0) { $0 + ingredientGrams($1, overrides: overrides) }
    }

    var definedYieldGrams: Double {
        ServingConverter.resolvedGrams(
            amount: yieldAmount > 0 ? yieldAmount : nil,
            unit: yieldUnit,
            gramWeight: yieldGramWeight > 0 ? yieldGramWeight : nil
        )
    }

    var hasUsableCustomYield: Bool {
        usesCustomYield && definedYieldGrams > 0
    }

    func batchGrams(
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> Double {
        if hasUsableCustomYield {
            return yieldIsPerServing ? definedYieldGrams * max(servings, 0.01) : definedYieldGrams
        }
        return ingredientTotalGrams(overrides: overrides)
    }

    func gramsPerServing(
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> Double {
        batchGrams(overrides: overrides) / max(servings, 0.01)
    }

    var gramsPerDefinedYieldUnit: Double {
        guard definedYieldGrams > 0 else { return 0 }
        if yieldAmount > 0 { return definedYieldGrams / yieldAmount }
        switch yieldUnit {
        case .grams: return 1
        case .ounces: return ServingConverter.gramsPerOunce
        default: return 0
        }
    }

    func availableServingUnits(
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> [ServingUnitType] {
        var units: [ServingUnitType] = [.serving]
        if batchGrams(overrides: overrides) > 0 {
            units.append(contentsOf: [.grams, .ounces])
        }
        if hasUsableCustomYield, gramsPerDefinedYieldUnit > 0 {
            switch yieldUnit {
            case .teaspoon, .tablespoon, .cup:
                if !units.contains(yieldUnit) { units.append(yieldUnit) }
            default:
                break
            }
        }
        return units
    }

    func grams(
        for quantity: Double,
        unit: ServingUnitType,
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> Double {
        switch unit {
        case .grams:
            return quantity
        case .ounces:
            return quantity * ServingConverter.gramsPerOunce
        case .serving:
            return gramsPerServing(overrides: overrides) * quantity
        case .teaspoon, .tablespoon, .cup:
            return quantity * gramsPerDefinedYieldUnit
        case .small, .medium, .large:
            return 0
        }
    }

    func convertedQuantity(
        _ quantity: Double,
        from oldUnit: ServingUnitType,
        to newUnit: ServingUnitType,
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> Double {
        let grams = grams(for: quantity, unit: oldUnit, overrides: overrides)
        let converted: Double
        switch newUnit {
        case .grams:
            converted = max(grams, 1)
        case .ounces:
            converted = max(grams / ServingConverter.gramsPerOunce, 0.01)
        case .serving:
            let perServing = gramsPerServing(overrides: overrides)
            converted = perServing > 0 ? max(grams / perServing, 0.01) : 1
        case .teaspoon, .tablespoon, .cup:
            let perUnit = gramsPerDefinedYieldUnit
            converted = perUnit > 0 ? max(grams / perUnit, 0.01) : 1
        case .small, .medium, .large:
            converted = 1
        }
        let range = ServingConverter.quantityRange(for: newUnit)
        return min(max(converted, range.lowerBound), range.upperBound)
    }

    func unitLabel(
        for unit: ServingUnitType,
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) -> String {
        switch unit {
        case .grams:
            return "grams"
        case .ounces:
            return "ounces"
        case .serving:
            let grams = gramsPerServing(overrides: overrides)
            if grams > 0 {
                return "serving (\(Int(grams.rounded()))g)"
            }
            return "serving"
        case .teaspoon:
            let grams = gramsPerDefinedYieldUnit
            return grams > 0 ? "tsp (\(Int(grams.rounded()))g)" : "tsp"
        case .tablespoon:
            let grams = gramsPerDefinedYieldUnit
            return grams > 0 ? "tbsp (\(Int(grams.rounded()))g)" : "tbsp"
        case .cup:
            let grams = gramsPerDefinedYieldUnit
            return grams > 0 ? "cup (\(Int(grams.rounded()))g)" : "cup"
        case .small, .medium, .large:
            return unit.displayName
        }
    }

    func copyYield(from source: Recipe) {
        usesCustomYield = source.usesCustomYield
        yieldIsPerServing = source.yieldIsPerServing
        yieldAmount = source.yieldAmount
        yieldUnitRaw = source.yieldUnitRaw
        yieldGramWeight = source.yieldGramWeight
    }
}

@Model
final class RecipeIngredient {
    var id: UUID
    var quantity: Double
    var servingUnitRaw: String
    var food: Food?
    var recipe: Recipe?
    /// When true, log-time UI can override this ingredient’s full-recipe amount.
    var isAdjustableAtLog: Bool = false

    var servingUnit: ServingUnitType {
        get { ServingUnitType(rawValue: servingUnitRaw) ?? .grams }
        set { servingUnitRaw = newValue.rawValue }
    }

    init(
        food: Food,
        quantity: Double,
        servingUnit: ServingUnitType = .grams,
        isAdjustableAtLog: Bool = false
    ) {
        self.id = UUID()
        self.food = food
        self.quantity = quantity
        self.servingUnitRaw = servingUnit.rawValue
        self.isAdjustableAtLog = isAdjustableAtLog
    }
}

extension RecipeIngredient: Identifiable {}
