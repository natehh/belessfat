import SwiftUI
import SwiftData

private enum FoodLibrarySegment: String, CaseIterable, Identifiable {
    case foods
    case recipes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .foods: return "Foods"
        case .recipes: return "Recipes"
        }
    }
}

struct FoodLibraryView: View {
    @Environment(\.modelContext) private var context
    @State private var segment: FoodLibrarySegment = .foods
    @State private var query = ""
    @State private var showCreateFood = false
    @State private var showCreateRecipe = false
    @State private var showURLImport = false
    @State private var foodToDelete: Food?
    @State private var recipeToDelete: Recipe?
    @State private var recipeToDuplicate: Recipe?

    private var foods: [Food] {
        FoodService.searchCustomFoods(query: query, context: context)
    }

    private var recipes: [Recipe] {
        FoodService.searchRecipes(query: query, context: context)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $segment) {
                    ForEach(FoodLibrarySegment.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    switch segment {
                    case .foods:
                        foodsContent
                    case .recipes:
                        recipesContent
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Library")
            .searchable(
                text: $query,
                prompt: segment == .foods ? "Search custom foods" : "Search recipes"
            )
            #if DEBUG
            .onAppear {
                if AppStoreScreenshotSeeder.isEnabled,
                   AppStoreScreenshotSeeder.requestedScreen == "recipes" {
                    segment = .recipes
                }
            }
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if segment == .recipes {
                        Button("Import URL") { showURLImport = true }
                    }
                    Menu {
                        Button("New Custom Food") { showCreateFood = true }
                        Button("New Recipe") { showCreateRecipe = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateFood) {
                CustomFoodFormView(barcode: nil, logImmediately: false, onDone: {})
            }
            .sheet(isPresented: $showCreateRecipe) {
                RecipeEditorView()
            }
            .sheet(isPresented: $showURLImport) {
                RecipeURLImportView()
            }
            .sheet(item: $recipeToDuplicate) { recipe in
                RecipeEditorView(
                    existingRecipe: FoodService.duplicateRecipe(
                        recipe,
                        newName: "\(recipe.name) Copy",
                        context: context
                    )
                )
            }
            .confirmationDialog(
                "Delete Custom Food?",
                isPresented: Binding(
                    get: { foodToDelete != nil },
                    set: { if !$0 { foodToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let foodToDelete {
                        FoodService.deleteCustomFood(foodToDelete, context: context)
                    }
                    foodToDelete = nil
                }
                Button("Cancel", role: .cancel) { foodToDelete = nil }
            } message: {
                if let foodToDelete {
                    Text("\"\(foodToDelete.displayName)\" will be permanently deleted. Past diary entries will be kept; recipe ingredients using it will be removed.")
                }
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
                Button("Cancel", role: .cancel) { recipeToDelete = nil }
            } message: {
                if let recipeToDelete {
                    Text("\"\(recipeToDelete.name)\" will be permanently deleted. Past diary entries will be kept with their logged nutrition.")
                }
            }
        }
    }

    @ViewBuilder
    private var foodsContent: some View {
        if foods.isEmpty {
            Text(query.isEmpty ? "No custom foods yet." : "No matching foods.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(foods, id: \.id) { food in
                NavigationLink {
                    CustomFoodDetailView(food: food)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(food.displayName)
                        Text(foodLibrarySubtitle(food))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        foodToDelete = food
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recipesContent: some View {
        if recipes.isEmpty {
            Text(query.isEmpty ? "No recipes yet." : "No matching recipes.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(recipes) { recipe in
                NavigationLink {
                    RecipeLibraryDetailView(recipe: recipe)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recipe.name)
                        Text(recipeLibrarySubtitle(recipe))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Duplicate & Edit") { recipeToDuplicate = recipe }
                    Button("Delete", role: .destructive) { recipeToDelete = recipe }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        recipeToDelete = recipe
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func foodLibrarySubtitle(_ food: Food) -> String {
        let serving = ServingConverter.servingLabel(for: .serving, food: food)
        var parts = ["\(Int(food.caloriesPerServing)) kcal / \(serving)"]
        parts.append("P \(Int(food.proteinPerServing)) · C \(Int(food.carbsPerServing)) · F \(Int(food.fatPerServing))")
        if food.servingSizeGrams > 0 {
            parts.append("\(food.servingSizeGrams.formatted(.number.precision(.fractionLength(0...1))))g")
        }
        return parts.joined(separator: " · ")
    }

    private func recipeLibrarySubtitle(_ recipe: Recipe) -> String {
        let m = recipe.macrosPerServing
        let ingredientCount = recipe.ingredients.count
        return "\(Int(m.calories)) kcal/serving · \(ingredientCount) ingredient\(ingredientCount == 1 ? "" : "s") · \(recipe.servings.formatted(.number.precision(.fractionLength(0...2)))) servings"
    }
}

struct CustomFoodDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let food: Food

    @State private var showEdit = false
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            Section("Details") {
                LabeledContent("Name", value: food.name)
                if let brand = food.brand, !brand.isEmpty {
                    LabeledContent("Brand", value: brand)
                }
                if let barcode = food.barcode, !barcode.isEmpty {
                    LabeledContent("Barcode", value: barcode)
                }
                if food.isAlcohol {
                    LabeledContent("Alcohol", value: "Yes")
                }
            }

            Section("Serving") {
                if let description = food.servingDescription, !description.isEmpty {
                    LabeledContent("Description", value: description)
                }
                let serving = FoodService.servingDefinition(from: food)
                if let amount = serving.amount, amount > 0 {
                    LabeledContent("Amount", value: "\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(serving.unit.displayName)")
                }
                if food.servingSizeGrams > 0 {
                    LabeledContent("Weight", value: "\(food.servingSizeGrams.formatted(.number.precision(.fractionLength(0...1)))) g")
                }
                if let tsp = food.teaspoonGrams {
                    LabeledContent("Teaspoon", value: "\(tsp.formatted(.number.precision(.fractionLength(0...1)))) g")
                }
                if let tbsp = food.tablespoonGrams {
                    LabeledContent("Tablespoon", value: "\(tbsp.formatted(.number.precision(.fractionLength(0...1)))) g")
                }
                if let cup = food.cupGrams {
                    LabeledContent("Cup", value: "\(cup.formatted(.number.precision(.fractionLength(0...1)))) g")
                }
            }

            Section("Macros (per serving)") {
                LabeledContent("Calories", value: "\(Int(food.caloriesPerServing))")
                LabeledContent("Protein", value: "\(food.proteinPerServing.formatted(.number.precision(.fractionLength(0...1)))) g")
                LabeledContent("Carbs", value: "\(food.carbsPerServing.formatted(.number.precision(.fractionLength(0...1)))) g")
                LabeledContent("Fat", value: "\(food.fatPerServing.formatted(.number.precision(.fractionLength(0...1)))) g")
            }

            if food.caloriesPer100g > 0 {
                Section("Per 100g") {
                    LabeledContent("Calories", value: "\(Int(food.caloriesPer100g))")
                    LabeledContent("Protein", value: "\(food.proteinPer100g.formatted(.number.precision(.fractionLength(0...1)))) g")
                    LabeledContent("Carbs", value: "\(food.carbsPer100g.formatted(.number.precision(.fractionLength(0...1)))) g")
                    LabeledContent("Fat", value: "\(food.fatPer100g.formatted(.number.precision(.fractionLength(0...1)))) g")
                }
            }

            Section {
                Button("Edit Food") { showEdit = true }
                Button("Delete Food", role: .destructive) { showDeleteConfirm = true }
            }
        }
        .navigationTitle(food.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEdit) {
            CustomFoodFormView(
                barcode: food.barcode,
                existingFood: food,
                logImmediately: false,
                onDone: {}
            )
        }
        .confirmationDialog("Delete Custom Food?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                FoodService.deleteCustomFood(food, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This food will be permanently deleted. Past diary entries will be kept; recipe ingredients using it will be removed.")
        }
    }
}

struct RecipeLibraryDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe

    @State private var showEdit = false
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            Section("Recipe") {
                LabeledContent("Servings", value: recipe.servings.formatted(.number.precision(.fractionLength(0...2))))
                LabeledContent("Ingredients", value: "\(recipe.ingredients.count)")
            }

            Section("Per serving") {
                let m = recipe.macrosPerServing
                LabeledContent("Calories", value: "\(Int(m.calories))")
                LabeledContent("Protein", value: "\(m.protein.formatted(.number.precision(.fractionLength(0...1)))) g")
                LabeledContent("Carbs", value: "\(m.carbs.formatted(.number.precision(.fractionLength(0...1)))) g")
                LabeledContent("Fat", value: "\(m.fat.formatted(.number.precision(.fractionLength(0...1)))) g")
            }

            Section("Total") {
                let m = recipe.totalMacros
                LabeledContent("Calories", value: "\(Int(m.calories))")
                LabeledContent("Protein", value: "\(m.protein.formatted(.number.precision(.fractionLength(0...1)))) g")
                LabeledContent("Carbs", value: "\(m.carbs.formatted(.number.precision(.fractionLength(0...1)))) g")
                LabeledContent("Fat", value: "\(m.fat.formatted(.number.precision(.fractionLength(0...1)))) g")
            }

            Section("Ingredients") {
                if recipe.ingredients.isEmpty {
                    Text("No ingredients")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recipe.ingredients) { ingredient in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ingredient.food?.displayName ?? "Unknown ingredient")
                            HStack {
                                if let food = ingredient.food {
                                    Text("\(ingredient.quantity.formatted(.number.precision(.fractionLength(0...2)))) \(ServingConverter.servingLabel(for: ingredient.servingUnit, food: food))")
                                } else {
                                    Text("\(ingredient.quantity.formatted(.number.precision(.fractionLength(0...2)))) \(ingredient.servingUnit.displayName)")
                                }
                                Spacer()
                                if let food = ingredient.food {
                                    let macros = food.macros(for: ingredient.quantity, unit: ingredient.servingUnit)
                                    Text("\(Int(macros.calories)) kcal")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Edit Recipe") { showEdit = true }
                Button("Delete Recipe", role: .destructive) { showDeleteConfirm = true }
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEdit) {
            RecipeEditorView(existingRecipe: recipe)
        }
        .confirmationDialog("Delete Recipe?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                FoodService.deleteRecipe(recipe, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This recipe will be permanently deleted. Past diary entries will be kept with their logged nutrition.")
        }
    }
}
