import SwiftUI

struct FoodTabShell: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var quickActions: QuickActionRouter
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DiaryView()
                .tabItem { Label("Diary", systemImage: "book") }
                .tag(0)
            FoodLibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(1)
            ReportsDashboardView()
                .tabItem { Label("Reports", systemImage: "chart.xyaxis.line") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .onAppear {
            if quickActions.pendingMeal != nil {
                selectedTab = 0
            }
            #if DEBUG
            if AppStoreScreenshotSeeder.isEnabled {
                switch AppStoreScreenshotSeeder.requestedScreen {
                case "library", "recipes": selectedTab = 1
                case "reports", "reportscharts": selectedTab = 2
                case "settings", "progress": selectedTab = 3
                default: selectedTab = 0
                }
            }
            #endif
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == 0 else { return }
            #if DEBUG
            if AppStoreScreenshotSeeder.isEnabled { return }
            #endif
            Task { await healthKit.sync(for: Date(), context: context) }
        }
        .onChange(of: quickActions.pendingMeal) { _, meal in
            guard meal != nil else { return }
            selectedTab = 0
        }
    }
}

struct WorkoutTabShell: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            WorkoutLogView()
                .tabItem { Label("Log", systemImage: "figure.strengthtraining.traditional") }
                .tag(0)
            WorkoutReportsView()
                .tabItem { Label("Reports", systemImage: "chart.xyaxis.line") }
                .tag(1)
            WorkoutSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var quickActions: QuickActionRouter
    @EnvironmentObject private var shareImport: ShareImportRouter
    @AppStorage("appSection") private var appSectionRaw = AppSection.food.rawValue
    #if DEBUG
    @State private var showScreenshotAI = false
    @State private var showScreenshotProgress = false
    #endif

    private var appSection: AppSection {
        get { AppSection(rawValue: appSectionRaw) ?? .food }
        set { appSectionRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: Binding(
                get: { appSection },
                set: { appSectionRaw = $0.rawValue }
            )) {
                ForEach(AppSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch appSection {
            case .food:
                FoodTabShell()
            case .workout:
                WorkoutTabShell()
            }
        }
        .sheet(isPresented: Binding(
            get: { shareImport.pending != nil },
            set: { if !$0 { shareImport.pending = nil } }
        )) {
            if let document = shareImport.pending {
                FoodShareImportView(document: document)
            }
        }
        .alert(
            "Couldn't open share",
            isPresented: Binding(
                get: { shareImport.unreadableMessage != nil },
                set: { if !$0 { shareImport.unreadableMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareImport.unreadableMessage ?? "")
        }
        .onChange(of: quickActions.pendingMeal) { _, meal in
            guard meal != nil else { return }
            appSectionRaw = AppSection.food.rawValue
        }
        .onAppear {
            if quickActions.pendingMeal != nil {
                appSectionRaw = AppSection.food.rawValue
            }
            #if DEBUG
            AppStoreScreenshotSeeder.seedIfNeeded(context: context)
            if AppStoreScreenshotSeeder.isEnabled {
                switch AppStoreScreenshotSeeder.requestedScreen {
                case "workout":
                    appSectionRaw = AppSection.workout.rawValue
                case "ai":
                    appSectionRaw = AppSection.food.rawValue
                    showScreenshotAI = true
                case "progress":
                    appSectionRaw = AppSection.food.rawValue
                    showScreenshotProgress = true
                default:
                    appSectionRaw = AppSection.food.rawValue
                }
            }
            #endif
        }
        #if DEBUG
        .preferredColorScheme(AppStoreScreenshotSeeder.isEnabled ? .light : nil)
        .fullScreenCover(isPresented: $showScreenshotAI) {
            AIFoodEstimateView(
                selectedDate: Date(),
                defaultMeal: .lunch,
                onDone: {}
            )
        }
        .fullScreenCover(isPresented: $showScreenshotProgress) {
            NavigationStack {
                ProgressPhotosView()
            }
        }
        #endif
    }
}
