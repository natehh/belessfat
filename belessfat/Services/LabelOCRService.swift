import Foundation
import Vision
import UIKit

enum LabelOCRService {
    private static let nutrientTokens = [
        "calories", "total fat", "saturated fat", "trans fat", "cholesterol",
        "sodium", "total carbohydrate", "dietary fiber", "total sugars", "protein", "serving size"
    ]

    static func parseLabel(from image: UIImage) async throws -> ParsedLabelNutrition {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        let observations = try await recognizeText(in: cgImage)
        let lines = observations.compactMap { obs -> (String, CGRect)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return (text, obs.boundingBox)
        }

        var warnings: [String] = []
        let fullText = lines.map(\.0).joined(separator: "\n")

        var calories = extractValue(from: fullText, patterns: [#"calories\s*(\d+)"#, #"(\d+)\s*calories"#])
        var fat = extractValue(from: fullText, patterns: [#"total fat\s*([\d.]+)\s*g"#, #"fat\s*([\d.]+)\s*g"#])
        var carbs = extractValue(from: fullText, patterns: [#"total carbohydrate\s*([\d.]+)\s*g"#, #"carbohydrate\s*([\d.]+)\s*g"#])
        var protein = extractValue(from: fullText, patterns: [#"protein\s*([\d.]+)\s*g"#])
        var servingSize = extractString(from: fullText, pattern: #"serving size\s*(.+)"#) ?? "1 serving"
        var servingGrams = parseServingGrams(from: servingSize) ?? 100

        if calories == 0 || protein == 0 {
            let paired = parseByLayout(lines: lines)
            if calories == 0 { calories = paired.calories }
            if fat == 0 { fat = paired.fat }
            if carbs == 0 { carbs = paired.carbs }
            if protein == 0 { protein = paired.protein }
        }

        let computed = protein * 4 + carbs * 4 + fat * 9
        if calories > 0 && abs(calories - computed) > 30 {
            warnings.append("Calories don't match macros (\(Int(computed)) vs \(Int(calories))). Please review.")
        }

        if calories == 0 && protein == 0 && carbs == 0 && fat == 0 {
            warnings.append("Could not extract nutrition values. Please enter manually.")
        }

        return ParsedLabelNutrition(
            name: "",
            servingSize: servingSize,
            servingSizeGrams: servingGrams,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            warnings: warnings
        )
    }

    private static func recognizeText(in image: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.customWords = ["Calories", "Protein", "Carbohydrate", "Serving Size", "Total Fat"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func parseByLayout(lines: [(String, CGRect)]) -> (calories: Double, fat: Double, carbs: Double, protein: Double) {
        var calories = 0.0, fat = 0.0, carbs = 0.0, protein = 0.0
        for (text, box) in lines {
            let lower = text.lowercased()
            let number = extractFirstNumber(from: text)
            guard number > 0 else { continue }
            if fuzzyMatch(lower, "calories") { calories = number }
            else if fuzzyMatch(lower, "total fat") { fat = number }
            else if fuzzyMatch(lower, "total carbohydrate") { carbs = number }
            else if fuzzyMatch(lower, "protein") && !lower.contains("calories") { protein = number }
            _ = box
        }
        return (calories, fat, carbs, protein)
    }

    private static func fuzzyMatch(_ text: String, _ token: String) -> Bool {
        if text.contains(token) { return true }
        return levenshtein(text, token) <= 2
    }

    private static func extractValue(from text: String, patterns: [String]) -> Double {
        for pattern in patterns {
            if let matched = extractString(from: text, pattern: pattern) {
                let value = extractFirstNumber(from: matched)
                if value > 0 { return value }
            }
            let value = extractFirstNumber(from: text)
            if value > 0, text.range(of: pattern, options: .regularExpression) != nil {
                return value
            }
        }
        return 0
    }

    private static func extractString(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture]).trimmingCharacters(in: .whitespaces)
    }

    private static func extractFirstNumber(from text: String) -> Double {
        let pattern = #"([\d.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return 0 }
        return Double(text[range]) ?? 0
    }

    private static func parseServingGrams(from serving: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*g"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: serving, range: NSRange(serving.startIndex..., in: serving)),
              let range = Range(match.range(at: 1), in: serving) else { return nil }
        return Double(serving[range])
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dist = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dist[i][0] = i }
        for j in 0...b.count { dist[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                dist[i][j] = min(
                    dist[i-1][j] + 1,
                    dist[i][j-1] + 1,
                    dist[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1)
                )
            }
        }
        return dist[a.count][b.count]
    }

    enum OCRError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "Invalid image for OCR." }
    }
}
