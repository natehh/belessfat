import Foundation
import SwiftData

@MainActor
enum DiaryService {
    static func entries(for date: Date, context: ModelContext) -> [LogEntry] {
        let day = DateHelpers.startOfDay(date)
        let descriptor = FetchDescriptor<LogEntry>(
            predicate: #Predicate { $0.date == day },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func totals(for date: Date, context: ModelContext) -> MacroTotals {
        entries(for: date, context: context).reduce(.zero) { $0 + $1.macros }
    }

    static func weekTotals(containing date: Date, weekStartsOn: WeekStartDay = .monday, context: ModelContext) -> MacroTotals {
        let weekStart = DateHelpers.weekStart(containing: date, weekStartsOn: weekStartsOn)
        let weekEnd = DateHelpers.weekEnd(containing: date, weekStartsOn: weekStartsOn)
        let descriptor = FetchDescriptor<LogEntry>(
            predicate: #Predicate { entry in
                entry.date >= weekStart && entry.date <= weekEnd
            }
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        return entries.reduce(.zero) { $0 + $1.macros }
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
        meal: MealCategory,
        date: Date,
        context: ModelContext
    ) {
        let entry = LogEntry(date: date, mealCategory: meal, quantity: quantity, servingUnit: .serving, recipe: recipe)
        context.insert(entry)
        try? context.save()
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
        return copy
    }

    static func frequentFoods(context: ModelContext, limit: Int = 20) -> [(food: Food, count: Int)] {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let descriptor = FetchDescriptor<LogEntry>(
            predicate: #Predicate { $0.date >= thirtyDaysAgo }
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        var counts: [UUID: (Food, Int)] = [:]
        for entry in entries {
            guard let food = entry.food else { continue }
            let current = counts[food.id]?.1 ?? 0
            counts[food.id] = (food, current + 1)
        }
        return counts.values
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    static func recentFoods(context: ModelContext, limit: Int = 20) -> [Food] {
        let descriptor = FetchDescriptor<LogEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        var seen = Set<UUID>()
        var foods: [Food] = []
        for entry in entries {
            guard let food = entry.food, !seen.contains(food.id) else { continue }
            seen.insert(food.id)
            foods.append(food)
            if foods.count >= limit { break }
        }
        return foods
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
