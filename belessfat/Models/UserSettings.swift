import Foundation
import SwiftData

@Model
final class UserSettings {
    var id: UUID
    var dailyCalories: Double
    var dailyProtein: Double
    var dailyCarbs: Double
    var dailyFat: Double
    var usePercentageMode: Bool
    var proteinPercent: Double
    var carbsPercent: Double
    var fatPercent: Double
    var macroSplitPresetRaw: String
    var macroDisplayModeRaw: String
    var weeklyBudgetEnabled: Bool
    var weeklyCalorieOverride: Double?
    var dailyStepTarget: Int = 10_000
    var weekStartDayRaw: Int = WeekStartDay.monday.rawValue
    var smoothedTDEE: Double?
    var smoothedTDEEDate: Date?
    /// nil = exclude today (default for food reports)
    var foodReportsIncludeToday: Bool?
    /// nil = include today (default for workout reports)
    var workoutReportsIncludeToday: Bool?

    /// Total height in inches (for body-fat estimates).
    var heightInches: Double?
    var biologicalSexRaw: String?
    var birthYear: Int?

    var biologicalSex: BiologicalSex? {
        get { biologicalSexRaw.flatMap(BiologicalSex.init(rawValue:)) }
        set { biologicalSexRaw = newValue?.rawValue }
    }

    var ageYears: Int? {
        guard let birthYear else { return nil }
        let current = Calendar.current.component(.year, from: Date())
        let age = current - birthYear
        return age >= 10 && age <= 120 ? age : nil
    }

    var hasCompleteBodyProfile: Bool {
        guard let heightInches, heightInches > 0,
              biologicalSex != nil,
              ageYears != nil else { return false }
        return true
    }

    var heightFeetInchesLabel: String? {
        guard let heightInches, heightInches > 0 else { return nil }
        let total = Int(heightInches.rounded())
        let feet = total / 12
        let inches = total % 12
        return "\(feet)'\(inches)\""
    }

    var effectiveFoodReportsIncludeToday: Bool {
        foodReportsIncludeToday ?? false
    }

    var effectiveWorkoutReportsIncludeToday: Bool {
        workoutReportsIncludeToday ?? true
    }

    var weekStartDay: WeekStartDay {
        get { WeekStartDay(rawValue: weekStartDayRaw) ?? .monday }
        set { weekStartDayRaw = newValue.rawValue }
    }

    var macroSplitPreset: MacroSplitPreset {
        get { MacroSplitPreset(rawValue: macroSplitPresetRaw) ?? .balanced }
        set { macroSplitPresetRaw = newValue.rawValue }
    }

    var macroDisplayMode: MacroDisplayMode {
        get { MacroDisplayMode(rawValue: macroDisplayModeRaw) ?? .remaining }
        set { macroDisplayModeRaw = newValue.rawValue }
    }

    init() {
        self.id = UUID()
        self.dailyCalories = 2000
        self.dailyProtein = 150
        self.dailyCarbs = 200
        self.dailyFat = 67
        self.usePercentageMode = false
        self.proteinPercent = 30
        self.carbsPercent = 40
        self.fatPercent = 30
        self.macroSplitPresetRaw = MacroSplitPreset.balanced.rawValue
        self.macroDisplayModeRaw = MacroDisplayMode.remaining.rawValue
        self.weeklyBudgetEnabled = true
        self.weeklyCalorieOverride = nil
        self.dailyStepTarget = 10_000
        self.weekStartDayRaw = WeekStartDay.monday.rawValue
    }

    func applyPercentageTargets() {
        guard usePercentageMode else { return }
        dailyProtein = dailyCalories * proteinPercent / 100 / 4
        dailyCarbs = dailyCalories * carbsPercent / 100 / 4
        dailyFat = dailyCalories * fatPercent / 100 / 9
    }

    func normalizeDefaults() {
        if dailyStepTarget <= 0 { dailyStepTarget = 10_000 }
        if weekStartDayRaw == 0 { weekStartDayRaw = WeekStartDay.monday.rawValue }
    }

    var weeklyCalorieCap: Double {
        weeklyCalorieOverride ?? (dailyCalories * 7)
    }
}

@Model
final class WeightEntry {
    var id: UUID
    var date: Date
    var weightLbs: Double
    /// When this value was last set. Nil on older rows (treated as that calendar day).
    var recordedAt: Date?
    var sourceRaw: String?

    var source: WeightEntrySource {
        get { WeightEntrySource(rawValue: sourceRaw ?? "") ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        date: Date,
        weightLbs: Double,
        recordedAt: Date = Date(),
        source: WeightEntrySource = .manual
    ) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.weightLbs = weightLbs
        self.recordedAt = recordedAt
        self.sourceRaw = source.rawValue
    }
}

@Model
final class WeightGoal {
    var id: UUID
    var goalTypeRaw: String
    var startWeightLbs: Double
    var goalWeightLbs: Double
    var startDate: Date = Date()
    var targetDate: Date
    var isActive: Bool

    var goalType: GoalType {
        get { GoalType(rawValue: goalTypeRaw) ?? .lose }
        set { goalTypeRaw = newValue.rawValue }
    }

    init(goalType: GoalType, startWeightLbs: Double, goalWeightLbs: Double, startDate: Date = Date(), targetDate: Date) {
        self.id = UUID()
        self.goalTypeRaw = goalType.rawValue
        self.startWeightLbs = startWeightLbs
        self.goalWeightLbs = goalWeightLbs
        self.startDate = Calendar.current.startOfDay(for: startDate)
        self.targetDate = targetDate
        self.isActive = true
    }
}

@Model
final class DailyHealthSnapshot {
    var id: UUID
    var date: Date
    var steps: Int
    var activeCalories: Double

    init(date: Date, steps: Int = 0, activeCalories: Double = 0) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.steps = steps
        self.activeCalories = activeCalories
    }
}

@Model
final class MealTemplate {
    var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \MealTemplateItem.template)
    var items: [MealTemplateItem]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.items = []
    }
}

@Model
final class MealTemplateItem {
    var id: UUID
    var mealCategoryRaw: String
    var quantity: Double
    var servingUnitRaw: String
    var food: Food?
    var recipe: Recipe?
    var template: MealTemplate?

    var mealCategory: MealCategory {
        get { MealCategory(rawValue: mealCategoryRaw) ?? .uncategorized }
        set { mealCategoryRaw = newValue.rawValue }
    }

    var servingUnit: ServingUnitType {
        get { ServingUnitType(rawValue: servingUnitRaw) ?? .grams }
        set { servingUnitRaw = newValue.rawValue }
    }

    init(from entry: LogEntry) {
        self.id = UUID()
        self.mealCategoryRaw = entry.mealCategoryRaw
        self.quantity = entry.quantity
        self.servingUnitRaw = entry.servingUnitRaw
        self.food = entry.food
        self.recipe = entry.recipe
    }
}

@Model
final class FavoriteMeal {
    var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \FavoriteMealItem.favorite)
    var items: [FavoriteMealItem]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.items = []
    }
}

@Model
final class FavoriteMealItem {
    var id: UUID
    var mealCategoryRaw: String
    var quantity: Double
    var servingUnitRaw: String
    var food: Food?
    var recipe: Recipe?
    var favorite: FavoriteMeal?

    var mealCategory: MealCategory {
        get { MealCategory(rawValue: mealCategoryRaw) ?? .uncategorized }
        set { mealCategoryRaw = newValue.rawValue }
    }

    var servingUnit: ServingUnitType {
        get { ServingUnitType(rawValue: servingUnitRaw) ?? .grams }
        set { servingUnitRaw = newValue.rawValue }
    }

    init(from entry: LogEntry) {
        self.id = UUID()
        self.mealCategoryRaw = entry.mealCategoryRaw
        self.quantity = entry.quantity
        self.servingUnitRaw = entry.servingUnitRaw
        self.food = entry.food
        self.recipe = entry.recipe
    }
}
