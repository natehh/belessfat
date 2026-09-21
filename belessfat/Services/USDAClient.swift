import Foundation

enum USDAClient {
    struct SearchResponse: Decodable {
        let foods: [USDAFood]?
        let totalHits: Int?
    }

    struct USDAFood: Decodable {
        let fdcId: Int
        let description: String
        let brandOwner: String?
        let brandName: String?
        let gtinUpc: String?
        let servingSize: Double?
        let servingSizeUnit: String?
        let householdServingFullText: String?
        let foodNutrients: [FoodNutrient]?
        let dataType: String?
        let foodPortions: [FoodPortion]?
    }

    struct FoodPortion: Decodable {
        let amount: Double?
        let gramWeight: Double?
        let portionDescription: String?
        let measureUnit: MeasureUnit?
    }

    struct MeasureUnit: Decodable {
        let name: String?
        let abbreviation: String?
    }

    struct FoodNutrient: Decodable {
        let nutrientName: String?
        let nutrientNumber: String?
        let value: Double?
        let unitName: String?
        let amount: Double?
        let nutrient: NutrientRef?

        struct NutrientRef: Decodable {
            let name: String?
            let number: String?
            let unitName: String?
        }

        var resolvedName: String? { nutrient?.name ?? nutrientName }
        var resolvedNumber: String? { nutrient?.number ?? nutrientNumber }
        var resolvedValue: Double? { amount ?? value }
        var resolvedUnit: String? { nutrient?.unitName ?? unitName }
    }

    enum ClientError: LocalizedError {
        case invalidURL
        case networkError(Error)
        case decodingError
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid USDA API URL."
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .decodingError: return "Failed to decode USDA response."
            case .apiError(let msg): return msg
            }
        }
    }

    static func search(query: String, dataTypes: [String] = ["Foundation", "SR Legacy", "Branded"]) async throws -> [Food] {
        guard var components = URLComponents(string: "\(AppConfig.usdaBaseURL)/foods/search") else {
            throw ClientError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: AppConfig.usdaAPIKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "pageSize", value: "25")
        ]
        for type in dataTypes {
            components.queryItems?.append(URLQueryItem(name: "dataType", value: type))
        }
        guard let url = components.url else { throw ClientError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.apiError("USDA API returned status \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (decoded.foods ?? []).compactMap { mapFood($0) }
    }

    static func fetchFood(fdcId: Int) async throws -> Food? {
        guard let url = URL(string: "\(AppConfig.usdaBaseURL)/food/\(fdcId)?api_key=\(AppConfig.usdaAPIKey)") else {
            throw ClientError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.apiError("USDA API returned status \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(USDAFood.self, from: data)
        return mapFood(decoded)
    }

    static func needsPortionEnrichment(_ food: Food) -> Bool {
        guard food.source == .usda, food.externalId != nil else { return false }
        if food.tablespoonGrams != nil || food.teaspoonGrams != nil || food.cupGrams != nil {
            return false
        }
        if let description = food.servingDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return false
        }
        return food.servingSizeGrams == 100
    }

    static func searchByBarcode(_ barcode: String) async throws -> Food? {
        let normalized = normalizeBarcode(barcode)
        let results = try await search(query: normalized, dataTypes: ["Branded"])
        if let match = results.first(where: { normalizeBarcode($0.barcode ?? "") == normalized }) {
            return match
        }
        return results.first
    }

    static func mapFood(_ usda: USDAFood) -> Food? {
        let nutrients = usda.foodNutrients ?? []

        struct NutrientReading {
            let value: Double
            let unit: String?
        }

        func nutrient(numbers: [String], names: [String] = []) -> NutrientReading {
            for n in nutrients {
                if let num = n.resolvedNumber, numbers.contains(num) {
                    return NutrientReading(value: n.resolvedValue ?? 0, unit: n.resolvedUnit)
                }
            }
            for n in nutrients {
                if let name = n.resolvedName, names.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                    return NutrientReading(value: n.resolvedValue ?? 0, unit: n.resolvedUnit)
                }
            }
            return NutrientReading(value: 0, unit: nil)
        }

        let energyKcal = nutrient(numbers: ["208"])
        let atwaterKcal = nutrient(numbers: ["957"])
        let energy: NutrientReading
        if energyKcal.value > 0 {
            energy = energyKcal
        } else if atwaterKcal.value > 0 {
            energy = atwaterKcal
        } else {
            energy = nutrient(numbers: ["268"], names: ["Energy"])
        }
        let calories = normalizeEnergy(energy.value, unit: energy.unit)
        let protein = nutrient(numbers: ["203"], names: ["Protein"]).value
        let carbs = nutrient(numbers: ["205"], names: ["Carbohydrate"]).value
        let fat = nutrient(numbers: ["204"], names: ["Total lipid", "Fat"]).value

        let householdGrams = usda.servingSize.map { servingSizeInGrams(size: $0, unit: usda.servingSizeUnit) }
        let portionInputs = (usda.foodPortions ?? []).compactMap { portion -> ServingPortionMapper.PortionInput? in
            guard let gramWeight = portion.gramWeight, gramWeight > 0 else { return nil }
            let label = [
                portion.measureUnit?.abbreviation,
                portion.measureUnit?.name,
                portion.portionDescription
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            return ServingPortionMapper.PortionInput(
                amount: portion.amount ?? 1,
                gramWeight: gramWeight,
                label: label
            )
        }
        let parsedPortions = ServingPortionMapper.portions(
            householdText: usda.householdServingFullText,
            householdGrams: householdGrams,
            foodPortions: portionInputs
        )

        let servingGrams = parsedPortions.servingGrams
            ?? householdGrams
            ?? parsedPortions.tablespoonGrams
            ?? parsedPortions.teaspoonGrams
            ?? 100

        // FDC foodNutrients are always per 100 g / 100 ml for every data type, including
        // Branded (USDA converts the label panel onto a 100-unit basis). Scale to the
        // household serving; do not treat the raw values as "per labeled cup."
        let servingFactor = servingGrams > 0 ? servingGrams / 100.0 : 1
        let caloriesPer100g = calories
        let proteinPer100g = protein
        let carbsPer100g = carbs
        let fatPer100g = fat
        let caloriesPerServing = calories * servingFactor
        let proteinPerServing = protein * servingFactor
        let carbsPerServing = carbs * servingFactor
        let fatPerServing = fat * servingFactor

        // Pure fat is ~9 kcal/g and ≤100 g of any macro per 100 g. Rows above that are
        // corrupt FDC ingest (e.g. O Organics yogurt 2756031: 17300 kcal, serving 0.75 g).
        if caloriesPer100g > 950 || proteinPer100g > 100 || carbsPer100g > 100 || fatPer100g > 100 {
            return nil
        }

        let brand = usda.brandName ?? usda.brandOwner

        return Food(
            name: usda.description,
            brand: brand,
            source: .usda,
            barcode: usda.gtinUpc,
            externalId: String(usda.fdcId),
            caloriesPer100g: caloriesPer100g,
            proteinPer100g: proteinPer100g,
            carbsPer100g: carbsPer100g,
            fatPer100g: fatPer100g,
            servingSizeGrams: servingGrams,
            servingDescription: parsedPortions.servingDescription ?? usda.householdServingFullText,
            caloriesPerServing: caloriesPerServing,
            proteinPerServing: proteinPerServing,
            carbsPerServing: carbsPerServing,
            fatPerServing: fatPerServing,
            smallServingGrams: parsedPortions.smallServingGrams,
            mediumServingGrams: parsedPortions.mediumServingGrams,
            largeServingGrams: parsedPortions.largeServingGrams,
            teaspoonGrams: parsedPortions.teaspoonGrams,
            tablespoonGrams: parsedPortions.tablespoonGrams,
            cupGrams: parsedPortions.cupGrams
        )
    }

    private static func normalizeEnergy(_ value: Double, unit: String?) -> Double {
        let normalizedUnit = unit?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if normalizedUnit == "kj" || normalizedUnit.contains("kilojoule") {
            return value / 4.184
        }
        return value
    }

    private static func servingSizeInGrams(size: Double, unit: String?) -> Double {
        guard size > 0 else { return 100 }
        switch unit?.trimmingCharacters(in: .whitespaces).lowercased() ?? "g" {
        case "g", "grm", "gram", "grams": return size
        case "ml", "mlt", "milliliter", "milliliters": return size
        case "oz", "onz", "ounce", "ounces": return size * ServingConverter.gramsPerOunce
        default: return size
        }
    }

    static func normalizeBarcode(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        if digits.count <= 8 {
            return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        }
        if digits.count <= 12 {
            return String(repeating: "0", count: max(0, 13 - digits.count)) + digits
        }
        return digits
    }
}
