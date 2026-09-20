import SwiftUI
import SwiftData
import UIKit

struct DiaryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var healthKit: HealthKitService
    @Query(sort: \UserSettings.id) private var settingsQuery: [UserSettings]
    @Query(sort: \LogEntry.createdAt) private var allLogEntries: [LogEntry]
    @Query(sort: \DailyHealthSnapshot.date, order: .reverse) private var healthSnapshots: [DailyHealthSnapshot]
    @Query(sort: \WeightGoal.targetDate, order: .reverse) private var weightGoals: [WeightGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var allWeightEntries: [WeightEntry]
    @State private var selectedDate = Date()
    @State private var showAddFood = false
    @State private var showScanner = false
    @State private var showQuickActions = false
    @State private var showFavorites = false
    @State private var showProgressPhotoCapture = false
    @State private var recipeFromMeal: Recipe?
    @State private var expandedMeals: Set<MealCategory> = Set(MealCategory.allCases)
    @State private var healthExpanded = true
    @State private var weightInput = ""
    @State private var lastLoadedWeightText = ""
    @State private var weightSaveError: String?
    @State private var editingEntry: LogEntry?

    private var healthSnapshot: DailyHealthSnapshot? {
        healthSnapshots.first { DateHelpers.isSameDay($0.date, selectedDate) }
    }

    private var settings: UserSettings {
        settingsQuery.first ?? GoalService.settings(context: context)
    }

    private var entries: [LogEntry] {
        allLogEntries.filter { DateHelpers.isSameDay($0.date, selectedDate) }
    }

    private var totals: MacroTotals {
        entries.reduce(.zero) { $0 + $1.macros }
    }

    private var weekTotals: MacroTotals {
        let start = DateHelpers.weekStart(containing: selectedDate, weekStartsOn: settings.weekStartDay)
        let endExclusive = DateHelpers.startOfNextDay(
            DateHelpers.weekEnd(containing: selectedDate, weekStartsOn: settings.weekStartDay)
        )
        return allLogEntries
            .filter { $0.date >= start && $0.date < endExclusive }
            .reduce(.zero) { $0 + $1.macros }
    }

    private var weekRangeLabel: String {
        let start = DateHelpers.weekStart(containing: selectedDate, weekStartsOn: settings.weekStartDay)
        let end = DateHelpers.weekEnd(containing: selectedDate, weekStartsOn: settings.weekStartDay)
        let fmt = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return "\(start.formatted(fmt)) – \(end.formatted(fmt))"
    }

    private var displayedSteps: Int {
        if let snapshot = healthSnapshot {
            return snapshot.steps
        }
        if DateHelpers.isSameDay(selectedDate, healthKit.cachedDate) {
            return healthKit.cachedSteps
        }
        return 0
    }

    private var displayedActiveCalories: Double {
        if let snapshot = healthSnapshot {
            return snapshot.activeCalories
        }
        if DateHelpers.isSameDay(selectedDate, healthKit.cachedDate) {
            return healthKit.cachedActiveCalories
        }
        return 0
    }

    private var weekSteps: Int {
        let start = DateHelpers.weekStart(containing: selectedDate, weekStartsOn: settings.weekStartDay)
        let end = DateHelpers.weekEnd(containing: selectedDate, weekStartsOn: settings.weekStartDay)
        return DateHelpers.daysBetween(start, end).reduce(0) { total, day in
            if DateHelpers.isSameDay(day, selectedDate) {
                return total + displayedSteps
            }
            if let snapshot = healthSnapshots.first(where: { DateHelpers.isSameDay($0.date, day) }) {
                return total + snapshot.steps
            }
            return total
        }
    }

    private var weeklyStepCap: Int {
        settings.dailyStepTarget * 7
    }

    private var weightGoal: WeightGoal? {
        weightGoals.first(where: \.isActive) ?? weightGoals.first
    }

    private var weightEntries: [WeightEntry] {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: selectedDate)!
        let end = DateHelpers.startOfDay(selectedDate)
        return allWeightEntries
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }
    }

    private var displayedWeightLbs: Double? {
        if let lbs = Double(weightInput), lbs > 0 { return lbs }
        if let entry = todaysWeightEntry { return entry.weightLbs }
        return GoalService.mostRecentWeight(onOrBefore: selectedDate, context: context)
    }

    private var todaysWeightEntry: WeightEntry? {
        allWeightEntries.first { DateHelpers.isSameDay($0.date, selectedDate) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    HStack(spacing: 8) {
                        Button {
                            shiftDay(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Previous day")

                        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)

                        Button {
                            shiftDay(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Next day")
                    }

                    if !isViewingToday {
                        Button("Today") {
                            selectedDate = Date()
                        }
                    }
                }

                if showMacroSectionForScreenshot {
                    Section {
                        MacroProgressView(totals: totals, settings: settings)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    if healthExpanded {
                        StepProgressBar(steps: displayedSteps, target: settings.dailyStepTarget)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        netCaloriesRow
                        weightSection
                        if let goal = weightGoal {
                            let current = displayedWeightLbs ?? goal.startWeightLbs
                            let metrics = GoalService.goalMetrics(
                                currentWeight: current,
                                goal: goal,
                                entries: weightEntries,
                                asOf: selectedDate
                            )
                            GoalProgressCard(goal: goal, metrics: metrics, currentWeight: current)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .id("weightGoalCard")
                        }
                    }
                } header: {
                    Button {
                        if healthExpanded {
                            healthExpanded = false
                        } else {
                            healthExpanded = true
                        }
                    } label: {
                        HStack {
                            Text("Activity & Weight")
                            Spacer()
                            if healthExpanded {
                                Text("\(displayedSteps) steps · \(weightSummary)")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: healthExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(HealthKitCopy.diaryStepsFooter)
                }

                ForEach(MealCategory.allCases) { meal in
                    let mealEntries = entries.filter { $0.mealCategory == meal }
                    Section {
                        if expandedMeals.contains(meal) {
                            if mealEntries.isEmpty {
                                Text("No items")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(mealEntries) { entry in
                                    LogEntryRow(entry: entry)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                DiaryService.delete(entry, context: context)
                                            } label: { Label("Delete", systemImage: "trash") }
                                            Button {
                                                DiaryService.duplicate(entry, context: context)
                                            } label: {
                                                Label("Duplicate", systemImage: "plus.square.on.square")
                                            }
                                        }
                                        .swipeActions(edge: .leading) {
                                            if !isViewingToday {
                                                Button {
                                                    copyEntryToToday(entry)
                                                } label: {
                                                    Label("Copy to Today", systemImage: "arrow.right.doc.on.doc")
                                                }
                                                .tint(.blue)
                                            }
                                            Button { editingEntry = entry } label: {
                                                Label("Edit", systemImage: "pencil")
                                            }
                                        }
                                        .contextMenu {
                                            Button("Edit") { editingEntry = entry }
                                            Button("Duplicate") { DiaryService.duplicate(entry, context: context) }
                                            if !isViewingToday {
                                                Button("Copy to Today") { copyEntryToToday(entry) }
                                            }
                                            Divider()
                                            ForEach(MealCategory.allCases) { target in
                                                Button("Move to \(target.displayName)") {
                                                    DiaryService.move(entry, to: target, context: context)
                                                }
                                            }
                                            Button("Delete", role: .destructive) {
                                                DiaryService.delete(entry, context: context)
                                            }
                                        }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Button {
                                if expandedMeals.contains(meal) {
                                    expandedMeals.remove(meal)
                                } else {
                                    expandedMeals.insert(meal)
                                }
                            } label: {
                                HStack {
                                    Text(meal.displayName)
                                    Spacer()
                                    Text("\(Int(mealEntries.reduce(0) { $0 + $1.macros.calories })) cal")
                                        .foregroundStyle(.secondary)
                                    Image(systemName: expandedMeals.contains(meal) ? "chevron.down" : "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if !mealEntries.isEmpty {
                                Menu {
                                    if !isViewingToday {
                                        Button {
                                            copyMealToToday(meal)
                                        } label: {
                                            Label("Copy to Today", systemImage: "arrow.right.doc.on.doc")
                                        }
                                    }
                                    Button {
                                        saveMealAsRecipe(meal, entries: mealEntries)
                                    } label: {
                                        Label("Save as Recipe", systemImage: "book.closed")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section {
                    if settings.weeklyBudgetEnabled {
                        WeeklyBudgetBar(consumed: weekTotals.calories, cap: settings.weeklyCalorieCap, weekLabel: weekRangeLabel)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    WeeklyStepsBar(steps: weekSteps, cap: weeklyStepCap, weekLabel: weekRangeLabel)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .id("weeklyBudget")
            }
            .navigationTitle("Diary")
            #if DEBUG
            .task {
                guard AppStoreScreenshotSeeder.isEnabled else { return }
                applyScreenshotLayout(proxy: proxy)
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showQuickActions = true } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showScanner = true } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    Button { showAddFood = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddFood) {
                FoodSearchView(selectedDate: selectedDate)
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView(selectedDate: selectedDate, onDone: {})
            }
            .sheet(item: $editingEntry) { entry in
                EditLogEntryView(entry: entry)
            }
            .sheet(isPresented: $showFavorites) {
                FavoritesListView(selectedDate: selectedDate)
            }
            .sheet(isPresented: $showProgressPhotoCapture) {
                DiaryProgressPhotoCapture(date: selectedDate)
            }
            .sheet(item: $recipeFromMeal) { recipe in
                RecipeEditorView(existingRecipe: recipe)
            }
            .confirmationDialog("Quick Actions", isPresented: $showQuickActions) {
                Button("Copy Yesterday") { copyYesterday() }
                Button("Save Today as Template") { saveAsTemplate() }
                Button("Log Favorite Meal") { showFavorites = true }
                Button("Save Today as Favorite") { saveAsFavorite() }
                Button("Add Progress Photo") { showProgressPhotoCapture = true }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                loadWeightInput()
                #if DEBUG
                if AppStoreScreenshotSeeder.isEnabled {
                    return
                }
                #endif
                healthKit.refreshAuthorizationStatus()
                healthKit.startObservingWeight(context: context)
                Task { await healthKit.sync(for: selectedDate, context: context) }
            }
            .onChange(of: selectedDate) { _, newDate in
                loadWeightInput()
                Task { await healthKit.sync(for: newDate, context: context) }
            }
            .onChange(of: todaysWeightEntry?.weightLbs) { _, _ in
                guard !isWeightInputDirty else { return }
                loadWeightInput()
            }
            .onChange(of: todaysWeightEntry?.recordedAt) { _, _ in
                guard !isWeightInputDirty else { return }
                loadWeightInput()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await healthKit.sync(for: selectedDate, context: context) }
            }
            .refreshable {
                await healthKit.sync(for: selectedDate, context: context)
            }
            } // ScrollViewReader
        }
    }

    #if DEBUG
    @MainActor
    private func applyScreenshotLayout(proxy: ScrollViewProxy) {
        switch AppStoreScreenshotSeeder.requestedScreen {
        case "addfood":
            healthExpanded = false
            showAddFood = true
        case "weight":
            expandedMeals = []
            healthExpanded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation {
                    proxy.scrollTo("weightGoalCard", anchor: .center)
                }
            }
        case "weekly":
            expandedMeals = []
            healthExpanded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation {
                    proxy.scrollTo("weeklyBudget", anchor: .center)
                }
            }
        default:
            healthExpanded = false
        }
    }
    #endif

    private var isViewingToday: Bool {
        DateHelpers.isSameDay(selectedDate, Date())
    }

    private var showMacroSectionForScreenshot: Bool {
        #if DEBUG
        if AppStoreScreenshotSeeder.isEnabled,
           AppStoreScreenshotSeeder.requestedScreen == "weight" {
            return false
        }
        #endif
        return true
    }

    private func shiftDay(by offset: Int) {
        guard let newDate = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate) else { return }
        selectedDate = newDate
    }

    private var weightSummary: String {
        if let entry = todaysWeightEntry {
            return String(format: "%.1f lbs", entry.weightLbs)
        }
        if let recent = GoalService.mostRecentWeight(onOrBefore: selectedDate, context: context) {
            return String(format: "%.1f lbs", recent)
        }
        return "no weight"
    }

    private var netCaloriesRow: some View {
        let active = displayedActiveCalories
        let net = totals.calories - active
        return HStack {
            Label("Net Calories", systemImage: "flame")
            Spacer()
            Text("\(Int(net)) kcal")
                .fontWeight(.semibold)
                .foregroundStyle(net < 0 ? .green : .primary)
        }
    }

    private var weightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Weight", systemImage: "scalemass")
                .font(.headline)
            HStack {
                DecimalPadTextField(text: $weightInput, placeholder: "lbs", onCommit: saveWeight)
                    .frame(width: 80, height: 36)
                Button("Save") { saveWeight() }
                    .buttonStyle(.borderedProminent)
            }
            if todaysWeightEntry?.source == .healthKit {
                Text("From HealthKit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isWeightInputDirty: Bool {
        weightInput != lastLoadedWeightText
    }

    private func loadWeightInput() {
        if let entry = GoalService.weightEntry(for: selectedDate, context: context) {
            weightInput = String(format: "%.1f", entry.weightLbs)
        } else {
            weightInput = ""
        }
        lastLoadedWeightText = weightInput
    }

    private func saveWeight() {
        defer { dismissKeyboard() }
        guard let lbs = Double(weightInput) else { return }
        GoalService.saveWeight(lbs, for: selectedDate, context: context)
        loadWeightInput()
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func copyYesterday() {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) else { return }
        DiaryService.copyDay(from: yesterday, to: selectedDate, context: context)
    }

    private func copyEntryToToday(_ entry: LogEntry) {
        DiaryService.copyEntry(entry, to: Date(), context: context)
    }

    private func copyMealToToday(_ meal: MealCategory) {
        DiaryService.copyMeal(from: selectedDate, meal: meal, to: Date(), context: context)
    }

    private func saveMealAsRecipe(_ meal: MealCategory, entries: [LogEntry]) {
        recipeFromMeal = FoodService.createRecipeFromMeal(
            entries: entries,
            meal: meal,
            date: selectedDate,
            context: context
        )
    }

    private func saveAsTemplate() {
        let name = "Template \(Date().formatted(date: .abbreviated, time: .omitted))"
        DiaryService.saveTemplate(name: name, from: entries, context: context)
    }

    private func saveAsFavorite() {
        let name = "Favorite \(Date().formatted(date: .abbreviated, time: .omitted))"
        DiaryService.saveFavorite(name: name, from: entries, context: context)
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text(entry.displayName)
                    if entry.food?.isAlcohol == true {
                        Image(systemName: "wineglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(entry.quantity.formatted()) \(entry.servingUnit.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(Int(entry.macros.calories)) cal")
                    .fontWeight(.medium)
                Text("P \(entry.macros.protein.formatted(.number.precision(.fractionLength(0))))g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
