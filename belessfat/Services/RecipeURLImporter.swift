import Foundation
import SwiftData

struct RecipeImportIngredient: Identifiable {
    let id = UUID()
    var rawText: String
    /// AI / parser search query used for USDA matching; preferred when resolving manually.
    var searchName: String
    var food: Food?
    var quantity: Double
    var servingUnit: ServingUnitType
    var isUncertain: Bool

    var isResolved: Bool { food != nil && !isUncertain }
}

struct ParsedWebRecipe {
    var name: String
    var servings: Double
    var ingredients: [RecipeImportIngredient]
}

/// Fetches recipe pages and turns HTML into plain text for AI import.
enum RecipeURLImporter {
    enum ImportError: LocalizedError {
        case invalidURL
        case fetchFailed
        case emptyPage
        case noSource
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL."
            case .fetchFailed: return "Could not download recipe page."
            case .emptyPage: return "The page had no usable text."
            case .noSource: return "Enter a recipe URL or paste recipe text first."
            case .network(let e): return e.localizedDescription
            }
        }
    }

    struct FetchedPage {
        let url: URL
        let text: String
    }

    static func fetchPageText(from urlString: String) async throws -> FetchedPage {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ImportError.invalidURL
        }

        let html: String
        do {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) belessfat/1.0",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw ImportError.fetchFailed
            }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw ImportError.fetchFailed
            }
            html = text
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.network(error)
        }

        let plain = plainText(fromHTML: html)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyPage
        }
        return FetchedPage(url: url, text: plain)
    }

    static func plainText(fromHTML html: String) -> String {
        var text = html
        // Drop scripts/styles/noscript.
        let blockPatterns = [
            #"<script[^>]*>[\s\S]*?</script>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
            #"<noscript[^>]*>[\s\S]*?</noscript>"#
        ]
        for pattern in blockPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Line breaks for common block tags.
        text = text.replacingOccurrences(
            of: #"</?(p|div|li|br|tr|h[1-6]|section|article)[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        // Strip remaining tags.
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        // Decode a few common entities.
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&mdash;", "—"),
            ("&ndash;", "–")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: #"&#(\d+);"#, with: " ", options: .regularExpression)

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var collapsed = lines.joined(separator: "\n")
        while collapsed.contains("  ") {
            collapsed = collapsed.replacingOccurrences(of: "  ", with: " ")
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
