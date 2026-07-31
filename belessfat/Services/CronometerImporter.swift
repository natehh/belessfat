import Foundation
import SwiftData

@MainActor
enum CronometerImporter {
    static let externalIdPrefix = "cronometer-daily:"
    private static let poundsPerKilogram = 2.2046226218

    enum FileKind {
        case dailySummary
        case biometrics
    }

    struct DailySummaryRow: Identifiable {
        var id: Date { date }
        var date: Date
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var completed: Bool?
    }

    struct BiometricsRow: Identifiable {
        var id: Date { date }
        var date: Date
        var weightLbs: Double
    }

    struct ImportOptions {
        var skipDaysWithExistingEntries = true
        var replacePreviousCronometerImports = true
    }

    struct BiometricsImportOptions {
        var skipDaysWithExistingWeight = true
    }

    struct ImportResult {
        var imported: Int
        var skippedExisting: Int
        var skippedEmpty: Int
        var replaced: Int
        var dateRange: ClosedRange<Date>?
    }

    struct BiometricsImportResult {
        var imported: Int
        var skippedExisting: Int
        var dateRange: ClosedRange<Date>?
    }

    struct DailySummaryPreview {
        var rows: [DailySummaryRow]
        var dateRange: ClosedRange<Date>?
    }

    struct BiometricsPreview {
        var rows: [BiometricsRow]
        var dateRange: ClosedRange<Date>?
    }

    enum ImportPreview {
        case dailySummary(DailySummaryPreview)
        case biometrics(BiometricsPreview)

        var fileKind: FileKind {
            switch self {
            case .dailySummary: return .dailySummary
            case .biometrics: return .biometrics
            }
        }
    }

    struct ParsePreview {
        var rows: [DailySummaryRow]
        var dateRange: ClosedRange<Date>?
    }

    enum ImportError: LocalizedError {
        case emptyFile
        case missingColumns([String])
        case invalidDate(String)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .emptyFile:
                return "CSV file is empty or has no data rows."
            case .missingColumns(let columns):
                return "Missing required columns: \(columns.joined(separator: ", "))."
            case .invalidDate(let value):
                return "Could not parse date: \(value)."
            case .unsupportedFormat:
                return "This file doesn't look like a Cronometer Daily Summary or Biometrics export."
            }
        }
    }

    static func preview(from csv: String) throws -> ImportPreview {
        let lines = csv.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else { throw ImportError.emptyFile }
        let headers = parseCSVLine(lines[0])

        switch detectFileKind(headers: headers) {
        case .dailySummary:
            let rows = try parseDailySummary(from: csv)
            return .dailySummary(DailySummaryPreview(rows: rows, dateRange: dateRange(for: rows.map(\.date))))
        case .biometrics:
            let rows = try parseBiometrics(from: csv)
            return .biometrics(BiometricsPreview(rows: rows, dateRange: dateRange(for: rows.map(\.date))))
        case nil:
            throw ImportError.unsupportedFormat
        }
    }

    static func previewDailySummary(from csv: String) throws -> ParsePreview {
        let rows = try parseDailySummary(from: csv)
        let sorted = rows.map(\.date).sorted()
        let range = sorted.first.flatMap { first in
            sorted.last.map { last in first...last }
        }
        return ParsePreview(rows: rows, dateRange: range)
    }

    static func parseDailySummary(from csv: String) throws -> [DailySummaryRow] {
        let lines = csv.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else { throw ImportError.emptyFile }

        let headers = parseCSVLine(lines[0])
        let dateIndex = columnIndex(headers, candidates: ["date"])
        let caloriesIndex = columnIndex(headers, candidates: ["energy (kcal)", "energy"])
        let proteinIndex = columnIndex(headers, candidates: ["protein (g)", "protein"])
        let carbsIndex = columnIndex(headers, candidates: ["carbs (g)", "carbs"])
        let fatIndex = columnIndex(headers, candidates: ["fat (g)", "fat"])
        let completedIndex = columnIndex(headers, candidates: ["completed"])

        var missing: [String] = []
        if dateIndex == nil { missing.append("Date") }
        if caloriesIndex == nil { missing.append("Energy (kcal)") }
        if proteinIndex == nil { missing.append("Protein (g)") }
        if carbsIndex == nil { missing.append("Carbs (g)") }
        if fatIndex == nil { missing.append("Fat (g)") }
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }

        var rows: [DailySummaryRow] = []
        for line in lines.dropFirst() {
            let values = parseCSVLine(line)
            guard let dateIndex, dateIndex < values.count else { continue }
            let dateText = values[dateIndex].trimmingCharacters(in: .whitespaces)
            guard !dateText.isEmpty else { continue }
            guard let date = parseDay(dateText) else { throw ImportError.invalidDate(dateText) }

            let calories = parseDouble(values, at: caloriesIndex) ?? 0
            guard calories > 0 else { continue }

            rows.append(DailySummaryRow(
                date: date,
                calories: calories,
                protein: parseDouble(values, at: proteinIndex) ?? 0,
                carbs: parseDouble(values, at: carbsIndex) ?? 0,
                fat: parseDouble(values, at: fatIndex) ?? 0,
                completed: parseBool(values, at: completedIndex)
            ))
        }
        return rows.sorted { $0.date < $1.date }
    }

    static func parseBiometrics(from csv: String) throws -> [BiometricsRow] {
        let lines = csv.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else { throw ImportError.emptyFile }

        let headers = parseCSVLine(lines[0])
        let dayIndex = columnIndex(headers, candidates: ["day", "date"])
        let metricIndex = columnIndex(headers, candidates: ["metric"])
        let unitIndex = columnIndex(headers, candidates: ["unit"])
        let amountIndex = columnIndex(headers, candidates: ["amount"])

        var missing: [String] = []
        if dayIndex == nil { missing.append("Day") }
        if metricIndex == nil { missing.append("Metric") }
        if unitIndex == nil { missing.append("Unit") }
        if amountIndex == nil { missing.append("Amount") }
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }

        var byDay: [Date: Double] = [:]
        for line in lines.dropFirst() {
            let values = parseCSVLine(line)
            guard let dayIndex, dayIndex < values.count else { continue }

            let metric = values[safe: metricIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard metric.compare("weight", options: .caseInsensitive) == .orderedSame else { continue }

            let dateText = values[dayIndex].trimmingCharacters(in: .whitespaces)
            guard !dateText.isEmpty else { continue }
            guard let date = parseDay(dateText) else { throw ImportError.invalidDate(dateText) }

            guard let amount = parseDouble(values, at: amountIndex), amount > 0 else { continue }
            let unit = values[safe: unitIndex]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "lbs"
            byDay[date] = weightInPounds(amount: amount, unit: unit)
        }

        return byDay.keys.sorted().map { date in
            BiometricsRow(date: date, weightLbs: byDay[date]!)
        }
    }

    static func importBiometrics(
        _ rows: [BiometricsRow],
        options: BiometricsImportOptions,
        context: ModelContext
    ) throws -> BiometricsImportResult {
        var imported = 0
        var skippedExisting = 0

        for row in rows {
            if options.skipDaysWithExistingWeight, GoalService.weightEntry(for: row.date, context: context) != nil {
                skippedExisting += 1
                continue
            }
            GoalService.saveWeight(row.weightLbs, for: row.date, context: context)
            imported += 1
        }

        return BiometricsImportResult(
            imported: imported,
            skippedExisting: skippedExisting,
            dateRange: dateRange(for: rows.map(\.date))
        )
    }

    static func importDailySummary(
        _ rows: [DailySummaryRow],
        options: ImportOptions,
        context: ModelContext
    ) throws -> ImportResult {
        var imported = 0
        var skippedExisting = 0
        var skippedEmpty = 0
        var replaced = 0

        for row in rows {
            guard row.calories > 0 else {
                skippedEmpty += 1
                continue
            }

            if options.skipDaysWithExistingEntries && hasNonCronometerEntries(for: row.date, context: context) {
                skippedExisting += 1
                continue
            }

            if options.replacePreviousCronometerImports {
                let removed = removeCronometerImports(for: row.date, context: context)
                if removed > 0 { replaced += removed }
            }

            let food = makeImportFood(for: row)
            context.insert(food)
            let entry = LogEntry(
                date: row.date,
                mealCategory: .uncategorized,
                quantity: 1,
                servingUnit: .serving,
                food: food
            )
            context.insert(entry)
            imported += 1
        }

        try context.save()

        return ImportResult(
            imported: imported,
            skippedExisting: skippedExisting,
            skippedEmpty: skippedEmpty,
            replaced: replaced,
            dateRange: dateRange(for: rows.map(\.date))
        )
    }

    private static func detectFileKind(headers: [String]) -> FileKind? {
        let normalized = Set(headers.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        if normalized.contains("energy (kcal)") {
            return .dailySummary
        }
        if normalized.contains("metric"), normalized.contains("amount"),
           normalized.contains("day") || normalized.contains("date") {
            return .biometrics
        }
        return nil
    }

    private static func dateRange(for dates: [Date]) -> ClosedRange<Date>? {
        let sorted = dates.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        return first...last
    }

    private static func weightInPounds(amount: Double, unit: String) -> Double {
        switch unit {
        case "kg", "kilogram", "kilograms":
            return amount * poundsPerKilogram
        default:
            return amount
        }
    }

    private static func makeImportFood(for row: DailySummaryRow) -> Food {
        let dayKey = isoDayFormatter.string(from: row.date)
        let label = row.date.formatted(date: .abbreviated, time: .omitted)
        return Food(
            name: "Cronometer — \(label)",
            brand: "Imported",
            source: .custom,
            externalId: "\(externalIdPrefix)\(dayKey)",
            servingSizeGrams: 1,
            servingDescription: "daily total",
            caloriesPerServing: row.calories,
            proteinPerServing: row.protein,
            carbsPerServing: row.carbs,
            fatPerServing: row.fat
        )
    }

    private static func hasNonCronometerEntries(for date: Date, context: ModelContext) -> Bool {
        DiaryService.entries(for: date, context: context).contains {
            $0.food?.externalId?.hasPrefix(externalIdPrefix) != true
        }
    }

    @discardableResult
    private static func removeCronometerImports(for date: Date, context: ModelContext) -> Int {
        let dayEntries = DiaryService.entries(for: date, context: context)
        var removed = 0
        for entry in dayEntries {
            guard entry.food?.externalId?.hasPrefix(externalIdPrefix) == true else { continue }
            let food = entry.food
            context.delete(entry)
            if let food {
                context.delete(food)
            }
            removed += 1
        }
        return removed
    }

    private static func columnIndex(_ headers: [String], candidates: [String]) -> Int? {
        let normalized = headers.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        for candidate in candidates {
            let key = candidate.lowercased()
            if let exact = normalized.firstIndex(of: key) {
                return exact
            }
            if let partial = normalized.firstIndex(where: { $0.contains(key) }) {
                return partial
            }
        }
        return nil
    }

    private static func parseDouble(_ values: [String], at index: Int?) -> Double? {
        guard let index, index < values.count else { return nil }
        let trimmed = values[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private static func parseBool(_ values: [String], at index: Int?) -> Bool? {
        guard let index, index < values.count else { return nil }
        switch values[index].trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func parseDay(_ text: String) -> Date? {
        if let date = isoDayFormatter.date(from: text) {
            return DateHelpers.startOfDay(date)
        }
        return nil
    }

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
}

private extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}
