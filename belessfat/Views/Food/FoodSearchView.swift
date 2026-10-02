import SwiftUI
import SwiftData

struct LogFoodPresentation: Identifiable {
    let id = UUID()
    let food: Food
    let defaultMeal: MealCategory
    let quantity: Double
    let unit: ServingUnitType
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
    var loggingAmount: DiaryService.LoggedAmount? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(food.displayName)
            HStack(spacing: 6) {
                if let loggingAmount {
                    let macros = food.macros(for: loggingAmount.quantity, unit: loggingAmount.unit)
                    Text("\(Int(macros.calories)) cal")
                    Text("· \(ServingConverter.compactAmountLabel(quantity: loggingAmount.quantity, unit: loggingAmount.unit, food: food))")
                    if let brand = food.brand, !brand.isEmpty {
                        Text("· \(brand)")
                    }
                } else {
                    Text(food.source.rawValue.uppercased())
                    if food.source == .custom, food.caloriesPerServing > 0 {
                        Text("· \(Int(food.caloriesPerServing)) kcal · \(ServingConverter.servingLabel(for: .serving, food: food))")
                    } else if food.caloriesPer100g > 0 {
                        Text("· \(Int(food.caloriesPer100g)) kcal/100g")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct RecipeRowView: View {
    let recipe: Recipe
    var loggingAmount: DiaryService.LoggedAmount? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.name)
            HStack(spacing: 6) {
                if let loggingAmount {
                    let macros = recipe.macros(
                        for: loggingAmount.quantity,
                        unit: loggingAmount.unit,
                        overrides: loggingAmount.recipeOverrides
                    )
                    Text("\(Int(macros.calories)) cal")
                    Text("· \(ServingConverter.compactAmountLabel(quantity: loggingAmount.quantity, unit: loggingAmount.unit, recipe: recipe))")
                    Text("· RECIPE")
                } else {
                    Text("RECIPE")
                    let perServing = recipe.macrosPerServing
                    if perServing.calories > 0 {
                        Text("· \(Int(perServing.calories)) kcal/serving")
                    }
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
    var onQuickAddFood: ((Food) -> Void)? = nil
    var onQuickAddRecipe: ((Recipe) -> Void)? = nil
    var justAddedIDs: Set<UUID> = []

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

    private var showsQuickAdd: Bool {
        (onQuickAddFood != nil || onQuickAddRecipe != nil) && selectedTab != .all
    }

    private var includesRecipes: Bool {
        onSelectRecipe != nil
    }

    @ViewBuilder
    private var recentsContent: some View {
        let recent = filteredRecents()
        let frequent = filteredFrequent()
        let amounts = DiaryService.lastLoggedAmounts(context: context)
        if recent.isEmpty && frequent.isEmpty {
            Text(query.isEmpty
                 ? (includesRecipes ? "Foods and recipes you log will appear here." : "Foods you log will appear here.")
                 : "No matching recents.")
                .foregroundStyle(.secondary)
        } else {
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { item in
                        recentItemRow(item, amounts: amounts)
                    }
                }
            }
            if !frequent.isEmpty {
                Section("Frequent") {
                    ForEach(frequent, id: \.item.id) { entry in
                        recentItemRow(entry.item, amounts: amounts, accessory: "\(entry.count)×")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var customContent: some View {
        let foods = FoodService.searchCustomFoods(query: query, context: context)
        let recipes = includesRecipes ? FoodService.searchRecipes(query: query, context: context) : []
        let amounts = DiaryService.lastLoggedAmounts(context: context)
        if foods.isEmpty && recipes.isEmpty {
            Text(query.isEmpty
                 ? (includesRecipes ? "Create custom foods or recipes from the + menu." : "Create custom foods from the + menu.")
                 : (includesRecipes ? "No matching custom foods or recipes." : "No matching custom foods."))
                .foregroundStyle(.secondary)
        } else {
            if !recipes.isEmpty {
                Section("Recipes") {
                    ForEach(recipes) { recipe in
                        recipeLogRow(
                            recipe,
                            amount: DiaryService.loggingAmount(for: recipe, lastLogged: amounts)
                        )
                    }
                }
            }
            if !foods.isEmpty {
                Section(foods.isEmpty || recipes.isEmpty ? "" : "Foods") {
                    ForEach(foods, id: \.id) { food in
                        foodLogRow(food, amount: DiaryService.loggingAmount(for: food, lastLogged: amounts))
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
    private func foodLogRow(
        _ food: Food,
        amount: DiaryService.LoggedAmount,
        accessory: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelectFood(food)
            } label: {
                HStack {
                    FoodRowView(food: food, loggingAmount: showsQuickAdd ? amount : nil)
                    Spacer(minLength: 0)
                    if let accessory {
                        Text(accessory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsQuickAdd, let onQuickAddFood {
                Button {
                    onQuickAddFood(food)
                } label: {
                    Image(systemName: justAddedIDs.contains(food.id) ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: justAddedIDs.contains(food.id))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Quick add \(food.displayName)")
            }
        }
    }

    @ViewBuilder
    private func recipeLogRow(
        _ recipe: Recipe,
        amount: DiaryService.LoggedAmount,
        accessory: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelectRecipe?(recipe)
            } label: {
                HStack {
                    RecipeRowView(recipe: recipe, loggingAmount: showsQuickAdd ? amount : nil)
                    Spacer(minLength: 0)
                    if let accessory {
                        Text(accessory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsQuickAdd, let onQuickAddRecipe {
                Button {
                    onQuickAddRecipe(recipe)
                } label: {
                    Image(systemName: justAddedIDs.contains(recipe.id) ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: justAddedIDs.contains(recipe.id))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Quick add \(recipe.name)")
            }
        }
    }

    @ViewBuilder
    private func recentItemRow(
        _ item: DiaryService.RecentItem,
        amounts: [UUID: DiaryService.LoggedAmount],
        accessory: String? = nil
    ) -> some View {
        switch item {
        case .food(let food):
            foodLogRow(
                food,
                amount: DiaryService.loggingAmount(for: food, lastLogged: amounts),
                accessory: accessory
            )
        case .recipe(let recipe):
            recipeLogRow(
                recipe,
                amount: DiaryService.loggingAmount(for: recipe, lastLogged: amounts),
                accessory: accessory
            )
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

    private func filteredRecents() -> [DiaryService.RecentItem] {
        filterItems(DiaryService.recentItems(context: context, includeRecipes: includesRecipes))
    }

    private func filteredFrequent() -> [(item: DiaryService.RecentItem, count: Int)] {
        let items = DiaryService.frequentItems(context: context, includeRecipes: includesRecipes)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { matchesQuery($0.item, query: trimmed) }
    }

    private func filterItems(_ items: [DiaryService.RecentItem]) -> [DiaryService.RecentItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { matchesQuery($0, query: trimmed) }
    }

    private func matchesQuery(_ item: DiaryService.RecentItem, query: String) -> Bool {
        item.name.localizedCaseInsensitiveContains(query)
            || (item.brand?.localizedCaseInsensitiveContains(query) ?? false)
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

    @State private var meal: MealCategory
    @State private var selectedTab: FoodSearchTab = .recents
    @State private var query = ""
    @State private var logFoodPresentation: LogFoodPresentation?
    @State private var isPreparingFood = false
    @State private var showCustomFood = false
    @State private var showAIEstimate = false
    @State private var showMenuEstimate = false
    @State private var showScanner = false
    @State private var showLabelScan = false
    @State private var showRecipes = false
    @State private var scannedBarcode: String?
    @State private var customFoodToDelete: Food?
    @State private var recipeToLog: Recipe?
    @State private var justAddedIDs: Set<UUID> = []

    init(selectedDate: Date, defaultMeal: MealCategory) {
        self.selectedDate = selectedDate
        _meal = State(initialValue: defaultMeal)
    }

    private var selectableMeals: [MealCategory] {
        var meals: [MealCategory] = [.breakfast, .lunch, .dinner, .snacks]
        if meal == .uncategorized {
            meals.append(.uncategorized)
        }
        return meals
    }

    var body: some View {
        NavigationStack {
            FoodBrowserView(
                selectedTab: $selectedTab,
                query: $query,
                onSelectFood: { food in presentLogFood(food) },
                onSelectRecipe: { recipe in recipeToLog = recipe },
                onDeleteCustomFood: { customFoodToDelete = $0 },
                onQuickAddFood: { food in quickAdd(food) },
                onQuickAddRecipe: { recipe in quickAdd(recipe) },
                justAddedIDs: justAddedIDs
            )
            .navigationTitle(meal.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("Meal", selection: $meal) {
                    ForEach(selectableMeals) { category in
                        Text(category.displayName).tag(category)
                    }
                }
            }
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
                        Button("Estimate Menu") { showMenuEstimate = true }
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
                    date: selectedDate,
                    initialQuantity: presentation.quantity,
                    initialUnit: presentation.unit
                ) { dismiss() }
            }
            .sheet(isPresented: $showCustomFood) {
                CustomFoodFormView(
                    barcode: nil,
                    selectedDate: selectedDate,
                    defaultMeal: meal,
                    onDone: { dismiss() }
                )
            }
            .sheet(isPresented: $showAIEstimate) {
                AIFoodEstimateView(
                    selectedDate: selectedDate,
                    defaultMeal: meal,
                    onDone: { dismiss() }
                )
            }
            .sheet(isPresented: $showMenuEstimate) {
                MenuEstimateView(
                    selectedDate: selectedDate,
                    defaultMeal: meal,
                    onDone: { dismiss() }
                )
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView(
                    selectedDate: selectedDate,
                    recipeMode: false,
                    defaultMeal: meal,
                    onFoodPrepared: nil
                ) { dismiss() }
            }
            .sheet(isPresented: $showLabelScan) {
                LabelCaptureView(
                    barcode: scannedBarcode,
                    selectedDate: selectedDate,
                    defaultMeal: meal
                ) { dismiss() }
            }
            .sheet(isPresented: $showRecipes) {
                RecipeListView(
                    selectedDate: selectedDate,
                    defaultMeal: meal
                ) { dismiss() }
            }
            .sheet(item: $recipeToLog) { recipe in
                NavigationStack {
                    let amount = DiaryService.loggingAmount(for: recipe, context: context)
                    LogRecipeView(
                        recipe: recipe,
                        defaultMeal: meal,
                        date: selectedDate,
                        initialQuantity: amount.quantity,
                        initialUnit: amount.unit,
                        initialOverrides: amount.recipeOverrides
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
            let amount = DiaryService.loggingAmount(for: prepared, context: context)
            logFoodPresentation = LogFoodPresentation(
                food: prepared,
                defaultMeal: meal,
                quantity: amount.quantity,
                unit: amount.unit
            )
        }
    }

    private func quickAdd(_ food: Food) {
        withAnimation {
            justAddedIDs.insert(food.id)
        }
        Task { @MainActor in
            let prepared = await FoodService.prepareForLogging(food, context: context)
            let amount = DiaryService.loggingAmount(for: prepared, context: context)
            DiaryService.addEntry(
                food: prepared,
                quantity: amount.quantity,
                unit: amount.unit,
                meal: meal,
                date: selectedDate,
                context: context
            )
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation {
                justAddedIDs.remove(food.id)
            }
        }
    }

    private func quickAdd(_ recipe: Recipe) {
        withAnimation {
            justAddedIDs.insert(recipe.id)
        }
        let amount = DiaryService.loggingAmount(for: recipe, context: context)
        DiaryService.addEntry(
            recipe: recipe,
            quantity: amount.quantity,
            unit: amount.unit,
            meal: meal,
            date: selectedDate,
            context: context,
            adjustableOverrides: amount.recipeOverrides
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation {
                justAddedIDs.remove(recipe.id)
            }
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

    init(
        food: Food,
        defaultMeal: MealCategory,
        date: Date,
        initialQuantity: Double? = nil,
        initialUnit: ServingUnitType? = nil,
        onDone: @escaping () -> Void
    ) {
        self.food = food
        self.date = date
        self.onDone = onDone
        _meal = State(initialValue: defaultMeal)

        let fallback = food.defaultLoggingAmount()
        let unit = initialUnit.flatMap { food.availableServingUnits.contains($0) ? $0 : nil } ?? fallback.unit
        _unit = State(initialValue: unit)
        _quantity = State(initialValue: initialQuantity ?? fallback.quantity)
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
    /// When non-nil, shows “Adjustable when logging” for recipe ingredients.
    var isAdjustableAtLog: Binding<Bool>? = nil
    var embedsNavigation: Bool = true
    let onConfirm: (Double, ServingUnitType) -> Void

    @State private var quantity: Double
    @State private var unit: ServingUnitType

    init(
        food: Food,
        title: String = "Add Ingredient",
        confirmTitle: String = "Add",
        initialQuantity: Double? = nil,
        initialUnit: ServingUnitType? = nil,
        isAdjustableAtLog: Binding<Bool>? = nil,
        embedsNavigation: Bool = true,
        onConfirm: @escaping (Double, ServingUnitType) -> Void
    ) {
        self.food = food
        self.title = title
        self.confirmTitle = confirmTitle
        self.initialQuantity = initialQuantity
        self.initialUnit = initialUnit
        self.isAdjustableAtLog = isAdjustableAtLog
        self.embedsNavigation = embedsNavigation
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
        if embedsNavigation {
            NavigationStack { form }
        } else {
            form
        }
    }

    private var form: some View {
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
            if let isAdjustableAtLog {
                Section {
                    Toggle("Adjustable when logging", isOn: isAdjustableAtLog)
                } footer: {
                    Text("You’ll be able to enter the exact full-recipe amount of this ingredient each time you log the recipe.")
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

struct EditLogEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let entry: LogEntry
    @State private var quantity: Double
    @State private var unit: ServingUnitType
    @State private var meal: MealCategory
    @State private var adjustableDrafts: [AdjustableIngredientDraft] = []

    init(entry: LogEntry) {
        self.entry = entry
        _quantity = State(initialValue: entry.quantity)
        _unit = State(initialValue: entry.servingUnit)
        _meal = State(initialValue: entry.mealCategory)
    }

    private var recipe: Recipe? { entry.recipe }

    private var overrides: [UUID: (quantity: Double, unit: ServingUnitType)] {
        Dictionary(uniqueKeysWithValues: adjustableDrafts.map { draft in
            (draft.id, (draft.quantity, draft.unit))
        })
    }

    private var availableUnits: [ServingUnitType] {
        if let food = entry.food {
            return food.availableServingUnits
        }
        if let recipe {
            return recipe.availableServingUnits(overrides: overrides)
        }
        return [entry.servingUnit]
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
                if let recipe {
                    quantity = recipe.convertedQuantity(quantity, from: unit, to: newUnit, overrides: overrides)
                } else {
                    let range = ServingConverter.quantityRange(for: newUnit)
                    quantity = min(max(quantity, range.lowerBound), range.upperBound)
                }
                unit = newUnit
            }
        )
    }

    private var liveMacros: MacroTotals {
        if let recipe {
            return recipe.macros(for: quantity, unit: unit, overrides: overrides)
        }
        if let food = entry.food {
            return food.macros(for: quantity, unit: unit)
        }
        return MacroTotals(
            calories: entry.snapshotCaloriesPerQuantity * quantity,
            protein: entry.snapshotProteinPerQuantity * quantity,
            carbs: entry.snapshotCarbsPerQuantity * quantity,
            fat: entry.snapshotFatPerQuantity * quantity
        )
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
                    title: quantityTitle,
                    value: $quantity,
                    range: quantityRange,
                    step: quantityStep,
                    format: unit == .grams ? "%.0f" : "%g"
                )
                if entry.isOrphanedSnapshot {
                    Text("This item was deleted; only meal and quantity can be edited.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if entry.food != nil || recipe != nil {
                    Picker("Unit", selection: unitBinding) {
                        ForEach(availableUnits, id: \.self) { u in
                            Text(unitLabel(for: u)).tag(u)
                        }
                    }
                }
                if let recipe {
                    RecipeAdjustableIngredientsSection(
                        recipe: recipe,
                        drafts: $adjustableDrafts
                    )
                }
                Section("Macros") {
                    LabeledContent("Calories", value: "\(Int(liveMacros.calories))")
                    LabeledContent("Protein", value: "\(liveMacros.protein.formatted())g")
                    LabeledContent("Carbs", value: "\(liveMacros.carbs.formatted())g")
                    LabeledContent("Fat", value: "\(liveMacros.fat.formatted())g")
                }
            }
            .adjustableIngredientDestination(drafts: $adjustableDrafts)
            .onChange(of: availableUnits) { _, units in
                if !units.contains(unit) {
                    unit = units.first ?? .serving
                }
            }
            .navigationTitle("Edit Entry")
            .keyboardDismissToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                if let recipe, adjustableDrafts.isEmpty {
                    adjustableDrafts = AdjustableIngredientDraft.drafts(
                        from: recipe,
                        stored: entry.recipeOverrideMap
                    )
                }
            }
        }
    }

    private var quantityTitle: String {
        if let recipe {
            return "Quantity (\(recipe.unitLabel(for: unit, overrides: overrides)))"
        }
        if let food = entry.food {
            return "Quantity (\(ServingConverter.servingLabel(for: unit, food: food)))"
        }
        return "Quantity"
    }

    private func unitLabel(for unit: ServingUnitType) -> String {
        if let recipe {
            return recipe.unitLabel(for: unit, overrides: overrides)
        }
        if let food = entry.food {
            return ServingConverter.servingLabel(for: unit, food: food)
        }
        return unit.displayName
    }

    private func save() {
        if let recipe {
            DiaryService.updateRecipeEntry(
                entry,
                recipe: recipe,
                quantity: quantity,
                unit: unit,
                meal: meal,
                adjustableOverrides: overrides,
                context: context
            )
        } else {
            entry.quantity = quantity
            entry.servingUnit = unit
            entry.mealCategory = meal
            try? context.save()
        }
        dismiss()
    }
}
