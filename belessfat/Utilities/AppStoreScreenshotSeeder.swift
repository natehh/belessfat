import Foundation
import SwiftData
import UIKit

#if DEBUG
/// Seeds polished demo data when launched with `-AppStoreScreenshots`.
enum AppStoreScreenshotSeeder {
    private static let flagKey = "appStoreScreenshotsSeeded"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-AppStoreScreenshots")
    }

    static var requestedScreen: String {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-AppStoreScreen=") }) else {
            return "diary"
        }
        return String(arg.dropFirst("-AppStoreScreen=".count))
    }

    static func sampleMealImage() -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let bowl = UIBezierPath(ovalIn: CGRect(x: 140, y: 280, width: 620, height: 520))
            UIColor(red: 0.22, green: 0.45, blue: 0.38, alpha: 1).setFill()
            bowl.fill()

            let rice = UIBezierPath(ovalIn: CGRect(x: 220, y: 360, width: 460, height: 360))
            UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1).setFill()
            rice.fill()

            let chicken = UIBezierPath(roundedRect: CGRect(x: 280, y: 420, width: 200, height: 120), cornerRadius: 20)
            UIColor(red: 0.78, green: 0.48, blue: 0.28, alpha: 1).setFill()
            chicken.fill()

            let avocado = UIBezierPath(ovalIn: CGRect(x: 500, y: 450, width: 120, height: 90))
            UIColor(red: 0.45, green: 0.70, blue: 0.30, alpha: 1).setFill()
            avocado.fill()

            let salsa = UIBezierPath(ovalIn: CGRect(x: 360, y: 560, width: 160, height: 100))
            UIColor(red: 0.75, green: 0.18, blue: 0.18, alpha: 1).setFill()
            salsa.fill()
        }
    }

    static func sampleProgressImage(tone: CGFloat) -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.92 - tone * 0.05, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Soft “studio” backdrop
            UIColor(red: 0.85 - tone * 0.1, green: 0.88 - tone * 0.08, blue: 0.90 - tone * 0.05, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 80, y: 120, width: 740, height: 960), cornerRadius: 40).fill()

            // Simple standing figure silhouette for progress-photo placeholder
            let figureColor = UIColor(white: 0.35 + tone * 0.08, alpha: 1)
            figureColor.setFill()
            UIBezierPath(ovalIn: CGRect(x: 370, y: 220, width: 160, height: 160)).fill()
            UIBezierPath(roundedRect: CGRect(x: 340, y: 400, width: 220, height: 420), cornerRadius: 60).fill()
            UIBezierPath(roundedRect: CGRect(x: 300, y: 820, width: 90, height: 220), cornerRadius: 30).fill()
            UIBezierPath(roundedRect: CGRect(x: 510, y: 820, width: 90, height: 220), cornerRadius: 30).fill()
        }
    }

    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        guard isEnabled else { return }
        UserDefaults.standard.set(true, forKey: "forceLightAppearanceForScreenshots")

        if UserDefaults.standard.bool(forKey: flagKey) { return }
        UserDefaults.standard.set(true, forKey: flagKey)

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let settings = GoalService.settings(context: context)
        settings.dailyCalories = 2000
        settings.dailyProtein = 150
        settings.dailyCarbs = 200
        settings.dailyFat = 67
        settings.dailyStepTarget = 10_000
        settings.weeklyBudgetEnabled = true
        settings.heightInches = 70
        settings.biologicalSex = .male
        settings.birthYear = 1992

        let foods: [(String, String?, Double, Double, Double, Double, String, MealCategory)] = [
            ("Greek Yogurt Bowl", "Fage", 320, 28, 32, 8, "1 bowl", .breakfast),
            ("Scrambled Eggs", nil, 180, 14, 2, 13, "2 eggs", .breakfast),
            ("Chicken Rice Bowl", nil, 620, 48, 55, 18, "1 bowl", .lunch),
            ("Side Salad", nil, 90, 3, 8, 5, "1 salad", .lunch),
            ("Salmon & Potatoes", nil, 710, 42, 40, 38, "1 plate", .dinner),
            ("Protein Shake", "Optimum", 160, 30, 4, 2, "1 scoop", .snacks),
            ("Apple", nil, 95, 0, 25, 0, "1 medium", .snacks)
        ]

        var createdFoods: [Food] = []
        for (name, brand, cal, p, c, f, serving, _) in foods {
            let food = Food(
                name: name,
                brand: brand,
                source: .custom,
                caloriesPer100g: cal,
                proteinPer100g: p,
                carbsPer100g: c,
                fatPer100g: f,
                servingSizeGrams: 100,
                servingDescription: serving,
                caloriesPerServing: cal,
                proteinPerServing: p,
                carbsPerServing: c,
                fatPerServing: f
            )
            context.insert(food)
            createdFoods.append(food)
        }

        for (index, item) in foods.enumerated() {
            let entry = LogEntry(
                date: today,
                mealCategory: item.7,
                quantity: 1,
                servingUnit: .serving,
                food: createdFoods[index]
            )
            context.insert(entry)
        }

        for dayOffset in 1...10 {
            guard let date = cal.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            for (meal, foodIndex) in [MealCategory.breakfast: 0, .lunch: 2, .dinner: 4, .snacks: 5] as [MealCategory: Int] {
                context.insert(LogEntry(
                    date: date,
                    mealCategory: meal,
                    quantity: 1,
                    servingUnit: .serving,
                    food: createdFoods[foodIndex]
                ))
            }

            // Older days heavier → losing ~1.2 lb/week so TDEE ≈ intake + deficit (~2,400+).
            let weight = 194.2 + Double(dayOffset) * 0.18 + Double(dayOffset % 2) * 0.05
            context.insert(WeightEntry(date: date, weightLbs: weight))
            context.insert(DailyHealthSnapshot(
                date: date,
                steps: 7800 + dayOffset * 120,
                activeCalories: 480 + Double(dayOffset * 8)
            ))
        }

        context.insert(WeightEntry(date: today, weightLbs: 194.2))
        context.insert(DailyHealthSnapshot(date: today, steps: 8420, activeCalories: 520))

        if let target = cal.date(byAdding: .day, value: 90, to: today) {
            context.insert(WeightGoal(
                goalType: .lose,
                startWeightLbs: 205,
                goalWeightLbs: 180,
                startDate: cal.date(byAdding: .day, value: -30, to: today) ?? today,
                targetDate: target
            ))
        }

        let recipeSpecs: [(String, Int)] = [
            ("Chicken Burrito Bowl", 2),
            ("Overnight Oats", 0),
            ("Salmon Power Plate", 4),
            ("Greek Yogurt Parfait", 0)
        ]
        for (name, foodIndex) in recipeSpecs {
            let recipe = Recipe(name: name, servings: 2)
            context.insert(recipe)
            let ingredient = RecipeIngredient(
                food: createdFoods[foodIndex],
                quantity: 1,
                servingUnit: .serving
            )
            ingredient.recipe = recipe
            context.insert(ingredient)
        }

        // Progress photo day batches with BF%
        if let older = cal.date(byAdding: .day, value: -45, to: today) {
            if let photo = try? ProgressPhotoService.savePhoto(sampleProgressImage(tone: 0.0), for: older, context: context) {
                photo.bodyFatPercent = 22.5
                photo.bodyFatEstimatedAt = older
            }
            if let photo = try? ProgressPhotoService.savePhoto(sampleProgressImage(tone: 0.15), for: older, context: context) {
                photo.bodyFatPercent = 22.5
                photo.bodyFatEstimatedAt = older
            }
        }
        if let mid = cal.date(byAdding: .day, value: -20, to: today) {
            if let photo = try? ProgressPhotoService.savePhoto(sampleProgressImage(tone: 0.35), for: mid, context: context) {
                photo.bodyFatPercent = 19.0
                photo.bodyFatEstimatedAt = mid
            }
        }
        if let photo = try? ProgressPhotoService.savePhoto(sampleProgressImage(tone: 0.55), for: today, context: context) {
            photo.bodyFatPercent = 16.5
            photo.bodyFatEstimatedAt = today
        }
        if let photo = try? ProgressPhotoService.savePhoto(sampleProgressImage(tone: 0.7), for: today, context: context) {
            photo.bodyFatPercent = 16.5
            photo.bodyFatEstimatedAt = today
        }

        let bench = Exercise(name: "Barbell Bench Press", categoryName: "Chest")
        let squat = Exercise(name: "Back Squat", categoryName: "Legs")
        let row = Exercise(name: "Barbell Row", categoryName: "Back")
        context.insert(bench)
        context.insert(squat)
        context.insert(row)

        let session = WorkoutSession(
            date: today,
            workoutType: .strength,
            durationMinutes: 55,
            syncToHealthKit: false
        )
        session.estimatedCalories = 380
        context.insert(session)

        let sets: [(Exercise, Int, Int, Double)] = [
            (bench, 0, 8, 135),
            (bench, 1, 8, 155),
            (bench, 2, 6, 175),
            (squat, 0, 5, 185),
            (squat, 1, 5, 205),
            (row, 0, 10, 135),
            (row, 1, 8, 145)
        ]
        for (exercise, setIndex, reps, weight) in sets {
            let order: Int
            switch exercise.name {
            case bench.name: order = 0
            case squat.name: order = 1
            default: order = 2
            }
            let log = WorkoutSetLog(
                exercise: exercise,
                exerciseSortOrder: order,
                setIndex: setIndex,
                reps: reps,
                weightLbs: weight
            )
            log.session = session
            log.snapshotExerciseName = exercise.name
            context.insert(log)
        }

        try? context.save()
    }
}
#endif
