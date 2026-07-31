import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RecipeListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let selectedDate: Date
    let defaultMeal: MealCategory
    let onDone: () -> Void

    @State private var showCreate = false
    @State private var showURLImport = false
    @State private var recipeToDuplicate: Recipe?
    @State private var recipeToDelete: Recipe?

    var body: some View {
        NavigationStack {
            List {
                ForEach(FoodService.allRecipes(context: context)) { recipe in
                    NavigationLink(recipe.name) {
                        RecipeDetailView(
                            recipe: recipe,
                            selectedDate: selectedDate,
                            defaultMeal: defaultMeal,
                            onDone: onDone
                        )
                    }
                    .contextMenu {
                        Button("Duplicate & Edit") {
                            recipeToDuplicate = recipe
                        }
                        NavigationLink("Edit") {
                            RecipeEditorView(existingRecipe: recipe)
                        }
                        Button("Delete", role: .destructive) {
                            recipeToDelete = recipe
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            recipeToDelete = recipe
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: deleteRecipesAtOffsets)
            }
            .navigationTitle("Recipes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import URL") { showURLImport = true }
                    Button("New") { showCreate = true }
                }
            }
            .sheet(isPresented: $showCreate) {
                RecipeEditorView()
            }
            .sheet(isPresented: $showURLImport) {
                RecipeURLImportView(
                    selectedDate: selectedDate,
                    defaultMeal: defaultMeal,
                    onFinished: {
                        dismiss()
                        onDone()
                    }
                )
            }
            .sheet(item: $recipeToDuplicate) { recipe in
                RecipeEditorView(
                    existingRecipe: FoodService.duplicateRecipe(recipe, newName: "\(recipe.name) Copy", context: context)
                )
            }
            .confirmationDialog(
                "Delete Recipe?",
                isPresented: Binding(
                    get: { recipeToDelete != nil },
                    set: { if !$0 { recipeToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let recipeToDelete {
                        FoodService.deleteRecipe(recipeToDelete, context: context)
                    }
                    recipeToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    recipeToDelete = nil
                }
            } message: {
                if let recipeToDelete {
                    Text("\"\(recipeToDelete.name)\" will be permanently deleted. Past diary entries will be kept with their logged nutrition.")
                }
            }
        }
    }

    private func deleteRecipesAtOffsets(_ offsets: IndexSet) {
        let recipes = FoodService.allRecipes(context: context)
        for index in offsets {
            FoodService.deleteRecipe(recipes[index], context: context)
        }
    }
}

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe
    let selectedDate: Date
    let defaultMeal: MealCategory
    let onDone: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            Section("Per serving") {
                let m = recipe.macrosPerServing
                LabeledContent("Calories", value: "\(Int(m.calories))")
                LabeledContent("Protein", value: "\(m.protein.formatted())g")
                LabeledContent("Carbs", value: "\(m.carbs.formatted())g")
                LabeledContent("Fat", value: "\(m.fat.formatted())g")
            }
            Section("Ingredients") {
                ForEach(recipe.ingredients) { ing in
                    HStack {
                        Text(ing.food?.displayName ?? "?")
                        Spacer()
                        if let food = ing.food {
                            Text("\(ing.quantity.formatted()) \(ServingConverter.servingLabel(for: ing.servingUnit, food: food))")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(ing.quantity.formatted()) \(ing.servingUnit.displayName)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            NavigationLink("Log This Recipe") {
                LogRecipeView(
                    recipe: recipe,
                    defaultMeal: defaultMeal,
                    date: selectedDate,
                    onDone: onDone
                )
            }
            NavigationLink("Edit Recipe") {
                RecipeEditorView(existingRecipe: recipe)
            }
            Section {
                Button("Delete Recipe", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .navigationTitle(recipe.name)
        .confirmationDialog("Delete Recipe?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                FoodService.deleteRecipe(recipe, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(recipe.name)\" will be permanently deleted. Past diary entries will be kept with their logged nutrition.")
        }
    }
}

struct RecipeEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var existingRecipe: Recipe?
    @State private var name = ""
    @State private var servings = 1.0
    @State private var recipe: Recipe?
    @State private var showFoodPicker = false
    @State private var editingIngredient: RecipeIngredient?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Recipe Name", text: $name)
                NumericStepperField(title: "Servings", value: $servings, range: 0.01...50, step: 0.25, format: "%g")
                if let recipe {
                    Section("Ingredients") {
                        ForEach(recipe.ingredients) { ingredient in
                            Button {
                                editingIngredient = ingredient
                            } label: {
                                HStack {
                                    Text(ingredient.food?.displayName ?? "?")
                                    Spacer()
                                    if let food = ingredient.food {
                                        Text("\(RecipeServingsScaler.formatQuantity(ingredient.quantity)) \(ServingConverter.servingLabel(for: ingredient.servingUnit, food: food))")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("\(RecipeServingsScaler.formatQuantity(ingredient.quantity)) \(ingredient.servingUnit.displayName)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { indexSet in
                            for i in indexSet { context.delete(recipe.ingredients[i]) }
                            try? context.save()
                        }
                    }
                    let macros = recipe.macrosPerServing
                    Section("Per Serving") {
                        LabeledContent("Calories", value: "\(Int(macros.calories))")
                        LabeledContent("Protein", value: "\(macros.protein.formatted())g")
                        LabeledContent("Carbs", value: "\(macros.carbs.formatted())g")
                        LabeledContent("Fat", value: "\(macros.fat.formatted())g")
                    }
                }
                if existingRecipe != nil {
                    Section {
                        Button("Delete Recipe", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .navigationTitle(existingRecipe == nil ? "New Recipe" : "Edit Recipe")
            .keyboardDismissToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Ingredient") {
                        ensureRecipe()
                        showFoodPicker = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty)
                }
            }
            .sheet(isPresented: $showFoodPicker) {
                if let recipe {
                    RecipeIngredientAddView(recipe: recipe)
                }
            }
            .sheet(item: $editingIngredient) { ingredient in
                if let food = ingredient.food {
                    FoodQuantitySheet(
                        food: food,
                        title: "Edit Ingredient",
                        confirmTitle: "Save",
                        initialQuantity: ingredient.quantity,
                        initialUnit: ingredient.servingUnit
                    ) { quantity, unit in
                        ingredient.quantity = quantity
                        ingredient.servingUnit = unit
                        try? context.save()
                    }
                }
            }
            .onAppear {
                if let existingRecipe {
                    recipe = existingRecipe
                    name = existingRecipe.name
                    servings = existingRecipe.servings
                }
            }
            .confirmationDialog("Delete Recipe?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let existingRecipe {
                        FoodService.deleteRecipe(existingRecipe, context: context)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This recipe will be permanently deleted. Past diary entries will be kept with their logged nutrition.")
            }
        }
    }

    private func ensureRecipe() {
        if recipe == nil {
            let r = Recipe(name: name.isEmpty ? "Recipe" : name, servings: servings)
            context.insert(r)
            recipe = r
        }
    }

    private func save() {
        if let recipe {
            recipe.name = name
            recipe.servings = servings
        } else {
            context.insert(Recipe(name: name, servings: servings))
        }
        try? context.save()
        dismiss()
    }
}

enum RecipeServingsScaler {
    static func factor(from oldValue: Double, to newValue: Double) -> Double? {
        guard oldValue > 0, newValue > 0 else { return nil }
        let factor = newValue / oldValue
        guard abs(factor - 1) > 0.000_001 else { return nil }
        return factor
    }

    static func scale(_ quantity: Double, by factor: Double) -> Double {
        let scaled = quantity * factor
        let rounded = (scaled * 1000).rounded() / 1000
        return max(rounded, 0.01)
    }

    static func formatQuantity(_ quantity: Double) -> String {
        quantity.formatted()
    }
}

struct RecipeIngredientAddView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe

    @State private var selectedTab: FoodSearchTab = .all
    @State private var query = ""
    @State private var isPreparingFood = false
    @State private var quantityPresentation: FoodQuantityPresentation?
    @State private var showScanner = false
    @State private var showLabelScan = false
    @State private var showCustomFood = false

    var body: some View {
        NavigationStack {
            FoodBrowserView(selectedTab: $selectedTab, query: $query) { food in
                prepareIngredient(food)
            }
            .navigationTitle("Add Ingredient")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Scan Barcode") { showScanner = true }
                        Button("Scan Nutrition Label") { showLabelScan = true }
                        Button("Custom Food") { showCustomFood = true }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .overlay {
                if isPreparingFood {
                    ProgressView("Loading...")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(item: $quantityPresentation) { presentation in
                FoodQuantitySheet(food: presentation.food) { quantity, unit in
                    addIngredient(food: presentation.food, quantity: quantity, unit: unit)
                    dismiss()
                }
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView(
                    selectedDate: Date(),
                    recipeMode: true,
                    onFoodPrepared: { food, quantity, unit in
                        addIngredient(food: food, quantity: quantity, unit: unit)
                        dismiss()
                    },
                    onDone: { dismiss() }
                )
            }
            .sheet(isPresented: $showLabelScan) {
                LabelCaptureView(
                    barcode: nil,
                    selectedDate: Date(),
                    defaultMeal: .uncategorized,
                    logImmediately: false,
                    onFoodSaved: { food in
                        showLabelScan = false
                        prepareIngredient(food)
                    },
                    onDone: {}
                )
            }
            .sheet(isPresented: $showCustomFood) {
                CustomFoodFormView(
                    barcode: nil,
                    logImmediately: false,
                    onFoodSaved: { food in
                        showCustomFood = false
                        prepareIngredient(food)
                    },
                    onDone: {}
                )
            }
        }
    }

    private func prepareIngredient(_ food: Food) {
        Task {
            isPreparingFood = true
            let prepared = await FoodService.prepareForLogging(food, context: context)
            isPreparingFood = false
            quantityPresentation = FoodQuantityPresentation(food: prepared)
        }
    }

    private func addIngredient(food: Food, quantity: Double, unit: ServingUnitType) {
        let cached = food.source == .custom ? food : FoodService.cacheFood(food, context: context)
        let ingredient = RecipeIngredient(food: cached, quantity: quantity, servingUnit: unit)
        ingredient.recipe = recipe
        recipe.ingredients.append(ingredient)
        context.insert(ingredient)
        try? context.save()
    }
}

struct RecipeURLImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var selectedDate: Date = Date()
    var defaultMeal: MealCategory = .uncategorized
    /// Called after any successful save so the diary flow can close outer sheets.
    var onFinished: (() -> Void)? = nil

    @State private var urlText = ""
    @State private var recipeText = ""
    @State private var fetchedSourceText = ""
    @State private var fetchedSourceURL: String?
    @State private var replyText = ""
    @State private var displayedPrompt = ""
    @State private var isLoading = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var promptCopied = false
    @State private var parsed: ParsedWebRecipe?
    @State private var hasAPIKey = AIAssistant.hasConfiguredKey

    private var hasSource: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !recipeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !fetchedSourceText.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://...", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextEditor(text: $recipeText)
                        .frame(minHeight: 100)
                } header: {
                    Text("Recipe source")
                } footer: {
                    Text("Paste a recipe URL and/or the recipe text. When a URL is provided, the page is fetched automatically.")
                }

                if hasAPIKey {
                    Section {
                        Button {
                            Task { await importWithAI() }
                        } label: {
                            Label(
                                isLoading ? "Importing…" : "Import with AI",
                                systemImage: "sparkles"
                            )
                        }
                        .disabled(!hasSource || isLoading)
                        if isLoading, !statusMessage.isEmpty {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("In-app import")
                    } footer: {
                        Text("Uses your AI API key from Settings. Ingredients are matched to your foods / USDA afterward — review before saving.")
                    }
                } else {
                    Section {
                        Text("Add an AI API key in Settings to import in-app. You can still use the clipboard flow below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("1. Add a URL and/or recipe text above.")
                    Text("2. Copy the prompt and paste it into your AI app.")
                    Text("3. Copy the AI reply, paste it below, then import.")
                } header: {
                    Text(hasAPIKey ? "Clipboard fallback" : "How it works")
                } footer: {
                    Text("The AI should reply with JSON. Review matched ingredients before saving.")
                }

                Section("Prompt") {
                    if displayedPrompt.isEmpty {
                        Text("Tap Copy Prompt to build the full prompt from your source (fetches the URL when needed).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(displayedPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button {
                        Task { await prepareAndCopyPrompt() }
                    } label: {
                        Label(
                            promptCopied ? "Prompt Copied" : "Copy Prompt",
                            systemImage: promptCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(!hasSource || isLoading)
                }

                Section {
                    TextEditor(text: $replyText)
                        .frame(minHeight: 120)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first {
                            replyText = first
                        }
                    }
                    .buttonBorderShape(.capsule)
                    Button {
                        Task { await importFromReply() }
                    } label: {
                        Label("Import Reply", systemImage: "square.and.arrow.down")
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                } header: {
                    Text("AI Reply")
                } footer: {
                    Text("You can paste the whole AI reply — it doesn’t have to be JSON-only.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.caption)
                    }
                }

                if parsed != nil {
                    Section {
                        NavigationLink("Review Ingredients") {
                            if let parsed {
                                RecipeImportReviewView(
                                    parsed: parsed,
                                    selectedDate: selectedDate,
                                    defaultMeal: defaultMeal,
                                    onFinished: { _ in
                                        dismiss()
                                        onFinished?()
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .disabled(isLoading && hasAPIKey)
            .overlay {
                if isLoading, hasAPIKey {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(statusMessage.isEmpty ? "Importing with AI…" : statusMessage)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .onAppear {
                hasAPIKey = AIAssistant.hasConfiguredKey
            }
        }
    }

    private func resolveSourceText() async throws -> (text: String, url: String?) {
        let pasted = recipeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !urlString.isEmpty {
            statusMessage = "Fetching page…"
            let page = try await RecipeURLImporter.fetchPageText(from: urlString)
            fetchedSourceText = page.text
            fetchedSourceURL = page.url.absoluteString
            if pasted.isEmpty {
                return (page.text, page.url.absoluteString)
            }
            return (page.text + "\n\n---\nUser-provided recipe text:\n" + pasted, page.url.absoluteString)
        }

        if !pasted.isEmpty {
            fetchedSourceText = pasted
            fetchedSourceURL = nil
            return (pasted, nil)
        }

        if !fetchedSourceText.isEmpty {
            return (fetchedSourceText, fetchedSourceURL)
        }

        throw RecipeURLImporter.ImportError.noSource
    }

    private func importWithAI() async {
        guard AIAssistant.hasConfiguredKey else {
            errorMessage = AIAssistant.AssistantError.missingAPIKey.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        parsed = nil
        defer {
            isLoading = false
            statusMessage = ""
        }
        do {
            let source = try await resolveSourceText()
            statusMessage = "Sending to AI…"
            let draft = try await AIAssistant.importRecipe(
                sourceText: source.text,
                sourceURL: source.url,
                onStatus: { status in
                    Task { @MainActor in
                        statusMessage = status
                    }
                }
            )
            statusMessage = "Matching ingredients…"
            parsed = await AIRecipeImportService.matchIngredients(draft, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareAndCopyPrompt() async {
        isLoading = true
        errorMessage = nil
        promptCopied = false
        defer {
            isLoading = false
            statusMessage = ""
        }
        do {
            let source = try await resolveSourceText()
            let prompt = AIRecipeImportService.prompt(sourceText: source.text, sourceURL: source.url)
            displayedPrompt = prompt
            AIRecipeImportService.copyPromptToClipboard(sourceText: source.text, sourceURL: source.url)
            promptCopied = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFromReply() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            statusMessage = ""
        }
        do {
            let draft = try AIRecipeImportService.parse(replyText)
            statusMessage = "Matching ingredients…"
            parsed = await AIRecipeImportService.matchIngredients(draft, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecipeImportLineRequest {
    let index: Int
    let suggestedQuery: String
}

private enum RecipeImportIngredientSheet: Identifiable {
    case resolve(RecipeImportLineRequest)
    case customFood(RecipeImportLineRequest)

    var id: String {
        switch self {
        case .resolve(let request):
            return "resolve-\(request.index)"
        case .customFood(let request):
            return "custom-\(request.index)"
        }
    }

    var debugName: String {
        switch self {
        case .resolve(let request):
            return "resolve(index=\(request.index), query=\(request.suggestedQuery))"
        case .customFood(let request):
            return "customFood(index=\(request.index), query=\(request.suggestedQuery))"
        }
    }
}

private enum RecipeImportDebug {
    static func log(_ message: String) {
        print("[RecipeImport] \(message)")
    }
}

struct RecipeImportReviewView: View {
    @Environment(\.modelContext) private var context
    @State var parsed: ParsedWebRecipe
    let selectedDate: Date
    let defaultMeal: MealCategory
    /// `true` when the recipe was also logged to the diary.
    let onFinished: (Bool) -> Void

    @State private var servings: Double
    @State private var logServings = 1.0
    @State private var meal: MealCategory
    @State private var ingredientSheet: RecipeImportIngredientSheet?

    init(
        parsed: ParsedWebRecipe,
        selectedDate: Date,
        defaultMeal: MealCategory,
        onFinished: @escaping (Bool) -> Void
    ) {
        self.selectedDate = selectedDate
        self.defaultMeal = defaultMeal
        self.onFinished = onFinished
        _parsed = State(initialValue: parsed)
        _servings = State(initialValue: parsed.servings)
        _meal = State(initialValue: defaultMeal)
    }

    private var canSave: Bool {
        !parsed.name.isEmpty && !parsed.ingredients.isEmpty && parsed.ingredients.allSatisfy(\.isResolved)
    }

    var body: some View {
        Form {
            TextField("Recipe Name", text: $parsed.name)
            Section {
                NumericStepperField(title: "Recipe servings", value: $servings, range: 0.01...50, step: 0.25, format: "%g")
            } footer: {
                Text("Yield for this batch. Changing it scales every ingredient amount to match.")
            }

            Section {
                Picker("Meal", selection: $meal) {
                    ForEach(MealCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                NumericStepperField(title: "Servings to log", value: $logServings, range: 0.01...20, step: 0.25, format: "%g")
            } header: {
                Text("Log")
            } footer: {
                Text("Used only for Save & Log. Save Only stores the recipe without adding a diary entry.")
            }

            Section("Ingredients") {
                ForEach(Array(parsed.ingredients.indices), id: \.self) { index in
                    let item = parsed.ingredients[index]
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if item.isUncertain || item.food == nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Text(item.rawText)
                                .font(.subheadline)
                        }
                        HStack {
                            if let food = item.food {
                                Text(food.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(RecipeServingsScaler.formatQuantity(item.quantity)) \(item.servingUnit.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                let query = suggestedQuery(for: item)
                                RecipeImportDebug.log("TAP Resolve index=\(index) query=\(query)")
                                ingredientSheet = .resolve(
                                    RecipeImportLineRequest(index: index, suggestedQuery: query)
                                )
                                RecipeImportDebug.log("SET ingredientSheet → \(ingredientSheet?.debugName ?? "nil")")
                            } label: {
                                Label("Resolve", systemImage: "magnifyingglass")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)

                            Button {
                                let query = suggestedQuery(for: item)
                                RecipeImportDebug.log("TAP Custom Food index=\(index) query=\(query)")
                                ingredientSheet = .customFood(
                                    RecipeImportLineRequest(index: index, suggestedQuery: query)
                                )
                                RecipeImportDebug.log("SET ingredientSheet → \(ingredientSheet?.debugName ?? "nil")")
                            } label: {
                                Label("Custom Food", systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                RecipeImportDebug.log("TAP Remove index=\(index)")
                                parsed.ingredients.remove(at: index)
                            } label: {
                                Label("Remove", systemImage: "trash")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.subheadline)
                    }
                }
            }

            if !canSave {
                Text("Resolve or remove all uncertain ingredients before saving.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Review Import")
        .keyboardDismissToolbar()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save & Log") { saveRecipe(logAfterSave: true) }
                    .disabled(!canSave)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Save Only") { saveRecipe(logAfterSave: false) }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            RecipeImportDebug.log("ReviewImport appeared ingredients=\(parsed.ingredients.count)")
        }
        .onChange(of: servings) { oldValue, newValue in
            guard let factor = RecipeServingsScaler.factor(from: oldValue, to: newValue) else { return }
            for index in parsed.ingredients.indices {
                parsed.ingredients[index].quantity = RecipeServingsScaler.scale(
                    parsed.ingredients[index].quantity,
                    by: factor
                )
            }
            parsed.servings = max(newValue, 0.01)
        }
        .onChange(of: ingredientSheet?.id) { oldId, newId in
            RecipeImportDebug.log("ingredientSheet id change \(oldId ?? "nil") → \(newId ?? "nil") (\(ingredientSheet?.debugName ?? "nil"))")
        }
        .sheet(item: $ingredientSheet) { sheet in
            let _ = RecipeImportDebug.log("SHEET BODY building for \(sheet.debugName)")
            switch sheet {
            case .resolve(let request):
                RecipeIngredientResolvePicker(initialQuery: request.suggestedQuery) { food in
                    RecipeImportDebug.log("ResolvePicker SELECT food=\(food.displayName) index=\(request.index)")
                    applyResolvedFood(food, at: request.index)
                    RecipeImportDebug.log("ResolvePicker clearing sheet after select")
                    ingredientSheet = nil
                }
                .onAppear {
                    RecipeImportDebug.log("ResolvePicker APPEARED index=\(request.index) query=\(request.suggestedQuery)")
                }
                .onDisappear {
                    RecipeImportDebug.log("ResolvePicker DISAPPEARED index=\(request.index)")
                }
            case .customFood(let request):
                CustomFoodFormView(
                    barcode: nil,
                    logImmediately: false,
                    onFoodSaved: { food in
                        RecipeImportDebug.log("CustomFood onFoodSaved food=\(food.displayName) index=\(request.index)")
                        applyResolvedFood(food, at: request.index)
                        ingredientSheet = nil
                    },
                    onDone: {
                        RecipeImportDebug.log("CustomFood onDone index=\(request.index)")
                        ingredientSheet = nil
                    }
                )
                .onAppear {
                    RecipeImportDebug.log("CustomFood SHEET APPEARED index=\(request.index) — if you tapped Resolve, this is the bug")
                }
                .onDisappear {
                    RecipeImportDebug.log("CustomFood SHEET DISAPPEARED index=\(request.index)")
                }
            }
        }
    }

    private func applyResolvedFood(_ food: Food, at index: Int) {
        RecipeImportDebug.log("applyResolvedFood index=\(index) food=\(food.displayName)")
        guard parsed.ingredients.indices.contains(index) else {
            RecipeImportDebug.log("applyResolvedFood FAILED — index out of range")
            return
        }
        parsed.ingredients[index].food = food
        parsed.ingredients[index].isUncertain = false
    }

    private func suggestedQuery(for item: RecipeImportIngredient) -> String {
        let search = item.searchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty { return search }
        if let name = item.food?.name, !name.isEmpty { return name }
        return item.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveRecipe(logAfterSave: Bool) {
        let recipe = Recipe(name: parsed.name, servings: servings)
        context.insert(recipe)
        for item in parsed.ingredients {
            guard let food = item.food else { continue }
            let cached = FoodService.cacheFood(food, context: context)
            let ing = RecipeIngredient(food: cached, quantity: item.quantity, servingUnit: item.servingUnit)
            ing.recipe = recipe
            recipe.ingredients.append(ing)
            context.insert(ing)
        }
        try? context.save()

        if logAfterSave {
            DiaryService.addEntry(
                recipe: recipe,
                quantity: logServings,
                meal: meal,
                date: selectedDate,
                context: context
            )
        }
        onFinished(logAfterSave)
    }
}

struct RecipeIngredientResolvePicker: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Food) -> Void
    @State private var selectedTab: FoodSearchTab = .all
    @State private var query: String

    init(initialQuery: String = "", onSelect: @escaping (Food) -> Void) {
        self.onSelect = onSelect
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            FoodBrowserView(selectedTab: $selectedTab, query: $query) { food in
                Task { @MainActor in
                    RecipeImportDebug.log("ResolvePicker prepareForLogging start food=\(food.displayName)")
                    let prepared = await FoodService.prepareForLogging(food, context: context)
                    RecipeImportDebug.log("ResolvePicker prepareForLogging done food=\(prepared.displayName)")
                    onSelect(prepared)
                    dismiss()
                }
            }
            .navigationTitle("Match Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        RecipeImportDebug.log("ResolvePicker Cancel tapped")
                        dismiss()
                    }
                }
            }
            .onAppear {
                RecipeImportDebug.log("ResolvePicker root onAppear query=\(query)")
            }
        }
    }
}

struct LogRecipeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe
    let date: Date
    let onDone: () -> Void

    @State private var servings = 1.0
    @State private var meal: MealCategory

    init(recipe: Recipe, defaultMeal: MealCategory, date: Date, onDone: @escaping () -> Void) {
        self.recipe = recipe
        self.date = date
        self.onDone = onDone
        _meal = State(initialValue: defaultMeal)
    }

    private var totalMacros: MacroTotals {
        let perServing = recipe.macrosPerServing
        return MacroTotals(
            calories: perServing.calories * servings,
            protein: perServing.protein * servings,
            carbs: perServing.carbs * servings,
            fat: perServing.fat * servings
        )
    }

    var body: some View {
        Form {
            Picker("Meal", selection: $meal) {
                ForEach(MealCategory.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            NumericStepperField(title: "Servings", value: $servings, range: 0.01...20, step: 0.25, format: "%g")
            Section("Macros") {
                LabeledContent("Calories", value: "\(Int(totalMacros.calories))")
                LabeledContent("Protein", value: "\(totalMacros.protein.formatted())g")
                LabeledContent("Carbs", value: "\(totalMacros.carbs.formatted())g")
                LabeledContent("Fat", value: "\(totalMacros.fat.formatted())g")
            }
        }
        .navigationTitle("Log Food")
        .keyboardDismissToolbar()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Log") {
                    DiaryService.addEntry(recipe: recipe, quantity: servings, meal: meal, date: date, context: context)
                    dismiss()
                    onDone()
                }
            }
        }
    }
}

struct CSVImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Import foods from CSV with columns: name, brand, barcode, serving_grams, serving_description, calories, protein, carbs, fat, is_alcohol")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                Button("Choose CSV File") { showImporter = true }
                if !message.isEmpty { Text(message) }
                Spacer()
            }
            .navigationTitle("Import CSV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url),
                       let csv = String(data: data, encoding: .utf8) {
                        importCSV(csv)
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    private func importCSV(_ csv: String) {
        do {
            let foods = try CSVImporter.parseFoods(from: csv)
            for item in foods {
                _ = FoodService.saveCustomFood(
                    name: item.name,
                    brand: item.brand,
                    barcode: item.barcode,
                    serving: FoodService.CustomServingDefinition(
                        amount: item.servingSizeGrams > 0 ? item.servingSizeGrams : nil,
                        unit: .grams,
                        gramWeight: item.servingSizeGrams > 0 ? item.servingSizeGrams : nil,
                        description: item.servingDescription
                    ),
                    calories: item.calories,
                    protein: item.protein,
                    carbs: item.carbs,
                    fat: item.fat,
                    isAlcohol: item.isAlcohol,
                    context: context
                )
            }
            message = "Imported \(foods.count) foods."
        } catch {
            message = error.localizedDescription
        }
    }
}

extension Recipe: Identifiable {}
