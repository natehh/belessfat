import Foundation

enum WgerClient {
    struct PaginatedResponse<T: Decodable>: Decodable {
        let count: Int?
        let next: String?
        let results: [T]?
    }

    struct ExerciseTranslation: Decodable {
        let id: Int
        let name: String
        let exercise: Int
    }

    struct ExerciseInfoResponse: Decodable {
        let id: Int
        let category: NamedItem?
        let muscles: [NamedItem]?
        let equipment: [NamedItem]?
        let translations: [Translation]?
    }

    struct NamedItem: Decodable {
        let name: String?
    }

    struct Translation: Decodable {
        let name: String?
        let language: Int?
        let description: String?
    }

    struct SearchResult: Identifiable {
        let id: Int
        let name: String
    }

    enum ClientError: LocalizedError {
        case invalidURL
        case networkError(Error)
        case decodingError
        case notFound
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid wger API URL."
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .decodingError: return "Failed to decode wger response."
            case .notFound: return "Exercise not found."
            case .apiError(let msg): return msg
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var translationCache: [ExerciseTranslation]?

    static func search(query: String) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let translations = try await loadTranslationCache()
        let needle = trimmed.lowercased()

        var seen = Set<Int>()
        var results: [SearchResult] = []
        for translation in translations {
            guard translation.name.lowercased().contains(needle) else { continue }
            guard !seen.contains(translation.exercise) else { continue }
            seen.insert(translation.exercise)
            results.append(SearchResult(id: translation.exercise, name: translation.name))
        }

        return sortResults(results, query: trimmed)
    }

    static func fetchExerciseInfo(id: Int) async throws -> ExerciseInfoResponse {
        guard var components = URLComponents(string: "\(AppConfig.wgerBaseURL)/exerciseinfo/\(id)/") else {
            throw ClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw ClientError.invalidURL }

        let data = try await fetchData(from: url)
        return try decode(ExerciseInfoResponse.self, from: data)
    }

    static func makeExercise(from info: ExerciseInfoResponse, fallbackName: String) -> Exercise {
        let englishName = info.translations?.first(where: { $0.language == 2 })?.name
            ?? info.translations?.first?.name
            ?? fallbackName
        let category = info.category?.name
        let muscles = info.muscles?.compactMap(\.name).joined(separator: ", ")
        let equipment = info.equipment?.compactMap(\.name).joined(separator: ", ")
        let met = ExerciseMETDefaults.met(forCategory: category)
        return Exercise(
            name: englishName,
            wgerId: info.id,
            categoryName: category,
            muscleNames: muscles,
            equipmentNames: equipment,
            metValue: met,
            isCustom: false
        )
    }

    private static func loadTranslationCache() async throws -> [ExerciseTranslation] {
        cacheLock.lock()
        if let translationCache {
            cacheLock.unlock()
            return translationCache
        }
        cacheLock.unlock()

        var all: [ExerciseTranslation] = []
        var offset = 0
        let pageSize = 200
        var hasMore = true

        while hasMore {
            guard var components = URLComponents(string: "\(AppConfig.wgerBaseURL)/exercise-translation/") else {
                throw ClientError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "language", value: "2"),
                URLQueryItem(name: "ordering", value: "name"),
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "format", value: "json")
            ]
            guard let url = components.url else { throw ClientError.invalidURL }

            let data = try await fetchData(from: url)
            let page = try decode(PaginatedResponse<ExerciseTranslation>.self, from: data)
            let batch = page.results ?? []
            all.append(contentsOf: batch)
            hasMore = page.next != nil && !batch.isEmpty
            offset += pageSize
        }

        cacheLock.lock()
        translationCache = all
        cacheLock.unlock()
        return all
    }

    private static func sortResults(_ results: [SearchResult], query: String) -> [SearchResult] {
        let lower = query.lowercased()
        return results.sorted { lhs, rhs in
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            let lhsExact = lhsName == lower
            let rhsExact = rhsName == lower
            if lhsExact != rhsExact { return lhsExact }
            let lhsStarts = lhsName.hasPrefix(lower)
            let rhsStarts = rhsName.hasPrefix(lower)
            if lhsStarts != rhsStarts { return lhsStarts }
            let lhsWord = lhsName.split(separator: " ").contains(where: { $0.hasPrefix(lower) })
            let rhsWord = rhsName.split(separator: " ").contains(where: { $0.hasPrefix(lower) })
            if lhsWord != rhsWord { return lhsWord }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(AppConfig.offUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.networkError(URLError(.badServerResponse))
            }
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 404 { throw ClientError.notFound }
                throw ClientError.networkError(URLError(.badServerResponse))
            }
            return data
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.networkError(error)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
               let detail = apiError.detail {
                throw ClientError.apiError(detail)
            }
            throw ClientError.decodingError
        }
    }

    private struct APIErrorResponse: Decodable {
        let detail: String?
    }
}
