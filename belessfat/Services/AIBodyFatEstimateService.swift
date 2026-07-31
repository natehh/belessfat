import Foundation
import SwiftData
import UIKit

struct AIBodyFatEstimateResult: Equatable {
    var bodyFatPercent: Double
    var notes: String?
}

enum AIBodyFatEstimateService {
    enum ParseError: LocalizedError {
        case empty
        case invalidFormat(String)
        case incompleteProfile

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Nothing to import. Paste the AI reply into the box first."
            case .invalidFormat(let detail):
                return detail
            case .incompleteProfile:
                return "Add height, sex, and birth year in Settings → Body profile before estimating."
            }
        }
    }

    struct ProfileContext {
        var heightInches: Double
        var sex: BiologicalSex
        var ageYears: Int
        var weightLbs: Double?
        var weightLabel: String?
        var contextDate: Date
    }

    @MainActor
    static func makeProfileContext(
        settings: UserSettings,
        date: Date,
        context: ModelContext
    ) throws -> ProfileContext {
        guard let height = settings.heightInches, height > 0,
              let sex = settings.biologicalSex,
              let age = settings.ageYears else {
            throw ParseError.incompleteProfile
        }
        let weight = ProgressPhotoService.weightForEstimate(on: date, context: context)
        return ProfileContext(
            heightInches: height,
            sex: sex,
            ageYears: age,
            weightLbs: weight?.lbs,
            weightLabel: weight?.label,
            contextDate: date
        )
    }

    static func prompt(profile: ProfileContext, imageCount: Int) -> String {
        let heightTotal = Int(profile.heightInches.rounded())
        let feet = heightTotal / 12
        let inches = heightTotal % 12
        let weightLine: String
        if let label = profile.weightLabel {
            weightLine = "Weight: \(label)"
        } else {
            weightLine = "Weight: unknown (not logged near this date)"
        }
        let dateLine = profile.contextDate.formatted(date: .abbreviated, time: .omitted)

        return """
        Visually estimate body fat percentage from the attached photo(s).

        Subject profile:
        - Date of photos / estimate: \(dateLine)
        - Height: \(feet)'\(inches)" (\(heightTotal) in)
        - Biological sex: \(profile.sex.displayName)
        - Age: \(profile.ageYears) years
        - \(weightLine)
        - Number of photos attached: \(imageCount)

        Work privately:
        1. Consider visible fat distribution, muscle definition, waist/hip cues, and lighting limitations.
        2. Prefer a single overall body-fat % that best fits all photos together (one combined estimate).
        3. If uncertain, form a plausible range and report the midpoint rounded to one decimal.

        Reply with ONLY a single JSON object (no markdown, no explanation):
        {
          "body_fat_percent": 18.5,
          "notes": null
        }

        Rules:
        - body_fat_percent must be a number between 3 and 60.
        - notes may be a short string or null.
        - This is a visual estimate only — not DEXA, calipers, or medical advice.
        """
    }

    static func copyPromptToClipboard(profile: ProfileContext, imageCount: Int) {
        UIPasteboard.general.string = prompt(profile: profile, imageCount: imageCount)
    }

    static func parse(_ text: String) throws -> AIBodyFatEstimateResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        guard let object = decodeJSONObject(from: trimmed) else {
            let preview = trimmed.replacingOccurrences(of: "\n", with: " ").prefix(120)
            throw ParseError.invalidFormat("Couldn’t parse that reply as body-fat JSON. Preview: \(preview)")
        }

        let percent = number(object["body_fat_percent"])
            ?? number(object["bodyFatPercent"])
            ?? number(object["body_fat"])
            ?? number(object["bf_percent"])
            ?? number(object["percent"])

        guard let percent, percent >= 3, percent <= 60 else {
            throw ParseError.invalidFormat("Missing or invalid body_fat_percent (expected 3–60).")
        }

        let notes = (object["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIBodyFatEstimateResult(
            bodyFatPercent: (percent * 10).rounded() / 10,
            notes: notes?.isEmpty == true ? nil : notes
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String {
            return Double(s.filter { "0123456789.-".contains($0) })
        }
        return nil
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
        result = result.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        return result
    }
}
