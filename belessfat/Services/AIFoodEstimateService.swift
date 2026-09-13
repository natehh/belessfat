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

        let weightUnit = ServingConverter.preferredWeightUnit
        let weightUnitName = weightUnit == .ounces ? "ounces" : "grams"
        let exampleQuantity = weightUnit == .ounces ? 7 : 200
        let exampleUnit = weightUnitName

        return """
Identify the food or meal in the attached photo as structured ingredients for a calorie tracker.
\(hintBlock)
Work through these steps privately (do not write them out):
1. Identify the dish and each distinct food or ingredient that is visible\(hint.isEmpty ? "" : " (prefer the user-provided name when it fits)").
2. Estimate a realistic amount for each visible item from visual cues (portion size, container, typical serving). Prefer \(weightUnitName).
3. Give each item a short search_name that will match USDA / grocery food search (e.g. "cooked white rice", "grilled chicken breast", "avocado").

Reply with ONLY a single JSON object (no markdown, no explanation) using exactly this shape:
{
  "name": "short meal name",
  "servings": 1,
  "ingredients": [
    {
      "raw": "what you see, e.g. scoop of rice",
      "search_name": "cooked white rice",
      "quantity": \(exampleQuantity),
      "unit": "\(exampleUnit)"
    }
  ]
}

Rules:
- servings is always 1 (the plate / serving shown).
- unit must be one of: grams, ounces, teaspoon, tablespoon, cup, serving
- Prefer \(weightUnitName) whenever you can estimate weight. Use teaspoon/tablespoon/cup only for small condiments or when weight is clearly worse.
- Do NOT invent calories, macros, USDA fdcIds, or other database ids. The app looks those up.
- Base the list only on what is visible (and the user-provided name/description when given). Do not add invisible cooking oil, butter, dressings, sauces, marinades, or other prep ingredients unless they are clearly visible in the photo or explicitly mentioned by the user.
- When an amount is uncertain, form a plausible range privately, then use the MIDPOINT (e.g. if you think \(weightUnit == .ounces ? "5–9 oz, output 7" : "150–250 g, output 200")). Do not use the high end, and do not invent a wider range to inflate amounts.
- name should describe the whole meal briefly (e.g. "chicken bowl with rice and avocado"), not a single ingredient.\(hint.isEmpty ? "" : " Prefer the user-provided name when it is accurate.")
- Include every distinct visible item. Skip garnish so small it would not change nutrition.
"""
    }

    static func copyPromptToClipboard(foodNameHint: String? = nil) {
        UIPasteboard.general.string = prompt(foodNameHint: foodNameHint)
    }

    static func parse(_ text: String) throws -> AIRecipeImportDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        do {
            var draft = try AIRecipeImportService.parse(text)
            draft.servings = 1
            return draft
        } catch {
            if looksLikeLegacyMacroJSON(trimmed) {
                throw ParseError.invalidFormat(
                    "This reply has calories but no ingredients. Copy the updated prompt so the AI returns items and amounts — macros come from the food database."
                )
            }
            throw ParseError.invalidFormat(error.localizedDescription)
        }
    }

    private static func looksLikeLegacyMacroJSON(_ text: String) -> Bool {
        let lower = text.lowercased()
        let hasMacros = lower.contains("calories") || lower.contains("protein_g") || lower.contains("\"protein\"")
        let hasIngredients = lower.contains("\"ingredients\"")
        return hasMacros && !hasIngredients
    }
}
