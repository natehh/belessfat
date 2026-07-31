import SwiftUI
import SwiftData

struct LogFoodPresentation: Identifiable {
    let id = UUID()
    let food: Food
    let defaultMeal: MealCategory
}

enum FoodSearchTab: String, CaseIterable, Identifiable {
    case recents
    case custom
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recents: return "Recents"
        case .custom: return "Custom"
        case .all: return "All"
        }
    }
}

struct FoodRowView: View {
    let food: Food

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(food.displayName)
            HStack(spacing: 6) {
                Text(food.source.rawValue.uppercased())
                if food.source == .custom, food.caloriesPerServing > 0 {
                    Text("· \(Int(food.caloriesPerServing)) kcal · \(ServingConverter.servingLabel(for: .serving, food: food))")
                } else if food.caloriesPer100g > 0 {
                    Text("· \(Int(food.caloriesPer100g)) kcal/100g")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct RecipeRowView: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.name)
            HStack(spacing: 6) {
                Text("RECIPE")
                let perServing = recipe.macrosPerServing
                if perServing.calories > 0 {
                    Text("· \(Int(perServing.calories)) kcal/serving")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct FoodBrowserView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var network = NetworkMonitor.shared

    @Binding var selectedTab: FoodSearchTab
    @Binding var query: String

    let onSelectFood: (Food) -> Void
    var onSelectRecipe: ((Recipe) -> Void)? = nil
    var onDeleteCustomFood: ((Food) -> Void)? = nil

    @State private var remoteResults: [Food] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if !network.isConnected, selectedTab == .all {
                Label("No internet — online search requires a connection", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            Picker("Tab", selection: $selectedTab) {
                ForEach(FoodSearchTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            List {
                switch selectedTab {
                case .recents:
                    recentsContent
                case .custom:
                    customContent
                case .all:
                    allContent
                }
            }
            .listStyle(.plain)
        }
        .searchable(text: $query, prompt: searchPrompt)
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onChange(of: selectedTab) { _, _ in
            scheduleSearch(for: query)
        }
        .onAppear {
            scheduleSearch(for: query)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private var searchPrompt: String {
        switch selectedTab {
        case .recents: return "Filter recents"
        case .custom: return "Search custom foods & recipes"
        case .all: return "Search all foods"
        }
    }

    @ViewBuilder
    private var recentsContent: some View {
        let recent = filteredRecents()
        let frequent = filteredFrequent()
        if recent.isEmpty && frequent.isEmpty {
            Text(query.isEmpty ? "Foods you log will appear here." : "No matching recents.")
                .foregroundStyle(.secondary)
        } else {
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.id) { food in
                        Button { onSelectFood(food) } label: { FoodRowView(food: food) }
                    }
                }
            }
            if !frequent.isEmpty {
                Section("Frequent") {
                    ForEach(frequent, id: \.food.id) { item in
                        Button { onSelectFood(item.food) } label: {
                            HStack {
                                FoodRowView(food: item.food)
                                Spacer()
                                Text("\(item.count)×")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var customContent: some View {
        let foods = FoodService.searchCustomFoods(query: query, context: context)
        let recipes = FoodService.searchRecipes(query: query, context: context)
        if foods.isEmpty && recipes.isEmpty {
            Text(query.isEmpty ? "Create custom foods or recipes from the + menu." : "No matching custom foods or recipes.")
                .foregroundStyle(.secondary)
        } else {
            if !recipes.isEmpty {
                Section("Recipes") {
                    ForEach(recipes) { recipe in
                        Button {
                            onSelectRecipe?(recipe)
                        } label: {
                            RecipeRowView(recipe: recipe)
                        }
                    }
                }
            }
            if !foods.isEmpty {
                Section(foods.isEmpty || recipes.isEmpty ? "" : "Foods") {
                    ForEach(foods, id: \.id) { food in
                        Button { onSelectFood(food) } label: { FoodRowView(food: food) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if let onDeleteCustomFood {
                                    Button(role: .destructive) {
                                        onDeleteCustomFood(food)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var allContent: some View {
        if isSearching {
            ProgressView()
        } else if let errorMessage {
            Text(errorMessage).foregroundStyle(.red)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            Text("Type at least 2 characters to search USDA and Open Food Facts.")
                .foregroundStyle(.secondary)
        } else if remoteResults.isEmpty {
            Text("No results. Check your connection.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(remoteResults, id: \.id) { food in
                Button { onSelectFood(food) } label: { FoodRowView(food: food) }
            }
        }
    }

    private func filteredRecents() -> [Food] {
        let foods = DiaryService.recentFoods(context: context)
        return filterFoods(foods)
    }

    private func filteredFrequent() -> [(food: Food, count: Int)] {
        let items = DiaryService.frequentFoods(context: context)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        return items.filter {
            $0.food.name.localizedCaseInsensitiveContains(query)
                || ($0.food.brand?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func filterFoods(_ foods: [Food]) -> [Food] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return foods }
        return foods.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.brand?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        guard selectedTab == .all else {
            remoteResults = []
            errorMessage = nil
            isSearching = false
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            remoteResults = []
            errorMessage = nil
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runRemoteSearch(trimmed)
        }
    }

    @MainActor
    private func runRemoteSearch(_ trimmed: String) async {
        isSearching = true
        errorMessage = nil
        do {
            let remote = try await FoodService.searchRemote(query: trimmed)
            let customMatches = FoodService.searchCustomFoods(query: trimmed, context: context)
            remoteResults = FoodService.mergeFoodResultsForDisplay(remote: remote, custom: customMatches)
        } catch {
            errorMessage = "Search failed. Internet required for food lookup."
            remoteResults = []
        }
        isSearching = false
    }
}

struct FoodSearchView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let selectedDate: Date

    @State private var selectedTab: FoodSearchTab = .recents
    @State private var query = ""
    @State private var logFoodPresentation: LogFoodPresentation?
    @State private var isPreparingFood = false
    @State private var showCustomFood = false
    @State private var showAIEstimate = false
    @State private var showScanner = false
    @State private var showLabelScan = false
    @State private var showRecipes = false
    @State private var scannedBarcode: String?
    @State private var customFoodToDelete: Food?
    @State private var recipeToLog: Recipe?

    var body: some View {
        NavigationStack {
            FoodBrowserView(
                selectedTab: $selectedTab,
                query: $query,
                onSelectFood: { food in presentLogFood(food) },
                onSelectRecipe: { recipe in recipeToLog = recipe },
                onDeleteCustomFood: { customFoodToDelete = $0 }
            )
            .navigationTitle("Add Food")
            #if DEBUG
            .onAppear {
                if AppStoreScreenshotSeeder.isEnabled {
                    selectedTab = .custom
                    query = ""
                }
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Scan Barcode") { showScanner = true }
                        Button("Scan Nutrition Label") { showLabelScan = true }
                        Button("Estimate with AI") { showAIEstimate = true }
                        Button("Custom Food") { showCustomFood = true }
                        Button("Recipes") { showRecipes = true }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .overlay {
                if isPreparingFood {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView("Loading food details...")
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .sheet(item: $logFoodPresentation) { presentation in
                LogFoodSheet(
                    food: presentation.food,
                    defaultMeal: presentation.defaultMeal,
                    date: selectedDate
                ) { dismiss() }
            }
            .sheet(isPresented: $showCustomFood) {
                CustomFoodFormView(
                    barcode: nil,
                    selectedDate: selectedDate,
                    defaultMeal: DiaryService.mostRecentMeal(context: context),
                    onDone: { dismiss() }
                )
            }
            .sheet(isPresented: $showAIEstimate) {
                AIFoodEstimateView(
                    selectedDate: selectedDate,
                    defaultMeal: DiaryService.mostRecentMeal(context: context),
                    onDone: { dismiss() }
                )
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView(
                    selectedDate: selectedDate,
                    recipeMode: false,
                    onFoodPrepared: nil
                ) { dismiss() }
            }
            .sheet(isPresented: $showLabelScan) {
                LabelCaptureView(
                    barcode: scannedBarcode,
                    selectedDate: selectedDate,
                    defaultMeal: DiaryService.mostRecentMeal(context: context)
                ) { dismiss() }
            }
            .sheet(isPresented: $showRecipes) {
                RecipeListView(
                    selectedDate: selectedDate,
                    defaultMeal: DiaryService.mostRecentMeal(context: context)
                ) { dismiss() }
            }
            .sheet(item: $recipeToLog) { recipe in
                NavigationStack {
                    LogRecipeView(
                        recipe: recipe,
                        defaultMeal: DiaryService.mostRecentMeal(context: context),
                        date: selectedDate
                    ) { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete Custom Food?",
                isPresented: Binding(
                    get: { customFoodToDelete != nil },
                    set: { if !$0 { customFoodToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let customFoodToDelete {
                        FoodService.deleteCustomFood(customFoodToDelete, context: context)
                    }
                    customFoodToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    customFoodToDelete = nil
                }
            } message: {
                if let customFoodToDelete {
                    Text("\"\(customFoodToDelete.displayName)\" will be permanently deleted. Past diary entries will be kept; recipe ingredients using it will be removed.")
                }
            }
        }
    }

    private func presentLogFood(_ food: Food) {
        Task {
            isPreparingFood = true
            let prepared = await FoodService.prepareForLogging(food, context: context)
            isPreparingFood = false
            logFoodPresentation = LogFoodPresentation(
                food: prepared,
                defaultMeal: DiaryService.mostRecentMeal(context: context)
            )
        }
    }
}

struct LogFoodSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let food: Food
    let date: Date
    let onDone: () -> Void

    @State private var quantity: Double
    @State private var unit: ServingUnitType
    @State private var meal: MealCategory

    init(food: Food, defaultMeal: MealCategory, date: Date, onDone: @escaping () -> Void) {
        self.food = food
        self.date = date
        self.onDone = onDone
        _meal = State(initialValue: defaultMeal)

        let available = food.availableServingUnits
        let defaultUnit: ServingUnitType
        if food.source == .usda, available.contains(.grams) {
            defaultUnit = .grams
        } else if available.contains(.tablespoon) {
            defaultUnit = .tablespoon
        } else if available.contains(.teaspoon) {
            defaultUnit = .teaspoon
        } else if available.contains(.medium) {
            defaultUnit = .medium
        } else if available.contains(.serving) {
            defaultUnit = .serving
        } else if available.contains(.cup) {
            defaultUnit = .cup
        } else {
            defaultUnit = available.first ?? .grams
        }

        let defaultQuantity: Double
        switch defaultUnit {
        case .grams: defaultQuantity = 100
        case .teaspoon, .tablespoon, .cup, .serving, .small, .medium, .large: defaultQuantity = 1
        default: defaultQuantity = 1
        }

        _unit = State(initialValue: defaultUnit)
        _quantity = State(initialValue: defaultQuantity)
    }

    private var quantityRange: ClosedRange<Double> {
        ServingConverter.quantityRange(for: unit)
    }

    private var quantityStep: Double {
        ServingConverter.quantityStep(for: unit)
    }

    private var macros: MacroTotals {
        food.macros(for: quantity, unit: unit)
    }

    private var unitBinding: Binding<ServingUnitType> {
        Binding(
            get: { unit },
            set: { newUnit in
                unit = newUnit
                let range = ServingConverter.quantityRange(for: newUnit)
                quantity = min(max(quantity, range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Text(food.displayName)
                    .font(.headline)
                Picker("Meal", selection: $meal) {
                    ForEach(MealCategory.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                NumericStepperField(
                    title: "Quantity (\(ServingConverter.servingLabel(for: unit, food: food)))",
                    value: $quantity,
                    range: quantityRange,
                    step: quantityStep,
                    format: unit == .grams ? "%.0f" : "%g"
                )
                Picker("Unit", selection: unitBinding) {
                    ForEach(food.availableServingUnits, id: \.self) { u in
                        Text(ServingConverter.servingLabel(for: u, food: food)).tag(u)
                    }
                }
                Section("Macros") {
                    LabeledContent("Calories", value: "\(Int(macros.calories))")
                    LabeledContent("Protein", value: "\(macros.protein.formatted())g")
                    LabeledContent("Carbs", value: "\(macros.carbs.formatted())g")
                    LabeledContent("Fat", value: "\(macros.fat.formatted())g")
                }
            }
            .navigationTitle("Log Food")
            .keyboardDismissToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        DiaryService.addEntry(food: food, quantity: quantity, unit: unit, meal: meal, date: date, context: context)
                        dismiss()
                        onDone()
                    }
                }
            }
        }
    }
}

struct FoodQuantitySheet: View {
    @Environment(\.dismiss) private var dismiss
    let food: Food
    let title: String
    let confirmTitle: String
    let initialQuantity: Double?
    let initialUnit: ServingUnitType?
    let onConfirm: (Double, ServingUnitType) -> Void

    @State private var quantity: Double
    @State private var unit: ServingUnitType

    init(
        food: Food,
        title: String = "Add Ingredient",
        confirmTitle: String = "Add",
        initialQuantity: Double? = nil,
        initialUnit: ServingUnitType? = nil,
        onConfirm: @escaping (Double, ServingUnitType) -> Void
    ) {
        self.food = food
        self.title = title
        self.confirmTitle = confirmTitle
        self.initialQuantity = initialQuantity
        self.initialUnit = initialUnit
        self.onConfirm = onConfirm

        let available = food.availableServingUnits
        let defaultUnit = initialUnit ?? (available.contains(.grams) ? .grams : (available.first ?? .grams))
        let defaultQuantity = initialQuantity ?? (defaultUnit == .grams ? 100 : 1)
        _unit = State(initialValue: defaultUnit)
        _quantity = State(initialValue: defaultQuantity)
    }

    private var quantityRange: ClosedRange<Double> {
        ServingConverter.quantityRange(for: unit)
    }

    private var quantityStep: Double {
        ServingConverter.quantityStep(for: unit)
    }

    private var unitBinding: Binding<ServingUnitType> {
        Binding(
            get: { unit },
            set: { newUnit in
                unit = newUnit
                let range = ServingConverter.quantityRange(for: newUnit)
                quantity = min(max(quantity, range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Text(food.displayName).font(.headline)
                NumericStepperField(
                    title: "Quantity (\(ServingConverter.servingLabel(for: unit, food: food)))",
                    value: $quantity,
                    range: quantityRange,
                    step: quantityStep,
                    format: unit == .grams ? "%.0f" : "%g"
                )
                Picker("Unit", selection: unitBinding) {
                    ForEach(food.availableServingUnits, id: \.self) { u in
                        Text(ServingConverter.servingLabel(for: u, food: food)).tag(u)
                    }
                }
                let macros = food.macros(for: quantity, unit: unit)
                Section("Macros") {
                    LabeledContent("Calories", value: "\(Int(macros.calories))")
                    LabeledContent("Protein", value: "\(macros.protein.formatted())g")
                    LabeledContent("Carbs", value: "\(macros.carbs.formatted())g")
                    LabeledContent("Fat", value: "\(macros.fat.formatted())g")
                }
            }
            .navigationTitle(title)
            .keyboardDismissToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onConfirm(quantity, unit)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct EditLogEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let entry: LogEntry
    @State private var quantity: Double
    @State private var unit: ServingUnitType
    @State private var meal: MealCategory

    init(entry: LogEntry) {
        self.entry = entry
        _quantity = State(initialValue: entry.quantity)
        _unit = State(initialValue: entry.servingUnit)
        _meal = State(initialValue: entry.mealCategory)
    }

    private var quantityRange: ClosedRange<Double> {
        ServingConverter.quantityRange(for: unit)
    }

    private var quantityStep: Double {
        ServingConverter.quantityStep(for: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Text(entry.displayName)
                Picker("Meal", selection: $meal) {
                    ForEach(MealCategory.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                NumericStepperField(
                    title: "Quantity",
                    value: $quantity,
                    range: quantityRange,
                    step: quantityStep,
                    format: unit == .grams ? "%.0f" : "%g"
                )
                if entry.hasSnapshot {
                    Text("This item was deleted; only meal and quantity can be edited.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let food = entry.food {
                    Picker("Unit", selection: $unit) {
                        ForEach(food.availableServingUnits, id: \.self) { u in
                            Text(ServingConverter.servingLabel(for: u, food: food)).tag(u)
                        }
                    }
                }
            }
            .onChange(of: unit) { _, _ in
                quantity = min(max(quantity, quantityRange.lowerBound), quantityRange.upperBound)
            }
            .navigationTitle("Edit Entry")
            .keyboardDismissToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        entry.quantity = quantity
                        entry.servingUnit = unit
                        entry.mealCategory = meal
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
