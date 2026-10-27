import Foundation
import SwiftData

struct FoodShareDocument: Codable {
    var version: Int
    var food: SharedCustomFood?
    var recipe: SharedRecipe?
}

struct SharedCustomFood: Codable, Identifiable {
    var key: String
    var name: String
    var brand: String?
    var barcode: String?
    var isAlcohol: Bool
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

    var id: String { key }

    var displayName: String {
        if let brand, !brand.isEmpty {
            return "\(name) (\(brand))"
        }
        return name
    }
}

struct SharedCatalogFood: Codable {
    var source: String
    var externalId: String?
    var barcode: String?
    var name: String
    var brand: String?

    var displayName: String {
        if let brand, !brand.isEmpty {
            return "\(name) (\(brand))"
        }
        return name
    }
}

struct SharedIngredient: Codable {
    var quantity: Double
    var unit: String
    var isAdjustable: Bool
    var customFoodKey: String?
    var catalog: SharedCatalogFood?
}

struct SharedRecipe: Codable {
    var name: String
    var servings: Double
    var usesCustomYield: Bool
    var yieldIsPerServing: Bool
    var yieldAmount: Double
    var yieldUnit: String
    var yieldGramWeight: Double
    var ingredients: [SharedIngredient]
    var customFoods: [SharedCustomFood]
}

enum FoodShareError: LocalizedError {
    case unreadable
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "This file isn’t a belessfat food or recipe."
        case .unsupportedVersion:
            return "This share was made by a newer version of belessfat."
        }
    }
}

@MainActor
enum FoodShareService {
    static let fileExtension = "belessfat"
    private static let version = 1

    static func document(for food: Food) -> FoodShareDocument {
        FoodShareDocument(version: version, food: sharedCustomFood(from: food, key: food.id.uuidString), recipe: nil)
    }

    static func document(for recipe: Recipe) -> FoodShareDocument {
        var foods: [SharedCustomFood] = []
        var keys: [UUID: String] = [:]
        var ingredients: [SharedIngredient] = []

        for ingredient in recipe.ingredients {
            guard let food = ingredient.food else { continue }
            let sharedIngredient: SharedIngredient
            if let catalog = catalogReference(for: food) {
                sharedIngredient = SharedIngredient(
                    quantity: ingredient.quantity,
                    unit: ingredient.servingUnitRaw,
                    isAdjustable: ingredient.isAdjustableAtLog,
                    customFoodKey: nil,
                    catalog: catalog
                )
            } else {
                let key: String
                if let existing = keys[food.id] {
                    key = existing
                } else {
                    key = food.id.uuidString
                    keys[food.id] = key
                    foods.append(sharedCustomFood(from: food, key: key))
                }
                sharedIngredient = SharedIngredient(
                    quantity: ingredient.quantity,
                    unit: ingredient.servingUnitRaw,
                    isAdjustable: ingredient.isAdjustableAtLog,
                    customFoodKey: key,
                    catalog: nil
                )
            }
            ingredients.append(sharedIngredient)
        }

        let shared = SharedRecipe(
            name: recipe.name,
            servings: recipe.servings,
            usesCustomYield: recipe.usesCustomYield,
            yieldIsPerServing: recipe.yieldIsPerServing,
            yieldAmount: recipe.yieldAmount,
            yieldUnit: recipe.yieldUnitRaw,
            yieldGramWeight: recipe.yieldGramWeight,
            ingredients: ingredients,
            customFoods: foods
        )
        return FoodShareDocument(version: version, food: nil, recipe: shared)
    }

    static let typeIdentifier = "com.belessfat.foodshare"
    private static let fileHeader = Data("belessfat-share-v1\n".utf8)

    static func fileData(for document: FoodShareDocument) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(document) else { return nil }
        var data = fileHeader
        data.append(json)
        return data
    }

    static func fileURL(for document: FoodShareDocument, suggestedName: String) -> URL? {
        guard let data = fileData(for: document) else { return nil }
        let url = temporaryURL(suggestedName: suggestedName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func filename(for suggestedName: String) -> String {
        temporaryURL(suggestedName: suggestedName).lastPathComponent
    }

    static func decode(_ data: Data) throws -> FoodShareDocument {
        let json = data.starts(with: fileHeader) ? data.dropFirst(fileHeader.count) : data
        let document: FoodShareDocument
        do {
            document = try JSONDecoder().decode(FoodShareDocument.self, from: json)
        } catch {
            throw FoodShareError.unreadable
        }
        guard document.version == version else { throw FoodShareError.unsupportedVersion }
        guard document.food != nil || document.recipe != nil else { throw FoodShareError.unreadable }
        return document
    }

    static func read(url: URL) throws -> FoodShareDocument {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        do {
            return try decode(data)
        } catch let error as FoodShareError {
            throw error
        } catch {
            throw FoodShareError.unreadable
        }
    }

    /// Uses a food already on the device when it matches. Otherwise fetches the database record without saving it.
    static func resolveCatalog(_ catalog: SharedCatalogFood, context: ModelContext) async -> Food? {
        if let local = localCatalogFood(catalog, context: context) {
            return local
        }
        if catalog.source == FoodSource.usda.rawValue {
            if let externalId = catalog.externalId,
               let fdcId = Int(externalId),
               let food = try? await USDAClient.fetchFood(fdcId: fdcId) {
                return food
            }
            if let barcode = catalog.barcode,
               let food = try? await USDAClient.searchByBarcode(barcode) {
                return food
            }
        }
        if catalog.source == FoodSource.off.rawValue,
           let code = catalog.barcode ?? catalog.externalId,
           let food = try? await OpenFoodFactsClient.lookupBarcode(code) {
            return food
        }
        return nil
    }

    static func importDocument(
        _ document: FoodShareDocument,
        catalogFoods: [Int: Food],
        context: ModelContext
    ) {
        if let food = document.food {
            _ = insertCustomFood(food, context: context)
            try? context.save()
            return
        }
        guard let shared = document.recipe else { return }

        var foodsByKey: [String: Food] = [:]
        for item in shared.customFoods {
            foodsByKey[item.key] = insertCustomFood(item, context: context)
        }

        let recipe = Recipe(name: shared.name, servings: shared.servings)
        recipe.usesCustomYield = shared.usesCustomYield
        recipe.yieldIsPerServing = shared.yieldIsPerServing
        recipe.yieldAmount = shared.yieldAmount
        recipe.yieldUnitRaw = shared.yieldUnit
        recipe.yieldGramWeight = shared.yieldGramWeight
        context.insert(recipe)

        for (index, ingredient) in shared.ingredients.enumerated() {
            let food: Food?
            if let key = ingredient.customFoodKey {
                food = foodsByKey[key]
            } else if ingredient.catalog != nil, let resolved = catalogFoods[index] {
                food = FoodService.cacheFood(resolved, context: context)
            } else {
                food = nil
            }
            guard let food else { continue }
            let item = RecipeIngredient(
                food: food,
                quantity: ingredient.quantity,
                servingUnit: ServingUnitType(rawValue: ingredient.unit) ?? .grams,
                isAdjustableAtLog: ingredient.isAdjustable
            )
            item.recipe = recipe
            recipe.ingredients.append(item)
            context.insert(item)
        }
        try? context.save()
    }

    private static func catalogReference(for food: Food) -> SharedCatalogFood? {
        guard food.source == .usda || food.source == .off else { return nil }
        let externalId = food.externalId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let barcode = food.barcode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExternalId = externalId?.isEmpty == false
        let hasBarcode = barcode?.isEmpty == false
        guard hasExternalId || hasBarcode else { return nil }
        return SharedCatalogFood(
            source: food.sourceRaw,
            externalId: hasExternalId ? externalId : nil,
            barcode: hasBarcode ? barcode : nil,
            name: food.name,
            brand: food.brand
        )
    }

    private static func sharedCustomFood(from food: Food, key: String) -> SharedCustomFood {
        SharedCustomFood(
            key: key,
            name: food.name,
            brand: food.brand,
            barcode: food.barcode,
            isAlcohol: food.isAlcohol,
            caloriesPer100g: food.caloriesPer100g,
            proteinPer100g: food.proteinPer100g,
            carbsPer100g: food.carbsPer100g,
            fatPer100g: food.fatPer100g,
            servingSizeGrams: food.servingSizeGrams,
            servingDescription: food.servingDescription,
            caloriesPerServing: food.caloriesPerServing,
            proteinPerServing: food.proteinPerServing,
            carbsPerServing: food.carbsPerServing,
            fatPerServing: food.fatPerServing,
            smallServingGrams: food.smallServingGrams,
            mediumServingGrams: food.mediumServingGrams,
            largeServingGrams: food.largeServingGrams,
            teaspoonGrams: food.teaspoonGrams,
            tablespoonGrams: food.tablespoonGrams,
            cupGrams: food.cupGrams
        )
    }

    private static func insertCustomFood(_ shared: SharedCustomFood, context: ModelContext) -> Food {
        let food = Food(
            name: shared.name,
            brand: shared.brand,
            source: .custom,
            barcode: shared.barcode.map { USDAClient.normalizeBarcode($0) },
            caloriesPer100g: shared.caloriesPer100g,
            proteinPer100g: shared.proteinPer100g,
            carbsPer100g: shared.carbsPer100g,
            fatPer100g: shared.fatPer100g,
            servingSizeGrams: shared.servingSizeGrams,
            servingDescription: shared.servingDescription,
            caloriesPerServing: shared.caloriesPerServing,
            proteinPerServing: shared.proteinPerServing,
            carbsPerServing: shared.carbsPerServing,
            fatPerServing: shared.fatPerServing,
            smallServingGrams: shared.smallServingGrams,
            mediumServingGrams: shared.mediumServingGrams,
            largeServingGrams: shared.largeServingGrams,
            teaspoonGrams: shared.teaspoonGrams,
            tablespoonGrams: shared.tablespoonGrams,
            cupGrams: shared.cupGrams,
            isAlcohol: shared.isAlcohol
        )
        context.insert(food)
        return food
    }

    private static func localCatalogFood(_ catalog: SharedCatalogFood, context: ModelContext) -> Food? {
        if let externalId = catalog.externalId, !externalId.isEmpty {
            let source = catalog.source
            var descriptor = FetchDescriptor<Food>(
                predicate: #Predicate { item in
                    item.externalId == externalId && item.sourceRaw == source
                }
            )
            descriptor.fetchLimit = 1
            if let match = (try? context.fetch(descriptor))?.first {
                return match
            }
        }
        if let barcode = catalog.barcode, !barcode.isEmpty {
            let normalized = USDAClient.normalizeBarcode(barcode)
            let source = catalog.source
            let foods = (try? context.fetch(FetchDescriptor<Food>())) ?? []
            return foods.first { food in
                guard food.sourceRaw == source, let existing = food.barcode else { return false }
                return USDAClient.normalizeBarcode(existing) == normalized
            }
        }
        return nil
    }

    private static func temporaryURL(suggestedName: String) -> URL {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = suggestedName
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Share" : String(cleaned.prefix(80))
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(base)
            .appendingPathExtension(fileExtension)
    }
}

@MainActor
final class ShareImportRouter: ObservableObject {
    static let shared = ShareImportRouter()

    @Published var pending: FoodShareDocument?
    @Published var unreadableMessage: String?

    private var openPath: String?

    func accept(_ capture: FoodShareCapture) {
        if openPath == capture.path, pending != nil { return }
        do {
            pending = try FoodShareService.decode(capture.data)
            openPath = capture.path
            unreadableMessage = nil
        } catch {
            openPath = capture.path
            pending = nil
            unreadableMessage = error.localizedDescription
        }
    }
}

struct FoodShareCapture: Equatable {
    var path: String
    var data: Data
}

enum FoodShareOpener {
    /// Copies the file immediately. Messages only keeps the URL valid until this returns.
    static func capture(_ url: URL) -> FoodShareCapture? {
        guard url.isFileURL else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return FoodShareCapture(path: url.path, data: data)
    }
}
