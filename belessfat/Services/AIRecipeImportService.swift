import Foundation
import SwiftData
import UIKit

struct AIRecipeIngredientDraft {
    var rawText: String
    var searchName: String
    var quantity: Double
    var servingUnit: ServingUnitType
}

struct AIRecipeImportDraft {
    var name: String
    var servings: Double
    var ingredients: [AIRecipeIngredientDraft]
}

enum AIRecipeImportService {
    enum ParseError: LocalizedError {
        case empty
        case invalidFormat(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Nothing to import. Paste the AI reply into the box first."
            case .invalidFormat(let detail):
                return detail
            }
        }
    }

    static func prompt(sourceText: String, sourceURL: String?) -> String {
        let clipped = clipSourceText(sourceText)
        let urlLine = sourceURL.map { "Source URL: \($0)\n" } ?? ""
        return """
        Extract a cooking recipe from the source text below into structured ingredients for a calorie tracker.

        \(urlLine)Work privately:
        1. Find the recipe title, yield/servings, and ingredient list (ignore ads, comments, nutrition widgets unless they are the only source).
        2. For each ingredient line, normalize quantity + unit and a short search_name good for USDA / grocery food search (e.g. "olive oil", "all-purpose flour", "boneless chicken breast").
        3. Prefer weight (grams/ounces) when the line gives weight; otherwise use teaspoon, tablespoon, cup, or serving.
        4. Skip non-food lines (equipment, "to taste" with no item). Keep "to taste" items only if you can assign a small plausible amount.

        Reply with ONLY a single JSON object (no markdown, no explanation):
        {
          "name": "recipe title",
          "servings": 4,
          "ingredients": [
            {
              "raw": "original ingredient line",
              "search_name": "short food search query",
              "quantity": 1,
              "unit": "cup"
            }
          ]
        }

        Rules:
        - unit must be one of: grams, ounces, teaspoon, tablespoon, cup, serving
        - Do NOT invent USDA fdcIds or database ids.
        - Do NOT invent nutrition macros; only structure the ingredients.
        - servings must be a positive number (default 1 if unknown).
        - search_name should omit prep notes like "diced" when they hurt search; keep important fat/cut words (e.g. "chicken thigh").

        SOURCE TEXT:
        \(clipped)
        """
    }

    static func copyPromptToClipboard(sourceText: String, sourceURL: String?) {
        UIPasteboard.general.string = prompt(sourceText: sourceText, sourceURL: sourceURL)
    }

    static func parse(_ text: String) throws -> AIRecipeImportDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        guard let object = decodeJSONObject(from: trimmed) else {
            let preview = trimmed.replacingOccurrences(of: "\n", with: " ").prefix(120)
            throw ParseError.invalidFormat(
                "Couldn’t parse that reply as recipe JSON. Preview: \(preview)"
            )
        }
        return try draft(from: object)
    }

    static func matchIngredients(
        _ draft: AIRecipeImportDraft,
        context: ModelContext
    ) async -> ParsedWebRecipe {
        var items: [RecipeImportIngredient] = []
        for ingredient in draft.ingredients {
            let query = ingredient.searchName.trimmingCharacters(in: .whitespacesAndNewlines)
            var food: Food?
            var uncertain = true
            if !query.isEmpty {
                let results = (try? await FoodService.search(query: query, context: context)) ?? []
                if let best = pickBestMatch(query: query, results: results) {
                    food = best.food
                    uncertain = best.uncertain
                }
            }
            items.append(RecipeImportIngredient(
                rawText: ingredient.rawText.isEmpty ? query : ingredient.rawText,
                searchName: query,
                food: food,
                quantity: max(ingredient.quantity, 0.01),
                servingUnit: ingredient.servingUnit,
                isUncertain: uncertain || food == nil
            ))
        }
        return ParsedWebRecipe(
            name: draft.name.isEmpty ? "Imported Recipe" : draft.name,
            servings: max(draft.servings, 0.25),
            ingredients: items
        )
    }

    // MARK: - Matching

    private static func pickBestMatch(
        query: String,
        results: [Food]
    ) -> (food: Food, uncertain: Bool)? {
        guard let first = results.first else { return nil }

        // Prefer custom foods with decent name overlap.
        if let custom = results.first(where: { $0.source == .custom }),
           nameSimilarity(query, custom.name) >= 0.25 {
            return (custom, nameSimilarity(query, custom.name) < 0.35)
        }

        let score = nameSimilarity(query, first.name)
        if results.count <= 3 || score > 0.35 {
            return (first, score < 0.2)
        }
        if score >= 0.2 {
            return (first, true)
        }
        return nil
    }

    private static func nameSimilarity(_ a: String, _ b: String) -> Double {
        let sa = Set(a.lowercased().split(separator: " ").filter { $0.count > 1 })
        let sb = Set(b.lowercased().split(separator: " ").filter { $0.count > 1 })
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    // MARK: - Parse helpers

    private static func draft(from object: [String: Any]) throws -> AIRecipeImportDraft {
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Imported Recipe"
        let servings = number(object["servings"]) ?? number(object["yield"]) ?? number(object["recipeYield"]) ?? 1

        guard let rawIngredients = object["ingredients"] as? [[String: Any]], !rawIngredients.isEmpty else {
            throw ParseError.invalidFormat("JSON is missing a non-empty ingredients array.")
        }

        var ingredients: [AIRecipeIngredientDraft] = []
        for item in rawIngredients {
            let raw = (item["raw"] as? String)
                ?? (item["raw_text"] as? String)
                ?? (item["line"] as? String)
                ?? ""
            let search = (item["search_name"] as? String)
                ?? (item["searchName"] as? String)
                ?? (item["name"] as? String)
                ?? raw
            let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSearch.isEmpty else { continue }
            let quantity = number(item["quantity"]) ?? number(item["amount"]) ?? 1
            let unit = parseUnit((item["unit"] as? String) ?? (item["serving_unit"] as? String) ?? "serving")
            ingredients.append(AIRecipeIngredientDraft(
                rawText: raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedSearch : raw,
                searchName: trimmedSearch,
                quantity: max(quantity, 0.01),
                servingUnit: unit
            ))
        }

        guard !ingredients.isEmpty else {
            throw ParseError.invalidFormat("No usable ingredients found in the AI reply.")
        }

        return AIRecipeImportDraft(
            name: name.isEmpty ? "Imported Recipe" : name,
            servings: max(servings, 0.25),
            ingredients: ingredients
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String {
            let filtered = s.filter { "0123456789.-/".contains($0) }
            if filtered.contains("/") {
                let parts = filtered.split(separator: "/")
                if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
                    return n / d
                }
            }
            return Double(filtered)
        }
        return nil
    }

    private static func parseUnit(_ raw: String) -> ServingUnitType {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "g", "gram", "grams": return .grams
        case "oz", "ounce", "ounces": return .ounces
        case "tsp", "teaspoon", "teaspoons": return .teaspoon
        case "tbsp", "tablespoon", "tablespoons": return .tablespoon
        case "cup", "cups": return .cup
        default: return .serving
        }
    }

    private static func clipSourceText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxChars = 60_000
        if trimmed.count <= maxChars { return trimmed }
        return String(trimmed.prefix(maxChars)) + "\n…[truncated]"
    }

    private static func decodeJSONObject(from text: String) -> [String: Any]? {
        for candidate in jsonCandidates(from: text) {
            let normalized = normalizeJSONText(candidate)
            guard let data = normalized.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    private static func jsonCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.replacingOccurrences(
            of: #"```(?:json|JSON)?"#,
            with: "",
            options: .regularExpression
        )
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        candidates.append(trimmed)
        if let extracted = extractBalancedJSONObject(from: trimmed) {
            candidates.insert(extracted, at: 0)
        }
        return candidates
    }

    private static func extractBalancedJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func normalizeJSONText(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        result = result.replacingOccurrences(of: #"\bNone\b"#, with: "null", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\bTrue\b"#, with: "true", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\bFalse\b"#, with: "false", options: .regularExpression)
        result = result.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        return result
    }
}
