import Foundation

enum OpenFoodFactsClient {
    struct ProductResponse: Decodable {
        let status: Int
        let product: OFFProduct?
    }

    struct OFFProduct: Decodable {
        let productName: String?
        let brands: String?
        let code: String?
        let servingSize: String?
        let nutriments: Nutriments?
    }

    struct Nutriments: Decodable {
        let energyKcal100g: Double?
        let proteins100g: Double?
        let carbohydrates100g: Double?
        let fat100g: Double?
        let energyKcalServing: Double?
        let proteinsServing: Double?
        let carbohydratesServing: Double?
        let fatServing: Double?

        enum CodingKeys: String, CodingKey {
            case energyKcal100g = "energy-kcal_100g"
            case proteins100g = "proteins_100g"
            case carbohydrates100g = "carbohydrates_100g"
            case fat100g = "fat_100g"
            case energyKcalServing = "energy-kcal_serving"
            case proteinsServing = "proteins_serving"
            case carbohydratesServing = "carbohydrates_serving"
            case fatServing = "fat_serving"
        }
    }

    struct SearchResponse: Decodable {
        let products: [OFFProduct]?
    }

    enum ClientError: LocalizedError {
        case invalidURL
        case notFound
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Open Food Facts URL."
            case .notFound: return "Product not found in Open Food Facts."
            case .networkError(let e): return e.localizedDescription
            }
        }
    }

    static func lookupBarcode(_ barcode: String) async throws -> Food? {
        let normalized = USDAClient.normalizeBarcode(barcode)
        guard let url = URL(string: "\(AppConfig.offBaseURL)/product/\(normalized).json") else {
            throw ClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(AppConfig.offUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(ProductResponse.self, from: data)
        guard decoded.status == 1, let product = decoded.product else {
            return nil
        }
        return mapProduct(product, barcode: normalized)
    }

    static func search(query: String) async throws -> [Food] {
        guard var components = URLComponents(string: "\(AppConfig.offBaseURL)/search") else {
            throw ClientError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "fields", value: "product_name,brands,code,serving_size,nutriments")
        ]
        guard let url = components.url else { throw ClientError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.offUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (decoded.products ?? []).compactMap { mapProduct($0, barcode: $0.code) }
    }

    static func mapProduct(_ product: OFFProduct, barcode: String?) -> Food? {
        guard let name = product.productName, !name.isEmpty else { return nil }
        let n = product.nutriments

        let cal100 = n?.energyKcal100g ?? 0
        let protein100 = n?.proteins100g ?? 0
        let carbs100 = n?.carbohydrates100g ?? 0
        let fat100 = n?.fat100g ?? 0

        let servingGrams = parseServingGrams(product.servingSize) ?? 100
        let parsedPortions = ServingPortionMapper.portions(
            householdText: product.servingSize,
            householdGrams: parseServingGrams(product.servingSize)
        )
        let effectiveServingGrams = parsedPortions.servingGrams ?? servingGrams
        let calServing = n?.energyKcalServing ?? (cal100 * effectiveServingGrams / 100)
        let proteinServing = n?.proteinsServing ?? (protein100 * effectiveServingGrams / 100)
        let carbsServing = n?.carbohydratesServing ?? (carbs100 * effectiveServingGrams / 100)
        let fatServing = n?.fatServing ?? (fat100 * effectiveServingGrams / 100)

        return Food(
            name: name,
            brand: product.brands,
            source: .off,
            barcode: barcode ?? product.code,
            externalId: product.code,
            caloriesPer100g: cal100,
            proteinPer100g: protein100,
            carbsPer100g: carbs100,
            fatPer100g: fat100,
            servingSizeGrams: effectiveServingGrams,
            servingDescription: parsedPortions.servingDescription ?? product.servingSize,
            caloriesPerServing: calServing,
            proteinPerServing: proteinServing,
            carbsPerServing: carbsServing,
            fatPerServing: fatServing,
            teaspoonGrams: parsedPortions.teaspoonGrams,
            tablespoonGrams: parsedPortions.tablespoonGrams,
            cupGrams: parsedPortions.cupGrams
        )
    }

    private static func parseServingGrams(_ serving: String?) -> Double? {
        guard let serving else { return nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*g"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: serving, range: NSRange(serving.startIndex..., in: serving)),
              let range = Range(match.range(at: 1), in: serving) else { return nil }
        return Double(serving[range])
    }
}
