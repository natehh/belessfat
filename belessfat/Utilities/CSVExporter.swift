import Foundation

struct ParsedLabelNutrition {
    var name: String
    var servingSize: String
    var servingSizeGrams: Double
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var warnings: [String]
}

@MainActor
enum CSVExporter {
    struct ExportOptions {
        var includeCalories: Bool = true
        var includeProtein: Bool = true
        var includeCarbs: Bool = true
        var includeFat: Bool = true
        var includeWeight: Bool = true
        var includeSteps: Bool = true
        var includeActiveCalories: Bool = true
        var includeNetCalories: Bool = true
        var aggregation: Aggregation = .daily

        enum Aggregation: String, CaseIterable {
            case daily = "Day by Day"
            case weekly = "Weekly Average"
            case monthly = "Monthly Average"
        }
    }

    static func export(
        options: ExportOptions,
        dailyData: [ReportService.DailyReportRow]
    ) -> String {
        var headers = ["Period Start", "Period End"]
        if options.includeCalories { headers.append("Calories") }
        if options.includeProtein { headers.append("Protein (g)") }
        if options.includeCarbs { headers.append("Carbs (g)") }
        if options.includeFat { headers.append("Fat (g)") }
        if options.includeWeight { headers.append("Weight (lbs)") }
        if options.includeSteps { headers.append("Steps") }
        if options.includeActiveCalories { headers.append("Active Calories") }
        if options.includeNetCalories { headers.append("Net Calories") }

        let rows: [[String]]
        switch options.aggregation {
        case .daily:
            rows = dailyData.map { row in
                buildRow(row: row, options: options, start: row.date, end: row.date)
            }
        case .weekly:
            rows = aggregate(dailyData, bucketDays: 7, options: options)
        case .monthly:
            rows = aggregate(dailyData, bucketDays: 30, options: options)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        var csv = headers.joined(separator: ",") + "\n"
        for row in rows {
            csv += row.joined(separator: ",") + "\n"
        }
        return csv
    }

    private static func buildRow(
        row: ReportService.DailyReportRow,
        options: ExportOptions,
        start: Date,
        end: Date
    ) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var values = [formatter.string(from: start), formatter.string(from: end)]
        if options.includeCalories { values.append(format(row.calories)) }
        if options.includeProtein { values.append(format(row.protein)) }
        if options.includeCarbs { values.append(format(row.carbs)) }
        if options.includeFat { values.append(format(row.fat)) }
        if options.includeWeight { values.append(row.weight.map(format) ?? "") }
        if options.includeSteps { values.append("\(row.steps)") }
        if options.includeActiveCalories { values.append(format(row.activeCalories)) }
        if options.includeNetCalories { values.append(format(row.netCalories)) }
        return values
    }

    private static func aggregate(
        _ data: [ReportService.DailyReportRow],
        bucketDays: Int,
        options: ExportOptions
    ) -> [[String]] {
        guard !data.isEmpty else { return [] }
        var buckets: [[ReportService.DailyReportRow]] = []
        var current: [ReportService.DailyReportRow] = []
        for (index, row) in data.enumerated() {
            current.append(row)
            if current.count == bucketDays || index == data.count - 1 {
                buckets.append(current)
                current = []
            }
        }
        return buckets.compactMap { bucket -> [String]? in
            guard let first = bucket.first, let last = bucket.last else { return nil }
            guard let avg = ReportService.averages(rows: bucket) else { return nil }
            return buildRow(row: avg, options: options, start: first.date, end: last.date)
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

enum CSVImporter {
    struct ImportedFood {
        var name: String
        var brand: String?
        var barcode: String?
        var servingSizeGrams: Double
        var servingDescription: String?
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var isAlcohol: Bool
    }

    static func parseFoods(from csv: String) throws -> [ImportedFood] {
        let lines = csv.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else { throw ImportError.emptyFile }
        let headers = parseCSVLine(lines[0]).map { $0.lowercased() }
        var foods: [ImportedFood] = []
        for line in lines.dropFirst() {
            let values = parseCSVLine(line)
            guard values.count >= headers.count else { continue }
            var dict: [String: String] = [:]
            for (i, header) in headers.enumerated() where i < values.count {
                dict[header] = values[i]
            }
            guard let name = dict["name"], !name.isEmpty else { continue }
            foods.append(ImportedFood(
                name: name,
                brand: dict["brand"],
                barcode: dict["barcode"],
                servingSizeGrams: Double(dict["serving_grams"] ?? dict["serving_size_grams"] ?? "100") ?? 100,
                servingDescription: dict["serving_description"],
                calories: Double(dict["calories"] ?? "0") ?? 0,
                protein: Double(dict["protein"] ?? "0") ?? 0,
                carbs: Double(dict["carbs"] ?? "0") ?? 0,
                fat: Double(dict["fat"] ?? "0") ?? 0,
                isAlcohol: (dict["is_alcohol"] ?? "").lowercased() == "true"
            ))
        }
        return foods
    }

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

    enum ImportError: LocalizedError {
        case emptyFile
        var errorDescription: String? {
            switch self {
            case .emptyFile: return "CSV file is empty or has no data rows."
            }
        }
    }
}
