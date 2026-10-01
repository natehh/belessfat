import SwiftUI
import SwiftData
import UIKit

final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()
    @Published var pendingMeal: MealCategory?

    func handle(_ shortcutItem: UIApplicationShortcutItem) {
        pendingMeal = MealCategory(shortcutType: shortcutItem.type)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            QuickActionRouter.shared.handle(shortcutItem)
        }
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = ShortcutSceneDelegate.self
        return configuration
    }
}

final class ShortcutSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        QuickActionRouter.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

@main
struct BelessfatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @StateObject private var healthKit = HealthKitService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(healthKit)
                .environmentObject(QuickActionRouter.shared)
                .preferredColorScheme(colorScheme)
        }
        .modelContainer(for: [
            Food.self,
            Recipe.self,
            RecipeIngredient.self,
            LogEntry.self,
            WeightEntry.self,
            BodyFatEntry.self,
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
