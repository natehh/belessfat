import Foundation

enum ServingPortionMapper {
    struct PortionInfo {
        var teaspoonGrams: Double?
        var tablespoonGrams: Double?
        var cupGrams: Double?
        var servingGrams: Double?
        var servingDescription: String?
        var smallServingGrams: Double?
        var mediumServingGrams: Double?
        var largeServingGrams: Double?
    }

    struct PortionInput {
        let amount: Double
        let gramWeight: Double
        let label: String
    }

    static func portions(
        householdText: String?,
        householdGrams: Double?,
        foodPortions: [PortionInput] = []
    ) -> PortionInfo {
        var info = PortionInfo()

        if let text = householdText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           let grams = householdGrams, grams > 0 {
            info.servingDescription = text
            info.servingGrams = grams
            applyUnitLabel(text, grams: grams, to: &info)
        }

        for portion in foodPortions where portion.gramWeight > 0 {
            let amount = portion.amount > 0 ? portion.amount : 1
            applyUnitLabel(portion.label, grams: portion.gramWeight / amount, to: &info)
        }

        if info.tablespoonGrams == nil, info.teaspoonGrams == nil, info.cupGrams == nil {
            let weights = foodPortions.map(\.gramWeight).filter { $0 > 0 }
            applyWeightHeuristics(weights, to: &info)
            applyProducePortions(weights, to: &info)
        }

        if info.servingGrams == nil {
            info.servingGrams = info.tablespoonGrams ?? info.teaspoonGrams ?? info.cupGrams
        }

        return info
    }

    private static func applyUnitLabel(_ text: String, grams: Double, to info: inout PortionInfo) {
        let lower = text.lowercased()
        if matchesTablespoon(lower) {
            info.tablespoonGrams = info.tablespoonGrams ?? grams
        } else if matchesTeaspoon(lower) {
            info.teaspoonGrams = info.teaspoonGrams ?? grams
        } else if lower.contains("cup") {
            info.cupGrams = info.cupGrams ?? grams
        }
    }

    private static func applyWeightHeuristics(_ weights: [Double], to info: inout PortionInfo) {
        let unique = Array(Set(weights.filter { $0 > 0 }))
        if info.teaspoonGrams == nil {
            info.teaspoonGrams = closestWeight(in: unique, ideal: 7, range: 4...11)
        }
        if info.tablespoonGrams == nil {
            let remaining = unique.filter { $0 != info.teaspoonGrams }
            info.tablespoonGrams = closestWeight(in: remaining, ideal: 21, range: 12...28)
        }
        if info.cupGrams == nil {
            let hasSpoonMeasures = info.teaspoonGrams != nil || info.tablespoonGrams != nil
            if hasSpoonMeasures {
                info.cupGrams = unique.filter { $0 >= 200 }.max()
            }
        }
    }

    private static func applyProducePortions(_ weights: [Double], to info: inout PortionInfo) {
        guard info.teaspoonGrams == nil, info.tablespoonGrams == nil, info.cupGrams == nil else { return }
        let sorted = Array(Set(weights.filter { (30...500).contains($0) })).sorted()
        guard !sorted.isEmpty else { return }

        switch sorted.count {
        case 1:
            info.servingGrams = info.servingGrams ?? sorted[0]
        case 2:
            info.smallServingGrams = sorted[0]
            info.largeServingGrams = sorted[1]
            info.mediumServingGrams = sorted[1]
            info.servingGrams = info.servingGrams ?? sorted[1]
        default:
            info.smallServingGrams = sorted.first
            info.mediumServingGrams = sorted[sorted.count / 2]
            info.largeServingGrams = sorted.last
            info.servingGrams = info.servingGrams ?? sorted[sorted.count / 2]
        }
    }

    private static func closestWeight(in weights: [Double], ideal: Double, range: ClosedRange<Double>) -> Double? {
        let candidates = weights.filter { range.contains($0) }
        return candidates.min(by: { abs($0 - ideal) < abs($1 - ideal) })
    }

    private static func matchesTablespoon(_ lower: String) -> Bool {
        lower.contains("tbsp") || lower.contains("tablespoon") || lower.contains("tbs")
    }

    private static func matchesTeaspoon(_ lower: String) -> Bool {
        lower.contains("tsp") || lower.contains("teaspoon")
    }
}

enum ServingConverter {
    static let gramsPerOunce = 28.3495
    static let preferredWeightUnitStorageKey = "preferredWeightUnit"

    /// User's preferred weight unit for AI photo estimates. Defaults to ounces.
    static var preferredWeightUnit: ServingUnitType {
        let raw = UserDefaults.standard.string(forKey: preferredWeightUnitStorageKey)
        return raw == ServingUnitType.grams.rawValue ? .grams : .ounces
    }

    static func convertWeight(_ quantity: Double, from: ServingUnitType, to: ServingUnitType) -> Double {
        guard from != to else { return quantity }
        let grams: Double
        switch from {
        case .grams: grams = quantity
        case .ounces: grams = quantity * gramsPerOunce
        default: return quantity
        }
        switch to {
        case .grams:
            return max(grams.rounded(), 1)
        case .ounces:
            let oz = grams / gramsPerOunce
            let quarter = (oz * 4).rounded() / 4
            if quarter >= 0.25 { return quarter }
            return max((oz * 100).rounded() / 100, 0.01)
        default:
            return quantity
        }
    }

    static func applyPreferredWeightUnit(to ingredients: inout [RecipeImportIngredient]) {
        let preferred = preferredWeightUnit
        guard preferred == .grams || preferred == .ounces else { return }
        for index in ingredients.indices {
            let unit = ingredients[index].servingUnit
            guard unit == .grams || unit == .ounces, unit != preferred else { continue }
            ingredients[index].quantity = convertWeight(
                ingredients[index].quantity,
                from: unit,
                to: preferred
            )
            ingredients[index].servingUnit = preferred
        }
    }

    static func resolvedGrams(amount: Double?, unit: ServingUnitType, gramWeight: Double?) -> Double {
        if let gramWeight, gramWeight > 0 { return gramWeight }
        guard let amount, amount > 0 else { return 0 }
        switch unit {
        case .grams: return amount
        case .ounces: return amount * gramsPerOunce
        case .teaspoon, .tablespoon, .cup, .serving, .small, .medium, .large:
            return 0
        }
    }

    static func gramsAmount(quantity: Double, unit: ServingUnitType, food: Food) -> Double {
        switch unit {
        case .grams:
            return quantity
        case .ounces:
            return quantity * gramsPerOunce
        case .teaspoon:
            return quantity * (food.teaspoonGrams ?? food.servingSizeGrams)
        case .tablespoon:
            return quantity * (food.tablespoonGrams ?? food.servingSizeGrams)
        case .cup:
            return quantity * (food.cupGrams ?? food.servingSizeGrams)
        case .serving:
            return quantity * food.servingSizeGrams
        case .small:
            return quantity * (food.smallServingGrams ?? food.servingSizeGrams)
        case .medium:
            return quantity * (food.mediumServingGrams ?? food.servingSizeGrams)
        case .large:
            return quantity * (food.largeServingGrams ?? food.servingSizeGrams)
        }
    }

    static func quantityRange(for unit: ServingUnitType) -> ClosedRange<Double> {
        // Lower bound is for typed values; steppers still use quantityStep (often 0.25).
        switch unit {
        case .grams: return 1...10_000
        case .ounces: return 0.01...500
        case .teaspoon, .tablespoon: return 0.01...50
        case .cup: return 0.01...20
        case .serving, .small, .medium, .large: return 0.01...100
        }
    }

    static func quantityStep(for unit: ServingUnitType) -> Double {
        switch unit {
        case .grams: return 1
        default: return 0.25
        }
    }

    static func servingLabel(for unit: ServingUnitType, food: Food) -> String {
        switch unit {
        case .grams: return "grams"
        case .ounces: return "ounces"
        case .teaspoon:
            if let grams = food.teaspoonGrams {
                return "tsp (\(Int(grams))g)"
            }
            return "tsp"
        case .tablespoon:
            if let grams = food.tablespoonGrams {
                return "tbsp (\(Int(grams))g)"
            }
            return "tbsp"
        case .cup:
            if let grams = food.cupGrams {
                return "cup (\(Int(grams))g)"
            }
            return "cup"
        case .serving:
            if let desc = food.servingDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                return "serving (\(desc))"
            }
            if food.servingSizeGrams > 0 {
                return "serving (\(Int(food.servingSizeGrams))g)"
            }
            return "serving"
        case .small: return "small (\(Int(food.smallServingGrams ?? 0))g)"
        case .medium: return "medium (\(Int(food.mediumServingGrams ?? 0))g)"
        case .large: return "large (\(Int(food.largeServingGrams ?? 0))g)"
        }
    }

    static func compactAmountLabel(quantity: Double, unit: ServingUnitType, food: Food) -> String {
        let qty: String
        if unit == .grams || abs(quantity - quantity.rounded()) < 0.001 {
            qty = String(Int(quantity.rounded()))
        } else {
            qty = String(format: "%g", quantity)
        }
        if unit == .serving,
           let desc = food.servingDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            return abs(quantity - 1) < 0.001 ? desc : "\(qty) \(desc)"
        }
        return "\(qty) \(unit.displayName)"
    }
}

enum MacroCalculator {
    static func progress(current: Double, target: Double) -> Double {
        guard target > 0 else { return 0 }
        return min(max(current / target, 0), 1.5)
    }

    static func remaining(current: Double, target: Double) -> Double {
        target - current
    }

    static func percentComplete(current: Double, target: Double) -> Double {
        guard target > 0 else { return 0 }
        return min(max((current / target) * 100, 0), 999)
    }

    static func weightProgressPercent(current: Double, start: Double, goal: Double) -> Double {
        let totalChange = start - goal
        guard abs(totalChange) > 0.01 else { return 100 }
        let currentChange = start - current
        let progress = currentChange / totalChange
        return min(max(progress * 100, 0), 100)
    }

    static func weeklyWeightChange(entries: [WeightEntry]) -> Double? {
        guard entries.count >= 2 else { return nil }
        let sorted = entries.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
        guard days > 0 else { return nil }
        let change = last.weightLbs - first.weightLbs
        return (change / Double(days)) * 7
    }

    static func weeklyPercentBodyWeightChange(entries: [WeightEntry]) -> Double? {
        guard entries.count >= 2 else { return nil }
        let sorted = entries.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
        guard days > 0, first.weightLbs > 0 else { return nil }
        let weeklyChange = ((last.weightLbs - first.weightLbs) / Double(days)) * 7
        return (weeklyChange / first.weightLbs) * 100
    }

    /// Average lbs/week from goal start weight/date to the current weight as of `asOf`.
    static func averageWeeklyWeightChange(
        startWeight: Double,
        currentWeight: Double,
        startDate: Date,
        asOf date: Date
    ) -> Double? {
        let startDay = DateHelpers.startOfDay(startDate)
        let endDay = DateHelpers.startOfDay(date)
        let days = Calendar.current.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        guard days > 0 else { return nil }
        return ((currentWeight - startWeight) / Double(days)) * 7
    }

    static func averageWeeklyPercentBodyWeightChange(
        startWeight: Double,
        currentWeight: Double,
        startDate: Date,
        asOf date: Date
    ) -> Double? {
        guard startWeight > 0 else { return nil }
        guard let weekly = averageWeeklyWeightChange(
            startWeight: startWeight,
            currentWeight: currentWeight,
            startDate: startDate,
            asOf: date
        ) else { return nil }
        return (weekly / startWeight) * 100
    }

    static func movingAverage(entries: [WeightEntry], window: Int = 7) -> [(date: Date, value: Double)] {
        let sorted = entries.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }
        return sorted.enumerated().map { index, entry in
            let start = max(0, index - window + 1)
            let slice = sorted[start...index]
            let avg = slice.map(\.weightLbs).reduce(0, +) / Double(slice.count)
            return (entry.date, avg)
        }
    }

    static func projectedFinishDate(current: Double, goal: Double, weeklyRate: Double) -> Date? {
        guard abs(weeklyRate) > 0.01 else { return nil }
        let remaining = goal - current
        let weeksNeeded = remaining / weeklyRate
        let days = Int(ceil(abs(weeksNeeded) * 7))
        return Calendar.current.date(byAdding: .day, value: days, to: Date())
    }

    static func macroCaloriePercents(protein: Double, carbs: Double, fat: Double) -> (protein: Double, carbs: Double, fat: Double) {
        let proteinCal = protein * 4
        let carbsCal = carbs * 4
        let fatCal = fat * 9
        let total = proteinCal + carbsCal + fatCal
        guard total > 0 else { return (0, 0, 0) }
        return (
            protein: proteinCal / total * 100,
            carbs: carbsCal / total * 100,
            fat: fatCal / total * 100
        )
    }
}

enum DateHelpers {
    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    static func startOfNextDay(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? startOfDay(date)
    }

    static func isSameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    static func weekStart(containing date: Date, weekStartsOn: WeekStartDay = .monday) -> Date {
        let calendar = Calendar.current
        let day = startOfDay(date)
        let weekday = calendar.component(.weekday, from: day)
        let target = weekStartsOn.rawValue
        var delta = weekday - target
        if delta < 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: -delta, to: day) ?? day
    }

    static func weekEnd(containing date: Date, weekStartsOn: WeekStartDay = .monday) -> Date {
        let start = weekStart(containing: date, weekStartsOn: weekStartsOn)
        return Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
    }

    static func timeProgressPercent(from start: Date, to end: Date, now: Date = Date()) -> Double {
        let startDay = startOfDay(start)
        let endDay = startOfDay(end)
        let nowDay = startOfDay(now)
        let total = Calendar.current.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        guard total > 0 else { return 100 }
        let elapsed = Calendar.current.dateComponents([.day], from: startDay, to: nowDay).day ?? 0
        return min(max((Double(elapsed) / Double(total)) * 100, 0), 100)
    }

    static func daysBetween(_ start: Date, _ end: Date) -> [Date] {
        var dates: [Date] = []
        var current = startOfDay(start)
        let endDay = startOfDay(end)
        while current <= endDay {
            dates.append(current)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return dates
    }
}
