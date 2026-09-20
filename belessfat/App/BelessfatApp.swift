import SwiftUI
import SwiftData

@main
struct BelessfatApp: App {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @StateObject private var healthKit = HealthKitService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(healthKit)
                .preferredColorScheme(colorScheme)
        }
        .modelContainer(for: [
            Food.self,
            Recipe.self,
            RecipeIngredient.self,
            LogEntry.self,
            WeightEntry.self,
            WeightGoal.self,
            UserSettings.self,
            DailyHealthSnapshot.self,
            MealTemplate.self,
            MealTemplateItem.self,
            FavoriteMeal.self,
            FavoriteMealItem.self,
            Exercise.self,
            WorkoutTemplate.self,
            WorkoutTemplateExercise.self,
            WorkoutSession.self,
            WorkoutSetLog.self,
            SwimSegment.self,
            WorkoutSettings.self,
            ProgressPhoto.self
        ])
    }

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
