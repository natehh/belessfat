import Foundation
import SwiftData

@MainActor
enum FoodService {
    struct CustomServingDefinition {
        var amount: Double?
        var unit: ServingUnitType
        var gramWeight: Double?
        var description: String?

        var resolvedGramWeight: Double {
            if let gramWeight, gramWeight > 0 { return gramWeight }
            guard let amount, amount > 0 else { return 0 }
            switch unit {
            case .grams: return amount
            case .ounces: return amount * ServingConverter.gramsPerOunce
            case .teaspoon, .tablespoon, .cup, .serving, .small, .medium, .large:
                return 0
            }
        }

        var resolvedDescription: String? {
            let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
            guard let amount, amount > 0, ServingUnitType.customFoodServingUnits.contains(unit) else { return nil }
            let formatted = amount.formatted(.number.precision(.fractionLength(0...2)))
            switch unit {
            case .grams: return "\(formatted)g"
            case .ounces: return "\(formatted) oz"
            default: return "\(formatted) \(unit.displayName)"
            }
        }
    }

    static func applyServingDefinition(_ definition: CustomServingDefinition, to food: Food) {
        food.teaspoonGrams = nil
        food.tablespoonGrams = nil
        food.cupGrams = nil
        food.servingDescription = definition.resolvedDescription

        let grams = definition.resolvedGramWeight
        food.servingSizeGrams = grams

        if let amount = definition.amount, amount > 0, grams > 0 {
            let perUnit = grams / amount
            switch definition.unit {
            case .teaspoon: food.teaspoonGrams = perUnit
            case .tablespoon: food.tablespoonGrams = perUnit
            case .cup: food.cupGrams = perUnit
            default: break
            }
        }
    }

    static func servingDefinition(from food: Food) -> CustomServingDefinition {
        if let cup = food.cupGrams, food.servingSizeGrams > 0 {
            let amount = food.servingSizeGrams / cup
            return CustomServingDefinition(
                amount: amount,
                unit: .cup,
                gramWeight: food.servingSizeGrams,
                description: food.servingDescription
            )
        }
        if let tbsp = food.tablespoonGrams, food.servingSizeGrams > 0 {
            let amount = food.servingSizeGrams / tbsp
            return CustomServingDefinition(
                amount: amount,
                unit: .tablespoon,
                gramWeight: food.servingSizeGrams,
                description: food.servingDescription
            )
        }
        if let tsp = food.teaspoonGrams, food.servingSizeGrams > 0 {
            let amount = food.servingSizeGrams / tsp
            return CustomServingDefinition(
                amount: amount,
                unit: .teaspoon,
                gramWeight: food.servingSizeGrams,
                description: food.servingDescription
            )
        }
        if food.servingSizeGrams > 0 {
            return CustomServingDefinition(
                amount: food.servingSizeGrams,
                unit: .grams,
                gramWeight: food.servingSizeGrams,
                description: food.servingDescription
            )
        }
        return CustomServingDefinition(
            amount: nil,
            unit: .grams,
            gramWeight: nil,
            description: food.servingDescription
        )
    }

    static func localFood(byBarcode barcode: String, context: ModelContext) -> Food? {
        let normalized = USDAClient.normalizeBarcode(barcode)
        let descriptor = FetchDescriptor<Food>()
        let foods = (try? context.fetch(descriptor)) ?? []
        return foods.first { food in
            guard let bc = food.barcode else { return false }
            return USDAClient.normalizeBarcode(bc) == normalized
        }
    }

    static func cacheFood(_ food: Food, context: ModelContext) -> Food {
        if let externalId = food.externalId {
            let lookupExternalId = externalId
            let lookupSource = food.sourceRaw
            var descriptor = FetchDescriptor<Food>(
                predicate: #Predicate { item in
                    item.externalId == lookupExternalId && item.sourceRaw == lookupSource
                }
            )
            descriptor.fetchLimit = 1
            if let match = (try? context.fetch(descriptor))?.first {
                syncNutrition(from: food, to: match)
                try? context.save()
                return match
            }
        }
        if let barcode = food.barcode, let existing = localFood(byBarcode: barcode, context: context) {
            syncNutrition(from: food, to: existing)
            try? context.save()
            return existing
        }
        context.insert(food)
        try? context.save()
        return food
    }

    private static func syncNutrition(from source: Food, to target: Food) {
        if source.caloriesPer100g > 0 || source.proteinPer100g > 0 || source.carbsPer100g > 0 || source.fatPer100g > 0 {
            target.caloriesPer100g = source.caloriesPer100g
            target.proteinPer100g = source.proteinPer100g
            target.carbsPer100g = source.carbsPer100g
            target.fatPer100g = source.fatPer100g
            target.caloriesPerServing = source.caloriesPerServing
            target.proteinPerServing = source.proteinPerServing
            target.carbsPerServing = source.carbsPerServing
            target.fatPerServing = source.fatPerServing
        }
        target.servingSizeGrams = source.servingSizeGrams
        target.servingDescription = source.servingDescription
        target.teaspoonGrams = source.teaspoonGrams
        target.tablespoonGrams = source.tablespoonGrams
        target.cupGrams = source.cupGrams
        target.smallServingGrams = source.smallServingGrams
        target.mediumServingGrams = source.mediumServingGrams
        target.largeServingGrams = source.largeServingGrams
    }

    static func prepareForLogging(_ food: Food, context: ModelContext) async -> Food {
        if USDAClient.needsPortionEnrichment(food),
           let fdcIdString = food.externalId,
           let fdcId = Int(fdcIdString),
           let enriched = try? await USDAClient.fetchFood(fdcId: fdcId) {
            return cacheFood(enriched, context: context)
        }
        return food.source == .custom ? food : cacheFood(food, context: context)
    }

    static func lookupBarcode(_ barcode: String, context: ModelContext) async throws -> Food? {
        if let local = localFood(byBarcode: barcode, context: context) {
            return local
        }
        if let off = try await OpenFoodFactsClient.lookupBarcode(barcode) {
            return cacheFood(off, context: context)
        }
        if let usda = try await USDAClient.searchByBarcode(barcode) {
            return cacheFood(usda, context: context)
        }
        return nil
    }

    static func search(query: String, context: ModelContext) async throws -> [Food] {
        let remote = try await searchRemote(query: query)
        let matchingCustom = searchCustomFoods(query: query, context: context)
        return mergeFoodResults(remote: remote, custom: matchingCustom)
    }

    static func searchRemote(query: String) async throws -> [Food] {
        async let usdaResults = USDAClient.search(query: query)
        async let offResults = OpenFoodFactsClient.search(query: query)
        let usda = (try? await usdaResults) ?? []
        let off = (try? await offResults) ?? []

        var seen = Set<String>()
        var merged: [Food] = []
        for food in usda + off {
            let key = foodDedupKey(food)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(food)
        }
        return merged
    }

    static func allCustomFoods(context: ModelContext) -> [Food] {
        let descriptor = FetchDescriptor<Food>(sortBy: [SortDescriptor(\.name)])
        let foods = (try? context.fetch(descriptor)) ?? []
        return foods.filter { $0.source == .custom }
    }

    static func searchCustomFoods(query: String, context: ModelContext) -> [Food] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let foods = allCustomFoods(context: context)
        guard !trimmed.isEmpty else { return foods }
        return foods.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.brand?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    static func searchRecipes(query: String, context: ModelContext) -> [Recipe] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipes = allRecipes(context: context)
        guard !trimmed.isEmpty else { return recipes }
        return recipes.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private static func foodDedupKey(_ food: Food) -> String {
        "\(food.name.lowercased())|\(food.brand?.lowercased() ?? "")"
    }

    private static func mergeFoodResults(remote: [Food], custom: [Food]) -> [Food] {
        var seen = Set<String>()
        var merged: [Food] = []
        for food in custom + remote {
            let key = foodDedupKey(food)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(food)
        }
        return merged
    }

    static func mergeFoodResultsForDisplay(remote: [Food], custom: [Food]) -> [Food] {
        var seen = Set<String>()
        var merged: [Food] = []
        for food in custom + remote {
            let key = "\(food.name.lowercased())|\(food.brand?.lowercased() ?? "")|\(food.sourceRaw)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(food)
        }
        return merged
    }

    static func updateCustomFood(
        _ food: Food,
        name: String,
        brand: String?,
        barcode: String?,
        serving: CustomServingDefinition,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        isAlcohol: Bool,
        context: ModelContext
    ) -> Food {
        applyServingDefinition(serving, to: food)
        let servingSizeGrams = food.servingSizeGrams
        let per100gFactor = servingSizeGrams > 0 ? 100.0 / servingSizeGrams : 1
        food.name = name
        food.brand = brand
        food.barcode = barcode.map { USDAClient.normalizeBarcode($0) }
        food.caloriesPer100g = calories * per100gFactor
        food.proteinPer100g = protein * per100gFactor
        food.carbsPer100g = carbs * per100gFactor
        food.fatPer100g = fat * per100gFactor
        food.caloriesPerServing = calories
        food.proteinPerServing = protein
        food.carbsPerServing = carbs
        food.fatPerServing = fat
        food.isAlcohol = isAlcohol
        try? context.save()
        return food
    }

    static func saveCustomFood(
        name: String,
        brand: String?,
        barcode: String?,
        serving: CustomServingDefinition,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        isAlcohol: Bool,
        context: ModelContext
    ) -> Food {
        let servingSizeGrams = serving.resolvedGramWeight
        let per100gFactor = servingSizeGrams > 0 ? 100.0 / servingSizeGrams : 1
        let food = Food(
            name: name,
            brand: brand,
            source: .custom,
            barcode: barcode.map { USDAClient.normalizeBarcode($0) },
            caloriesPer100g: calories * per100gFactor,
            proteinPer100g: protein * per100gFactor,
            carbsPer100g: carbs * per100gFactor,
            fatPer100g: fat * per100gFactor,
            servingSizeGrams: 0,
            servingDescription: serving.resolvedDescription,
            caloriesPerServing: calories,
            proteinPerServing: protein,
            carbsPerServing: carbs,
            fatPerServing: fat,
            isAlcohol: isAlcohol
        )
        applyServingDefinition(serving, to: food)
        return cacheFood(food, context: context)
    }

    static func allRecipes(context: ModelContext) -> [Recipe] {
        let descriptor = FetchDescriptor<Recipe>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func allTemplates(context: ModelContext) -> [MealTemplate] {
        let descriptor = FetchDescriptor<MealTemplate>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func allFavorites(context: ModelContext) -> [FavoriteMeal] {
        let descriptor = FetchDescriptor<FavoriteMeal>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func duplicateRecipe(_ source: Recipe, newName: String, context: ModelContext) -> Recipe {
        let copy = Recipe(name: newName, servings: source.servings)
        copy.copyYield(from: source)
        context.insert(copy)
        for ingredient in source.ingredients {
            guard let food = ingredient.food else { continue }
            let item = RecipeIngredient(
                food: food,
                quantity: ingredient.quantity,
                servingUnit: ingredient.servingUnit,
                isAdjustableAtLog: ingredient.isAdjustableAtLog
            )
            item.recipe = copy
            copy.ingredients.append(item)
            context.insert(item)
        }
        try? context.save()
        return copy
    }

    static func createRecipeFromMeal(
        entries: [LogEntry],
        meal: MealCategory,
        date: Date,
        context: ModelContext
    ) -> Recipe {
        let dateLabel = date.formatted(date: .abbreviated, time: .omitted)
        let recipe = Recipe(name: "\(meal.displayName) — \(dateLabel)", servings: 1)
        context.insert(recipe)
        for entry in entries {
            for (food, quantity, unit) in ingredientLines(from: entry, context: context) {
                let item = RecipeIngredient(food: food, quantity: quantity, servingUnit: unit)
                item.recipe = recipe
                recipe.ingredients.append(item)
                context.insert(item)
            }
        }
        try? context.save()
        return recipe
    }

    private static func ingredientLines(
        from entry: LogEntry,
        context: ModelContext
    ) -> [(Food, Double, ServingUnitType)] {
        if let food = entry.food {
            return [(food, entry.quantity, entry.servingUnit)]
        }
        if let recipe = entry.recipe {
            let overrides = entry.recipeOverrideMap
            let fraction: Double
            if entry.servingUnit == .serving {
                fraction = entry.quantity / max(recipe.servings, 0.01)
            } else {
                let loggedGrams = recipe.grams(for: entry.quantity, unit: entry.servingUnit, overrides: overrides)
                let batch = recipe.batchGrams(overrides: overrides)
                fraction = batch > 0 ? loggedGrams / batch : 0
            }
            return recipe.ingredients.compactMap { ingredient in
                guard let food = ingredient.food else { return nil }
                if let override = overrides[ingredient.id] {
                    return (food, override.quantity * fraction, override.unit)
                }
                return (food, ingredient.quantity * fraction, ingredient.servingUnit)
            }
        }
        if let food = foodFromSnapshotEntry(entry, context: context) {
            return [(food, entry.quantity, entry.servingUnit)]
        }
        return []
    }

    private static func foodFromSnapshotEntry(_ entry: LogEntry, context: ModelContext) -> Food? {
        guard entry.hasSnapshot, let name = entry.snapshotName else { return nil }
        return saveCustomFood(
            name: name,
            brand: nil,
            barcode: nil,
            serving: CustomServingDefinition(
                amount: 1,
                unit: entry.servingUnit,
                gramWeight: entry.servingUnit == .grams ? max(entry.quantity, 1) : nil,
                description: nil
            ),
            calories: entry.snapshotCaloriesPerQuantity,
            protein: entry.snapshotProteinPerQuantity,
            carbs: entry.snapshotCarbsPerQuantity,
            fat: entry.snapshotFatPerQuantity,
            isAlcohol: false,
            context: context
        )
    }

    static func deleteRecipe(_ recipe: Recipe, context: ModelContext) {
        let recipeId = recipe.id
        let entries = (try? context.fetch(FetchDescriptor<LogEntry>())) ?? []
        for entry in entries where entry.recipe?.id == recipeId {
            entry.freezeFromLink()
        }
        for template in (try? context.fetch(FetchDescriptor<MealTemplate>())) ?? [] {
            for item in template.items where item.recipe?.id == recipeId {
                context.delete(item)
            }
        }
        for favorite in (try? context.fetch(FetchDescriptor<FavoriteMeal>())) ?? [] {
            for item in favorite.items where item.recipe?.id == recipeId {
                context.delete(item)
            }
        }
        context.delete(recipe)
        try? context.save()
    }

    static func deleteCustomFood(_ food: Food, context: ModelContext) {
        guard food.source == .custom else { return }
        let foodId = food.id
        let entries = (try? context.fetch(FetchDescriptor<LogEntry>())) ?? []
        for entry in entries where entry.food?.id == foodId {
            entry.freezeFromLink()
        }
        for recipe in (try? context.fetch(FetchDescriptor<Recipe>())) ?? [] {
            for ingredient in recipe.ingredients where ingredient.food?.id == foodId {
                context.delete(ingredient)
            }
        }
        for template in (try? context.fetch(FetchDescriptor<MealTemplate>())) ?? [] {
            for item in template.items where item.food?.id == foodId {
                context.delete(item)
            }
        }
        for favorite in (try? context.fetch(FetchDescriptor<FavoriteMeal>())) ?? [] {
            for item in favorite.items where item.food?.id == foodId {
                context.delete(item)
            }
        }
        context.delete(food)
        try? context.save()
    }
}
