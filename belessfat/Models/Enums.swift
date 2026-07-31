import Foundation

enum MealCategory: String, Codable, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snacks
    case uncategorized

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .snacks: return "Snacks"
        case .uncategorized: return "Uncategorized"
        }
    }
}

enum FoodSource: String, Codable {
    case usda
    case off
    case custom
}

enum GoalType: String, Codable, CaseIterable, Identifiable {
    case lose
    case maintain
    case gain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lose: return "Lose Weight"
        case .maintain: return "Maintain Weight"
        case .gain: return "Gain Weight"
        }
    }
}

enum MacroDisplayMode: String, Codable, CaseIterable {
    case remaining
    case percent

    var displayName: String {
        switch self {
        case .remaining: return "Remaining"
        case .percent: return "Percent"
        }
    }
}

enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
    case male
    case female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        }
    }
}

enum MacroSplitPreset: String, CaseIterable, Identifiable {
    case balanced = "40/30/30"
    case highProtein = "40/40/20"
    case lowCarb = "35/35/30"
    case keto = "25/5/70"
    case custom

    var id: String { rawValue }

    var proteinPercent: Double {
        switch self {
        case .balanced: return 30
        case .highProtein: return 40
        case .lowCarb: return 35
        case .keto: return 25
        case .custom: return 30
        }
    }

    var carbsPercent: Double {
        switch self {
        case .balanced: return 40
        case .highProtein: return 20
        case .lowCarb: return 30
        case .keto: return 5
        case .custom: return 40
        }
    }

    var fatPercent: Double {
        switch self {
        case .balanced: return 30
        case .highProtein: return 40
        case .lowCarb: return 35
        case .keto: return 70
        case .custom: return 30
        }
    }
}

enum ServingUnitType: String, Codable, CaseIterable {
    case grams
    case ounces
    case teaspoon
    case tablespoon
    case cup
    case serving
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .grams: return "g"
        case .ounces: return "oz"
        case .teaspoon: return "tsp"
        case .tablespoon: return "tbsp"
        case .cup: return "cup"
        case .serving: return "serving"
        case .small: return "small"
        case .medium: return "medium"
        case .large: return "large"
        }
    }

    /// Units available when defining a custom food's serving size.
    static var customFoodServingUnits: [ServingUnitType] {
        [.grams, .ounces, .teaspoon, .tablespoon, .cup]
    }
}

enum WeekStartDay: Int, CaseIterable, Identifiable, Codable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case food = "Food"
    case workout = "Workout"

    var id: String { rawValue }
}

enum WorkoutType: String, Codable, CaseIterable, Identifiable {
    case strength
    case tennisSingles
    case tennisDoubles
    case treadmill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .strength: return "Weight Training"
        case .tennisSingles: return "Tennis (Singles)"
        case .tennisDoubles: return "Tennis (Doubles)"
        case .treadmill: return "Treadmill"
        }
    }

    var systemImage: String {
        switch self {
        case .strength: return "dumbbell.fill"
        case .tennisSingles, .tennisDoubles: return "figure.tennis"
        case .treadmill: return "figure.run"
        }
    }
}

enum ReportTimeframe: String, CaseIterable, Identifiable {
    case week = "Last 7 Days"
    case twoWeeks = "Last 14 Days"
    case month = "Last 30 Days"
    case custom = "Custom"

    var id: String { rawValue }

    func dateRange(customStart: Date? = nil, customEnd: Date? = nil, includeToday: Bool = true) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let resolvedEnd: Date
        if self == .custom {
            resolvedEnd = calendar.startOfDay(for: customEnd ?? today)
        } else if includeToday {
            resolvedEnd = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            resolvedEnd = yesterday
        } else {
            resolvedEnd = today
        }
        switch self {
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: resolvedEnd)!
            return (start, resolvedEnd)
        case .twoWeeks:
            let start = calendar.date(byAdding: .day, value: -13, to: resolvedEnd)!
            return (start, resolvedEnd)
        case .month:
            let start = calendar.date(byAdding: .day, value: -29, to: resolvedEnd)!
            return (start, resolvedEnd)
        case .custom:
            let start = calendar.startOfDay(for: customStart ?? calendar.date(byAdding: .day, value: -6, to: resolvedEnd)!)
            return (start, resolvedEnd)
        }
    }

    func rangeLabel(start: Date, end: Date) -> String {
        let fmt = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return "\(start.formatted(fmt)) – \(end.formatted(fmt))"
    }
}
