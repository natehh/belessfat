import Foundation
import UIKit

struct MacroEstimate: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var servingDescription: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var notes: String
    var listed: Bool
    var isSelected: Bool

    var macroLine: String {
        let calories = calories.formatted(.number.precision(.fractionLength(0)))
        let protein = protein.formatted(.number.precision(.fractionLength(0...1)))
        let carbs = carbs.formatted(.number.precision(.fractionLength(0...1)))
        let fat = fat.formatted(.number.precision(.fractionLength(0...1)))
        return "\(calories) kcal · \(protein)p · \(carbs)c · \(fat)f"
    }
}

struct MenuItemChoice: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var description: String
    var isSelected: Bool
}

enum MenuAIResponse {
    case items(restaurant: String, items: [MenuItemChoice])
    case estimates(restaurant: String, items: [MacroEstimate])
    case needsMenu(restaurant: String, reason: String)
}

enum AIMacroEstimateService {
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

    static func quickPrompt(foodNameHint: String?) -> String {
        let hint = foodNameHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hintBlock = hint.isEmpty
            ? ""
            : """

            Name or description from the user:
            \(hint)
            """
        return """
        Estimate one serving of this food for a calorie log.
        \(hintBlock)
        Use the photo if one is attached, plus the name or description. If calories or macros are already listed, use those.

        Reply with ONLY a single JSON object (no markdown, no explanation):
        {
          "name": "short food name",
          "serving_description": "what one serving is",
          "calories": 0,
          "protein": 0,
          "carbs": 0,
          "fat": 0,
          "notes": "short assumption, or empty"
        }

        protein, carbs, and fat are grams for that one serving.
        """
    }

    static func discoverPrompt(menuURL: String, photoCount: Int = 0) -> String {
        let urlLine = menuURL.isEmpty ? "No menu URL was provided." : "Menu URL: \(menuURL)"
        let photoLine = photoCount > 0
            ? "\(photoCount) menu photo\(photoCount == 1 ? " is" : "s are") attached. Use those as the menu when the page is missing or unreadable."
            : ""
        return """
        Read this restaurant menu and list the items a person could order.

        \(urlLine)
        \(photoLine)

        If you cannot read the page and no photos were attached, reply with ONLY:
        { "status": "needs_menu", "restaurant": "", "reason": "short reason" }

        Otherwise reply with ONLY:
        {
          "status": "items",
          "restaurant": "restaurant name",
          "items": [
            { "name": "item name", "description": "short description from the menu, or empty" }
          ]
        }
        """
    }

    static func estimatePrompt(
        menuURL: String?,
        restaurant: String?,
        requestedItemsText: String?,
        items: [MenuItemChoice],
        pastedText: String?
    ) -> String {
        var lines: [String] = [
            "Estimate one serving of each of these menu items for a calorie log.",
            ""
        ]
        if let menuURL, !menuURL.isEmpty {
            lines.append("Menu URL: \(menuURL)")
        }
        if let restaurant, !restaurant.isEmpty {
            lines.append("Restaurant: \(restaurant)")
        }
        let requested = requestedItemsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requested.isEmpty {
            lines.append("")
            lines.append("Items the user asked for:")
            lines.append(requested)
        }
        let chosen = items.filter(\.isSelected)
        if !chosen.isEmpty {
            lines.append("")
            lines.append("Items to estimate:")
            for item in chosen {
                let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if description.isEmpty {
                    lines.append("- \(item.name)")
                } else {
                    lines.append("- \(item.name): \(description)")
                }
            }
        }
        let pasted = pastedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pasted.isEmpty {
            lines.append("")
            lines.append("Menu text or descriptions from the user:")
            lines.append(clip(pasted))
        }
        lines.append("")
        lines.append(
            """
            Use the item name, description, photos, and any nutrition the menu already lists. If the menu lists calories or macros, use those and set listed to true. Photos may be attached.

            If you still cannot tell what the items are, reply with ONLY:
            { "status": "needs_menu", "restaurant": "", "reason": "short reason" }

            Otherwise reply with ONLY:
            {
              "status": "estimates",
              "restaurant": "restaurant name",
              "items": [
                {
                  "name": "item name",
                  "serving_description": "what one serving is",
                  "calories": 0,
                  "protein": 0,
                  "carbs": 0,
                  "fat": 0,
                  "listed": false,
                  "notes": "short assumption, or empty"
                }
              ]
            }

            protein, carbs, and fat are grams for that one serving.
            """
        )
        return lines.joined(separator: "\n")
    }

    static func copyQuickPromptToClipboard(foodNameHint: String?) {
        UIPasteboard.general.string = quickPrompt(foodNameHint: foodNameHint)
    }

    static func copyPromptToClipboard(_ prompt: String) {
        UIPasteboard.general.string = prompt
    }

    static func parseQuick(_ text: String) throws -> MacroEstimate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        guard let object = decodeJSONObject(from: trimmed) else {
            throw ParseError.invalidFormat("Could not find a JSON object in the reply.")
        }
        guard let estimate = macroEstimate(from: object, listedDefault: false) else {
            throw ParseError.invalidFormat("The reply needs a name and calories for one serving.")
        }
        return estimate
    }

    static func parseMenu(_ text: String) throws -> MenuAIResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        guard let object = decodeJSONObject(from: trimmed) else {
            throw ParseError.invalidFormat("Could not find a JSON object in the reply.")
        }
        let status = (object["status"] as? String)?.lowercased() ?? ""
        let restaurant = string(object["restaurant"])
        switch status {
        case "needs_menu", "needs_input", "blocked":
            let reason = string(object["reason"])
            return .needsMenu(
                restaurant: restaurant,
                reason: reason.isEmpty ? "The menu could not be read." : reason
            )
        case "items", "menu":
            let items = menuItems(from: object)
            guard !items.isEmpty else {
                throw ParseError.invalidFormat("The reply did not include any menu items.")
            }
            return .items(restaurant: restaurant, items: items)
        case "estimates", "foods":
            let items = macroItems(from: object)
            guard !items.isEmpty else {
                throw ParseError.invalidFormat("The reply did not include any estimates.")
            }
            return .estimates(restaurant: restaurant, items: items)
        default:
            if object["calories"] != nil, let estimate = macroEstimate(from: object, listedDefault: false) {
                return .estimates(restaurant: restaurant, items: [estimate])
            }
            let rawItems = object["items"] as? [[String: Any]] ?? []
            if rawItems.contains(where: { $0["calories"] != nil }) {
                let items = macroItems(from: object)
                guard !items.isEmpty else {
                    throw ParseError.invalidFormat("The reply did not include any estimates.")
                }
                return .estimates(restaurant: restaurant, items: items)
            }
            let items = menuItems(from: object)
            guard !items.isEmpty else {
                throw ParseError.invalidFormat("The reply needs menu items or nutrition estimates.")
            }
            return .items(restaurant: restaurant, items: items)
        }
    }

    private static func menuItems(from object: [String: Any]) -> [MenuItemChoice] {
        let raw = object["items"] as? [[String: Any]] ?? []
        return raw.compactMap { item in
            let name = string(item["name"])
            guard !name.isEmpty else { return nil }
            return MenuItemChoice(name: name, description: string(item["description"]), isSelected: false)
        }
    }

    private static func macroItems(from object: [String: Any]) -> [MacroEstimate] {
        let raw = object["items"] as? [[String: Any]] ?? []
        return raw.compactMap { macroEstimate(from: $0, listedDefault: false) }
    }

    private static func macroEstimate(from object: [String: Any], listedDefault: Bool) -> MacroEstimate? {
        let name = string(object["name"])
        guard !name.isEmpty, let calories = doubleValue(object["calories"]) else { return nil }
        let listed = (object["listed"] as? Bool) ?? listedDefault
        return MacroEstimate(
            name: name,
            servingDescription: string(object["serving_description"]),
            calories: calories,
            protein: doubleValue(object["protein"]) ?? 0,
            carbs: doubleValue(object["carbs"]) ?? 0,
            fat: doubleValue(object["fat"]) ?? 0,
            notes: string(object["notes"]),
            listed: listed,
            isSelected: true
        )
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func clip(_ text: String) -> String {
        let maxChars = 60_000
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars)) + "\n…[truncated]"
    }

    private static func decodeJSONObject(from text: String) -> [String: Any]? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.replacingOccurrences(
            of: #"```(?:json|JSON)?"#,
            with: "",
            options: .regularExpression
        )
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let extracted = extractBalancedJSONObject(from: trimmed) {
            candidates.insert(extracted, at: 0)
        }
        for candidate in candidates {
            let normalized = candidate
                .replacingOccurrences(of: "“", with: "\"")
                .replacingOccurrences(of: "”", with: "\"")
            guard let data = normalized.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return object
        }
        return nil
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
}
