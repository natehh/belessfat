import Foundation
import UIKit

struct AIFoodEstimateResult {
    var name: String
    var brand: String?
    var servingDescription: String?
    var servingAmount: Double?
    var servingUnit: ServingUnitType
    var gramWeight: Double?
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
}

enum AIFoodEstimateService {
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

    static func prompt(foodNameHint: String? = nil) -> String {
        let hint = foodNameHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hintBlock: String
        if hint.isEmpty {
            hintBlock = ""
        } else {
            hintBlock = """

User-provided food name / description (use this to identify the dish; still verify against the photo when one is attached):
\(hint)

"""
        }

        return """
Estimate nutrition for the food or meal in the attached photo.
\(hintBlock)
Work through these steps privately (do not write them out):
1. Identify the dish and each distinct food or ingredient that is visible\(hint.isEmpty ? "" : " (prefer the user-provided name when it fits)").
2. Infer how this dish is typically prepared (common recipes / restaurant versions). Add likely ingredients that often are not visible — cooking oil or butter, dressings, sauces, cheese, cream, sugar, marinades — when they fit this food type. Skip them only when the dish is clearly dry, plain, or packaged with no such prep.
3. Estimate a realistic amount for each visible and inferred ingredient (volume, count, or grams from visual cues and typical prep).
4. Assign calories and macros to each ingredient from typical values for that food.
5. Sum everything into one total for the whole serving shown. Prefer the sum of parts over a single plate guess.

Reply with ONLY a single JSON object (no markdown, no explanation) using exactly these keys:
{
  "name": "short food name",
  "brand": null,
  "serving_description": "e.g. 1 plate or 1 sandwich",
  "serving_amount": 1,
  "serving_unit": "serving",
  "grams": null,
  "calories": 0,
  "protein_g": 0,
  "carbs_g": 0,
  "fat_g": 0
}

Rules:
- Values are for ONE serving as shown / described (the totals after summing ingredients).
- serving_unit must be one of: grams, ounces, teaspoon, tablespoon, cup, serving
- Use grams for serving_amount when the best unit is weight; otherwise put weight in "grams" if known, or null.
- Numbers only for macros. Estimate if unsure; do not invent precision.
- Prefer typical-prep inference over assuming zero oil/sauce when those are common for the dish.
- When a value is uncertain, form a plausible range privately, then report the TOP of that range (e.g. if you think 800–1000 kcal, output 1000). Do not pad beyond your honest high end, and do not invent a wider range just to inflate numbers.
- name should describe the whole meal briefly (e.g. "chicken bowl with rice and avocado"), not a single ingredient.\(hint.isEmpty ? "" : " Prefer the user-provided name when it is accurate.")
"""
    }

    static func copyPromptToClipboard(foodNameHint: String? = nil) {
        UIPasteboard.general.string = prompt(foodNameHint: foodNameHint)
    }

    static func parse(_ text: String) throws -> AIFoodEstimateResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        if let object = decodeJSONObject(from: trimmed) {
            return try result(from: object)
        }
        if let object = decodeLooseKeyValues(from: trimmed) {
            return try result(from: object)
        }

        let preview = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(120)
        throw ParseError.invalidFormat(
            "Couldn’t parse that reply. Paste only the JSON object (or the whole AI reply) into the box. Preview: \(preview)"
        )
    }

    private static func decodeJSONObject(from text: String) -> [String: Any]? {
        let candidates = jsonCandidates(from: text)
        for candidate in candidates {
            let normalized = normalizeJSONText(candidate)
            guard let data = normalized.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = array.first {
                return first
            }
        }
        return nil
    }

    private static func jsonCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown fences anywhere, not only at the start.
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
        if let extractedArray = extractBalancedJSONArray(from: trimmed) {
            candidates.insert(extractedArray, at: 0)
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

    private static func extractBalancedJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
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
                case "[": depth += 1
                case "]":
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
        // Smart quotes → ASCII
        result = result
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        // Python-ish null / bools
        result = result
            .replacingOccurrences(of: #"\bNone\b"#, with: "null", options: .regularExpression)
        result = result
            .replacingOccurrences(of: #"\bTrue\b"#, with: "true", options: .regularExpression)
        result = result
            .replacingOccurrences(of: #"\bFalse\b"#, with: "false", options: .regularExpression)
        // Trailing commas before } or ]
        result = result.replacingOccurrences(
            of: #",(\s*[}\]])"#,
            with: "$1",
            options: .regularExpression
        )
        return result
    }

    private static func decodeLooseKeyValues(from text: String) -> [String: Any]? {
        var object: [String: Any] = [:]
        let pattern = #"(?im)^\s*["']?([A-Za-z0-9_ ]+)["']?\s*[:=]\s*["']?([^,"}\n]+)["']?\s*,?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { return }
            let key = String(text[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(value.filter { "0123456789.-".contains($0) }),
               value.rangeOfCharacter(from: .decimalDigits) != nil,
               !value.contains(where: { $0.isLetter }) {
                object[key] = number
            } else if value.lowercased() == "null" || value.lowercased() == "none" {
                object[key] = NSNull()
            } else {
                object[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return object.isEmpty ? nil : object
    }

    private static func result(from object: [String: Any]) throws -> AIFoodEstimateResult {
        let lookup = NormalizedLookup(object)

        let name = lookup.string(
            "name", "food", "food_name", "title", "item", "description"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let calories = lookup.number("calories", "kcal", "energy", "energy_kcal", "cals") ?? 0
        let protein = lookup.number("protein_g", "protein", "protein_grams", "prot") ?? 0
        let carbs = lookup.number("carbs_g", "carbs", "carbohydrates", "carbohydrate", "carb") ?? 0
        let fat = lookup.number("fat_g", "fat", "total_fat", "fats") ?? 0

        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else if calories > 0 || protein > 0 || carbs > 0 || fat > 0 {
            resolvedName = "AI Estimated Food"
        } else {
            throw ParseError.invalidFormat(
                "Found text, but no food name or macros. Make sure the reply includes name/calories/protein/carbs/fat."
            )
        }

        let unitRaw = lookup.string("serving_unit", "unit", "serving unit")?.lowercased() ?? "serving"
        let unit = parseUnit(unitRaw)

        var amount = lookup.number("serving_amount", "amount", "quantity", "servings")
        var grams = lookup.number("grams", "gram_weight", "serving_grams", "weight_g", "weight")
        if unit == .grams, grams == nil, let amount {
            grams = amount
        }
        if unit == .grams, amount == nil, let grams {
            amount = grams
        }

        return AIFoodEstimateResult(
            name: resolvedName,
            brand: lookup.string("brand", "brand_name"),
            servingDescription: lookup.string(
                "serving_description", "serving", "serving_size", "portion", "serving description"
            ),
            servingAmount: amount,
            servingUnit: unit,
            gramWeight: grams,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat
        )
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

    private struct NormalizedLookup {
        private let map: [String: Any]

        init(_ object: [String: Any]) {
            var normalized: [String: Any] = [:]
            for (key, value) in object {
                normalized[Self.normalizeKey(key)] = value
            }
            self.map = normalized
        }

        func string(_ keys: String...) -> String? {
            for key in keys {
                let value = map[Self.normalizeKey(key)]
                if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
            return nil
        }

        func number(_ keys: String...) -> Double? {
            for key in keys {
                let value = map[Self.normalizeKey(key)]
                if let number = value as? NSNumber { return number.doubleValue }
                if let string = value as? String {
                    let sanitized = string
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: ",", with: "")
                        .filter { "0123456789.-".contains($0) }
                    if let parsed = Double(sanitized) { return parsed }
                }
            }
            return nil
        }

        private static func normalizeKey(_ key: String) -> String {
            key.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
        }
    }
}
