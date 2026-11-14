import Foundation
import SwiftData

@MainActor
enum DiaryService {
    static func entries(for date: Date, context: ModelContext) -> [LogEntry] {
        let start = DateHelpers.startOfDay(date)
        let end = DateHelpers.startOfNextDay(date)
        let descriptor = FetchDescriptor<LogEntry>(
            predicate: #Predicate { entry in
                entry.date >= start && entry.date < end
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            print("[Diary] fetch entries failed: \(error)")
            return []
        }
    }

    static func totals(for date: Date, context: ModelContext) -> MacroTotals {
        entries(for: date, context: context).reduce(.zero) { $0 + $1.macros }
    }

    static func weekTotals(containing date: Date, weekStartsOn: WeekStartDay = .monday, context: ModelContext) -> MacroTotals {
        let weekStart = DateHelpers.weekStart(containing: date, weekStartsOn: weekStartsOn)
        let weekEndExclusive = DateHelpers.startOfNextDay(DateHelpers.weekEnd(containing: date, weekStartsOn: weekStartsOn))
        let descriptor = FetchDescriptor<LogEntry>(
            predicate: #Predicate { entry in
                entry.date >= weekStart && entry.date < weekEndExclusive
            }
        )
        do {
            return try context.fetch(descriptor).reduce(.zero) { $0 + $1.macros }
        } catch {
            print("[Diary] fetch week totals failed: \(error)")
            return .zero
        }
    }

    static func addEntry(
        food: Food,
        quantity: Double,
        unit: ServingUnitType,
        meal: MealCategory,
        date: Date,
        context: ModelContext
    ) {
        let entry = LogEntry(date: date, mealCategory: meal, quantity: quantity, servingUnit: unit, food: food)
        context.insert(entry)
        try? context.save()
    }

    static func addEntry(
        recipe: Recipe,
        quantity: Double,
        unit: ServingUnitType = .serving,
        meal: MealCategory,
        date: Date,
        context: ModelContext,
        adjustableOverrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    ) {
        let entry = LogEntry(date: date, mealCategory: meal, quantity: quantity, servingUnit: unit, recipe: recipe)
        applyRecipeOverrides(adjustableOverrides, to: entry, recipe: recipe, quantity: quantity, unit: unit)
        context.insert(entry)
        try? context.save()
    }

    static func updateRecipeEntry(
        _ entry: LogEntry,
        recipe: Recipe,
        quantity: Double,
        unit: ServingUnitType,
        meal: MealCategory,
        adjustableOverrides: [UUID: (quantity: Double, unit: ServingUnitType)],
        context: ModelContext
    ) {
        entry.quantity = quantity
        entry.servingUnit = unit
        entry.mealCategory = meal
        applyRecipeOverrides(adjustableOverrides, to: entry, recipe: recipe, quantity: quantity, unit: unit)
        try? context.save()
    }

    private static func applyRecipeOverrides(
        _ overrides: [UUID: (quantity: Double, unit: ServingUnitType)],
        to entry: LogEntry,
        recipe: Recipe,
        quantity: Double,
        unit: ServingUnitType
    ) {
        entry.recipeOverrideMap = overrides
        if shouldSnapshotRecipeLog(recipe: recipe, overrides: overrides) {
            let totals = recipe.macros(for: quantity, unit: unit, overrides: overrides)
            let divisor = max(quantity, 0.01)
            entry.applyRecipeSnapshot(
                name: recipe.name,
                macrosPerQuantity: MacroTotals(
                    calories: totals.calories / divisor,
                    protein: totals.protein / divisor,
                    carbs: totals.carbs / divisor,
                    fat: totals.fat / divisor
                )
            )
        } else {
            entry.clearRecipeSnapshot()
        }
    }

    /// Snapshot when any adjustable ingredient differs from the recipe default.
    private static func shouldSnapshotRecipeLog(
        recipe: Recipe,
        overrides: [UUID: (quantity: Double, unit: ServingUnitType)]
    ) -> Bool {
        guard !overrides.isEmpty else { return false }
        for ingredient in recipe.adjustableIngredients {
            guard let override = overrides[ingredient.id] else { continue }
            if abs(override.quantity - ingredient.quantity) > 0.000_001
                || override.unit != ingredient.servingUnit {
                return true
            }
        }
        return false
    }

    static func delete(_ entry: LogEntry, context: ModelContext) {
        context.delete(entry)
        try? context.save()
    }

    static func duplicate(_ entry: LogEntry, context: ModelContext) {
        let copy = makeCopy(of: entry, date: entry.date, meal: entry.mealCategory)
        context.insert(copy)
        try? context.save()
    }

    static func copyEntry(_ entry: LogEntry, to targetDate: Date, context: ModelContext) {
        let copy = makeCopy(of: entry, date: targetDate, meal: entry.mealCategory)
        context.insert(copy)
        try? context.save()
    }

    static func copyMeal(from sourceDate: Date, meal: MealCategory, to targetDate: Date, context: ModelContext) {
        let sourceEntries = entries(for: sourceDate, context: context).filter { $0.mealCategory == meal }
        guard !sourceEntries.isEmpty else { return }
        let targetDay = DateHelpers.startOfDay(targetDate)
        for entry in sourceEntries {
            context.insert(makeCopy(of: entry, date: targetDay, meal: meal))
        }
        try? context.save()
    }

    static func move(_ entry: LogEntry, to meal: MealCategory, context: ModelContext) {
        entry.mealCategory = meal
        try? context.save()
    }

    static func copyDay(from sourceDate: Date, to targetDate: Date, context: ModelContext) {
        let sourceEntries = entries(for: sourceDate, context: context)
        let targetDay = DateHelpers.startOfDay(targetDate)
        for entry in sourceEntries {
            context.insert(makeCopy(of: entry, date: targetDay, meal: entry.mealCategory))
        }
        try? context.save()
    }

    private static func makeCopy(of entry: LogEntry, date: Date, meal: MealCategory) -> LogEntry {
        let copy = LogEntry(
            date: date,
            mealCategory: meal,
            quantity: entry.quantity,
            servingUnit: entry.servingUnit,
            food: entry.food,
            recipe: entry.recipe
        )
        copy.snapshotName = entry.snapshotName
        copy.snapshotCaloriesPerQuantity = entry.snapshotCaloriesPerQuantity
        copy.snapshotProteinPerQuantity = entry.snapshotProteinPerQuantity
        copy.snapshotCarbsPerQuantity = entry.snapshotCarbsPerQuantity
        copy.snapshotFatPerQuantity = entry.snapshotFatPerQuantity
        copy.recipeIngredientOverridesJSON = entry.recipeIngredientOverridesJSON
        return copy
    }

    enum RecentItem: Identifiable {
        case food(Food)
        case recipe(Recipe)

        var id: UUID {
            switch self {
            case .food(let food): return food.id
            case .recipe(let recipe): return recipe.id
            }
        }

        var name: String {
            switch self {
            case .food(let food): return food.displayName
            case .recipe(let recipe): return recipe.name
            }
        }

        var brand: String? {
            switch self {
            case .food(let food): return food.brand
            case .recipe: return nil
            }
        }

        init?(entry: LogEntry, includeRecipes: Bool) {
            if includeRecipes, let recipe = entry.recipe {
                self = .recipe(recipe)
            } else if let food = entry.food {
                self = .food(food)
            } else {
                return nil
            }
        }
    }

    static func frequentItems(
        context: ModelContext,
        limit: Int = 20,
        includeRecipes: Bool = true
    ) -> [(item: RecentItem, count: Int)] {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let descriptor = FetchDescriptor<LogEntry>(
            predicate: #Predicate { $0.date >= thirtyDaysAgo }
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        var counts: [UUID: (RecentItem, Int)] = [:]
        for entry in entries {
            guard let item = RecentItem(entry: entry, includeRecipes: includeRecipes) else { continue }
            let current = counts[item.id]?.1 ?? 0
            counts[item.id] = (item, current + 1)
        }
        return counts.values
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    static func recentItems(
        context: ModelContext,
        limit: Int = 20,
        includeRecipes: Bool = true
    ) -> [RecentItem] {
        let descriptor = FetchDescriptor<LogEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        var seen = Set<UUID>()
        var items: [RecentItem] = []
        for entry in entries {
            guard let item = RecentItem(entry: entry, includeRecipes: includeRecipes),
                  !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            items.append(item)
            if items.count >= limit { break }
        }
        return items
    }

    struct LoggedAmount {
        var quantity: Double
        var unit: ServingUnitType
        var recipeOverrides: [UUID: (quantity: Double, unit: ServingUnitType)] = [:]
    }

    static func lastLoggedAmounts(context: ModelContext) -> [UUID: LoggedAmount] {
        let descriptor = FetchDescriptor<LogEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        var result: [UUID: LoggedAmount] = [:]
        for entry in entries {
            let id: UUID?
            let overrides: [UUID: (quantity: Double, unit: ServingUnitType)]
            if let recipe = entry.recipe {
                id = recipe.id
                overrides = entry.recipeOverrideMap
            } else if let food = entry.food {
                id = food.id
                overrides = [:]
            } else {
                id = nil
                overrides = [:]
            }
            guard let id, result[id] == nil else { continue }
            result[id] = LoggedAmount(
                quantity: entry.quantity,
                unit: entry.servingUnit,
                recipeOverrides: overrides
            )
        }
        return result
    }

    static func loggingAmount(for food: Food, lastLogged: [UUID: LoggedAmount]? = nil, context: ModelContext? = nil) -> LoggedAmount {
        let amounts = lastLogged ?? context.map { lastLoggedAmounts(context: $0) } ?? [:]
        if let last = amounts[food.id], food.availableServingUnits.contains(last.unit) {
            return last
        }
        let fallback = food.defaultLoggingAmount()
        return LoggedAmount(quantity: fallback.quantity, unit: fallback.unit)
    }

    static func loggingAmount(for recipe: Recipe, lastLogged: [UUID: LoggedAmount]? = nil, context: ModelContext? = nil) -> LoggedAmount {
        let amounts = lastLogged ?? context.map { lastLoggedAmounts(context: $0) } ?? [:]
        let units = recipe.availableServingUnits()
        if let last = amounts[recipe.id], units.contains(last.unit) {
            return last
        }
        return LoggedAmount(quantity: 1, unit: .serving)
    }

    static func mostRecentMeal(context: ModelContext) -> MealCategory {
        var descriptor = FetchDescriptor<LogEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let entry = (try? context.fetch(descriptor))?.first {
            return entry.mealCategory
        }
        return .breakfast
    }

    static func applyTemplate(_ template: MealTemplate, to date: Date, context: ModelContext) {
        let day = DateHelpers.startOfDay(date)
        for item in template.items {
            let entry = LogEntry(
                date: day,
                mealCategory: item.mealCategory,
                quantity: item.quantity,
                servingUnit: item.servingUnit,
                food: item.food,
                recipe: item.recipe
            )
            context.insert(entry)
        }
        try? context.save()
    }

    static func applyFavorite(_ favorite: FavoriteMeal, to date: Date, context: ModelContext) {
        let day = DateHelpers.startOfDay(date)
        for item in favorite.items {
            let entry = LogEntry(
                date: day,
                mealCategory: item.mealCategory,
                quantity: item.quantity,
                servingUnit: item.servingUnit,
                food: item.food,
                recipe: item.recipe
            )
            context.insert(entry)
        }
        try? context.save()
    }

    static func saveTemplate(name: String, from entries: [LogEntry], context: ModelContext) {
        let template = MealTemplate(name: name)
        for entry in entries {
            let item = MealTemplateItem(from: entry)
            item.template = template
            template.items.append(item)
            context.insert(item)
        }
        context.insert(template)
        try? context.save()
    }

    static func saveFavorite(name: String, from entries: [LogEntry], context: ModelContext) {
        let favorite = FavoriteMeal(name: name)
        for entry in entries {
            let item = FavoriteMealItem(from: entry)
            item.favorite = favorite
            favorite.items.append(item)
            context.insert(item)
        }
        context.insert(favorite)
        try? context.save()
    }
}

struct DiaryClipboardItem {
    var food: Food?
    var recipe: Recipe?
    var quantity: Double
    var servingUnit: ServingUnitType
    var snapshotName: String?
    var snapshotCaloriesPerQuantity: Double
    var snapshotProteinPerQuantity: Double
    var snapshotCarbsPerQuantity: Double
    var snapshotFatPerQuantity: Double
    var recipeIngredientOverridesJSON: String?

    init(_ entry: LogEntry) {
        food = entry.food
        recipe = entry.recipe
        quantity = entry.quantity
        servingUnit = entry.servingUnit
        snapshotName = entry.snapshotName
        snapshotCaloriesPerQuantity = entry.snapshotCaloriesPerQuantity
        snapshotProteinPerQuantity = entry.snapshotProteinPerQuantity
        snapshotCarbsPerQuantity = entry.snapshotCarbsPerQuantity
        snapshotFatPerQuantity = entry.snapshotFatPerQuantity
        recipeIngredientOverridesJSON = entry.recipeIngredientOverridesJSON
    }

    func makeEntry(date: Date, meal: MealCategory) -> LogEntry {
        let entry = LogEntry(
            date: date,
            mealCategory: meal,
            quantity: quantity,
            servingUnit: servingUnit,
            food: food,
            recipe: recipe
        )
        entry.snapshotName = snapshotName
        entry.snapshotCaloriesPerQuantity = snapshotCaloriesPerQuantity
        entry.snapshotProteinPerQuantity = snapshotProteinPerQuantity
        entry.snapshotCarbsPerQuantity = snapshotCarbsPerQuantity
        entry.snapshotFatPerQuantity = snapshotFatPerQuantity
        entry.recipeIngredientOverridesJSON = recipeIngredientOverridesJSON
        return entry
    }
}

/// Days left out of calorie averages and the weekly calorie budget.
@MainActor
final class CalorieTrackingDays: ObservableObject {
    static let shared = CalorieTrackingDays()

    @Published private(set) var manualExclusions: Set<Date>
    private static let key = "calorieTrackingExcludedDayStarts"

    private init() {
        manualExclusions = Set((UserDefaults.standard.stringArray(forKey: Self.key) ?? []).compactMap(Self.date(from:)))
    }

    func isManuallyExcluded(_ date: Date) -> Bool {
        manualExclusions.contains(DateHelpers.startOfDay(date))
    }

    /// Past days with no food drop out. Today and later days stay until that day ends with no food.
    /// A manual exclusion drops the day even when food is logged.
    func countsTowardBudget(on date: Date, hasFood: Bool, now: Date = Date()) -> Bool {
        if isManuallyExcluded(date) { return false }
        let day = DateHelpers.startOfDay(date)
        let today = DateHelpers.startOfDay(now)
        if day < today && !hasFood { return false }
        return true
    }

    /// Calorie and macro averages only include days with food, minus manual exclusions.
    func countsTowardCalorieAverages(on date: Date, hasFood: Bool) -> Bool {
        if isManuallyExcluded(date) { return false }
        return hasFood
    }

    func setManuallyExcluded(_ excluded: Bool, on date: Date) {
        let day = DateHelpers.startOfDay(date)
        var next = manualExclusions
        if excluded {
            next.insert(day)
        } else {
            next.remove(day)
        }
        manualExclusions = next
        let values = next.map(Self.string(from:)).sorted()
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set(values, forKey: Self.key)
        }
    }

    private static func string(from date: Date) -> String {
        formatter.string(from: DateHelpers.startOfDay(date))
    }

    private static func date(from string: String) -> Date? {
        formatter.date(from: string).map(DateHelpers.startOfDay)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
final class DiaryClipboard: ObservableObject {
    static let shared = DiaryClipboard()

    @Published private(set) var items: [DiaryClipboardItem] = []

    var canPaste: Bool { !items.isEmpty }

    func copy(_ entries: [LogEntry]) {
        let copied = entries.map(DiaryClipboardItem.init)
        guard !copied.isEmpty else { return }
        items = copied
    }

    func paste(into meal: MealCategory, on date: Date, context: ModelContext) {
        guard canPaste else { return }
        for item in items {
            context.insert(item.makeEntry(date: date, meal: meal))
        }
        try? context.save()
    }
}
