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

enum WeightEntrySource: String, Codable {
    case manual
    case healthKit
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
    case swimming

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .strength: return "Weight Training"
        case .tennisSingles: return "Tennis (Singles)"
        case .tennisDoubles: return "Tennis (Doubles)"
        case .treadmill: return "Treadmill"
        case .swimming: return "Swimming"
        }
    }

    var systemImage: String {
        switch self {
        case .strength: return "dumbbell.fill"
        case .tennisSingles, .tennisDoubles: return "figure.tennis"
        case .treadmill: return "figure.run"
        case .swimming: return "figure.pool.swim"
        }
    }

    var writesHealthKitSteps: Bool {
        switch self {
        case .tennisSingles, .tennisDoubles, .treadmill: return true
        case .strength, .swimming: return false
        }
    }
}

enum SwimStroke: String, Codable, CaseIterable, Identifiable {
    case freestyle
    case backstroke
    case breaststroke
    case butterfly
    case kick
    case mixed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .freestyle: return "Freestyle"
        case .backstroke: return "Backstroke"
        case .breaststroke: return "Breaststroke"
        case .butterfly: return "Butterfly"
        case .kick: return "Kick"
        case .mixed: return "IM / Mixed"
        }
    }

    /// Compendium of Physical Activities, typical lap-swim effort (not leisurely floating).
    var met: Double {
        switch self {
        case .freestyle: return 8.3
        case .backstroke: return 8.0
        case .breaststroke: return 9.0
        case .butterfly: return 13.8
        case .kick: return 6.0
        case .mixed: return 9.5
        }
    }

    /// Relative velocity for splitting clock time across strokes (m/min).
    var relativeVelocityMetersPerMin: Double {
        switch self {
        case .freestyle: return 50
        case .backstroke: return 45
        case .breaststroke: return 40
        case .butterfly: return 35
        case .kick: return 30
        case .mixed: return 45
        }
    }
}

enum PoolLength: String, Codable, CaseIterable, Identifiable {
    case yards25
    case meters25
    case meters50

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yards25: return "25 yd"
        case .meters25: return "25 m"
        case .meters50: return "50 m"
        }
    }

    var meters: Double {
        switch self {
        case .yards25: return 22.86
        case .meters25: return 25
        case .meters50: return 50
        }
    }

    var lengthLabel: String {
        switch self {
        case .yards25: return "yd"
        case .meters25, .meters50: return "m"
        }
    }

    var lengthValue: Int {
        switch self {
        case .yards25, .meters25: return 25
        case .meters50: return 50
        }
    }

    func distanceLabel(lengths: Int) -> String {
        "\(lengths * lengthValue) \(lengthLabel)"
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
