import SwiftUI
import SwiftData

struct CustomFoodFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let barcode: String?
    var existingFood: Food?
    var labelPrefill: ParsedLabelNutrition?
    var aiPrefill: AIFoodEstimateResult?
    var logImmediately: Bool = true
    var selectedDate: Date = Date()
    var defaultMeal: MealCategory = .breakfast
    var onFoodSaved: ((Food) -> Void)? = nil
    let onDone: () -> Void

    @State private var name = ""
    @State private var brand = ""
    @State private var servingAmount = ""
    @State private var servingUnit: ServingUnitType = .grams
    @State private var gramWeight = ""
    @State private var servingDesc = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var isAlcohol = false
    @State private var meal: MealCategory = .breakfast
    @State private var showDeleteConfirm = false

    private var isEditing: Bool { existingFood != nil }
    private var navigationTitle: String {
        if isEditing { return "Edit Food" }
        if labelPrefill != nil { return "Review Food" }
        if aiPrefill != nil { return "Review AI Food" }
        return "Custom Food"
    }

    private var usesVolumeUnit: Bool {
        switch servingUnit {
        case .teaspoon, .tablespoon, .cup: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let labelPrefill, !labelPrefill.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(labelPrefill.warnings, id: \.self) { warning in
                            Text(warning).foregroundStyle(.orange)
                        }
                    }
                }
                if aiPrefill != nil {
                    Section {
                        Text("Imported from AI. Review everything before saving — estimates can be wrong.")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Brand (optional)", text: $brand)
                    if let barcode {
                        LabeledContent("Barcode", value: barcode)
                    }
                    Toggle("Alcohol", isOn: $isAlcohol)
                }
                Section {
                    TextField("Serving description", text: $servingDesc, prompt: Text("e.g. 1 plate, 2 cookies"))
                    HStack(alignment: .top, spacing: 12) {
                        OptionalNumericStepperField(
                            title: "Amount",
                            text: $servingAmount,
                            step: usesVolumeUnit ? 0.25 : 1
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unit")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Picker("Unit", selection: $servingUnit) {
                                ForEach(ServingUnitType.customFoodServingUnits, id: \.self) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    if usesVolumeUnit || servingAmount.isEmpty {
                        OptionalNumericStepperField(
                            title: "Weight in grams",
                            text: $gramWeight,
                            suffix: "g",
                            step: 5
                        )
                    }
                } header: {
                    Text("Serving")
                } footer: {
                    if usesVolumeUnit || servingAmount.isEmpty {
                        Text("Leave amount, weight, or both blank if you only know the serving name (e.g. “1 plate”). Macros are always per serving.")
                    } else {
                        Text("Macros below are per this serving. Weight is optional for cups, tsp, and tbsp.")
                    }
                }
                Section("Macros (per serving)") {
                    OptionalNumericStepperField(title: "Calories", text: $calories, step: 5)
                    OptionalNumericStepperField(title: "Protein", text: $protein, suffix: "g", step: 1)
                    OptionalNumericStepperField(title: "Carbs", text: $carbs, suffix: "g", step: 1)
                    OptionalNumericStepperField(title: "Fat", text: $fat, suffix: "g", step: 1)
                }
                if logImmediately {
                    Picker("Meal", selection: $meal) {
                        ForEach(MealCategory.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .keyboardDismissToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if logImmediately {
                        Button("Save & Log") { save(logAfterSave: true) }
                            .disabled(name.isEmpty)
                    } else {
                        Button("Save") { save(logAfterSave: false) }
                            .disabled(name.isEmpty)
                    }
                }
                if logImmediately {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Save Only") { save(logAfterSave: false) }
                            .disabled(name.isEmpty)
                    }
                }
                if isEditing {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete Food", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .confirmationDialog("Delete Custom Food?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    deleteFood()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This food will be permanently deleted. Past diary entries will be kept; recipe ingredients using it will be removed.")
            }
            .onAppear {
                print("[RecipeImport] CustomFoodFormView.onAppear title=\(navigationTitle) nameEmpty=\(name.isEmpty) existing=\(existingFood != nil) ai=\(aiPrefill != nil) label=\(labelPrefill != nil)")
                applyInitialValues()
            }
        }
    }

    private func applyInitialValues() {
        meal = defaultMeal
        if let existingFood {
            name = existingFood.name
            brand = existingFood.brand ?? ""
            let serving = FoodService.servingDefinition(from: existingFood)
            servingUnit = serving.unit
            if let amount = serving.amount {
                servingAmount = String(format: "%g", amount)
            } else {
                servingAmount = ""
            }
            if let weight = serving.gramWeight, weight > 0 {
                gramWeight = String(format: "%g", weight)
            } else {
                gramWeight = ""
            }
            servingDesc = existingFood.servingDescription ?? ""
            calories = String(format: "%g", existingFood.caloriesPerServing)
            protein = String(format: "%g", existingFood.proteinPerServing)
            carbs = String(format: "%g", existingFood.carbsPerServing)
            fat = String(format: "%g", existingFood.fatPerServing)
            isAlcohol = existingFood.isAlcohol
            return
        }
        if let labelPrefill {
            servingDesc = labelPrefill.servingSize
            servingAmount = String(format: "%g", labelPrefill.servingSizeGrams)
            servingUnit = .grams
            gramWeight = String(format: "%g", labelPrefill.servingSizeGrams)
            calories = String(format: "%g", labelPrefill.calories)
            protein = String(format: "%g", labelPrefill.protein)
            carbs = String(format: "%g", labelPrefill.carbs)
            fat = String(format: "%g", labelPrefill.fat)
            return
        }
        if let aiPrefill {
            name = aiPrefill.name
            brand = aiPrefill.brand ?? ""
            servingDesc = aiPrefill.servingDescription ?? ""
            if ServingUnitType.customFoodServingUnits.contains(aiPrefill.servingUnit) {
                servingUnit = aiPrefill.servingUnit
                if let amount = aiPrefill.servingAmount, amount > 0 {
                    servingAmount = String(format: "%g", amount)
                }
            } else {
                servingUnit = .grams
                servingAmount = ""
            }
            if let weight = aiPrefill.gramWeight, weight > 0 {
                gramWeight = String(format: "%g", weight)
            }
            calories = String(format: "%g", aiPrefill.calories)
            protein = String(format: "%g", aiPrefill.protein)
            carbs = String(format: "%g", aiPrefill.carbs)
            fat = String(format: "%g", aiPrefill.fat)
        }
    }

    private func buildServingDefinition() -> FoodService.CustomServingDefinition {
        let amount = Double(servingAmount)
        let weight = Double(gramWeight)
        let hasAmount = amount != nil && (amount ?? 0) > 0
        return FoodService.CustomServingDefinition(
            amount: hasAmount ? amount : nil,
            unit: servingUnit,
            gramWeight: weight != nil && (weight ?? 0) > 0 ? weight : nil,
            description: servingDesc.isEmpty ? nil : servingDesc
        )
    }

    private func save(logAfterSave: Bool) {
        let serving = buildServingDefinition()
        let saved: Food
        if let existingFood {
            saved = FoodService.updateCustomFood(
                existingFood,
                name: name,
                brand: brand.isEmpty ? nil : brand,
                barcode: barcode ?? existingFood.barcode,
                serving: serving,
                calories: Double(calories) ?? 0,
                protein: Double(protein) ?? 0,
                carbs: Double(carbs) ?? 0,
                fat: Double(fat) ?? 0,
                isAlcohol: isAlcohol,
                context: context
            )
        } else {
            saved = FoodService.saveCustomFood(
                name: name,
                brand: brand.isEmpty ? nil : brand,
                barcode: barcode,
                serving: serving,
                calories: Double(calories) ?? 0,
                protein: Double(protein) ?? 0,
                carbs: Double(carbs) ?? 0,
                fat: Double(fat) ?? 0,
                isAlcohol: isAlcohol,
                context: context
            )
        }

        if logAfterSave && logImmediately {
            DiaryService.addEntry(food: saved, quantity: 1, unit: .serving, meal: meal, date: selectedDate, context: context)
            onDone()
        } else {
            onFoodSaved?(saved)
        }
        dismiss()
    }

    private func deleteFood() {
        guard let existingFood else { return }
        FoodService.deleteCustomFood(existingFood, context: context)
        dismiss()
        onDone()
    }
}

struct MyFoodsListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var foodToEdit: Food?
    @State private var showCreate = false
    @State private var foodToDelete: Food?

    private var foods: [Food] {
        FoodService.searchCustomFoods(query: query, context: context)
    }

    var body: some View {
        NavigationStack {
            List {
                if foods.isEmpty {
                    Text(query.isEmpty ? "No custom foods yet." : "No matches.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(foods, id: \.id) { food in
                        Button {
                            foodToEdit = food
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(food.displayName)
                                Text(customFoodSubtitle(food))
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
            .searchable(text: $query, prompt: "Search my foods")
            .navigationTitle("My Foods")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $foodToEdit) { food in
                CustomFoodFormView(
                    barcode: food.barcode,
                    existingFood: food,
                    logImmediately: false,
                    onDone: {}
                )
            }
            .sheet(isPresented: $showCreate) {
                CustomFoodFormView(barcode: nil, logImmediately: false, onDone: {})
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
                Button("Cancel", role: .cancel) {
                    foodToDelete = nil
                }
            } message: {
                if let foodToDelete {
                    Text("\"\(foodToDelete.displayName)\" will be permanently deleted. Past diary entries will be kept; recipe ingredients using it will be removed.")
                }
            }
        }
    }

    private func customFoodSubtitle(_ food: Food) -> String {
        let serving = ServingConverter.servingLabel(for: .serving, food: food)
        return "\(Int(food.caloriesPerServing)) kcal per \(serving)"
    }
}
