import SwiftUI
import SwiftData

private enum WeightGoalEditorMode: String, Identifiable {
    case edit
    case configure

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var healthKit: HealthKitService
    @Query(sort: \UserSettings.id) private var settingsQuery: [UserSettings]
    @Query(sort: \WeightGoal.targetDate, order: .reverse) private var weightGoals: [WeightGoal]
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage(ServingConverter.preferredWeightUnitStorageKey) private var preferredWeightUnit = ServingUnitType.ounces.rawValue

    @State private var weightGoalEditor: WeightGoalEditorMode?
    @State private var showTemplates = false
    @State private var showFavorites = false
    @State private var showImport = false
    @State private var showCronometerImport = false

    private var activeWeightGoal: WeightGoal? {
        weightGoals.first(where: \.isActive) ?? weightGoals.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let settings = settingsQuery.first {
                    SettingsFormContent(
                        settings: settings,
                        activeWeightGoal: activeWeightGoal,
                        appearanceMode: $appearanceMode,
                        preferredWeightUnit: $preferredWeightUnit,
                        weightGoalEditor: $weightGoalEditor,
                        showTemplates: $showTemplates,
                        showFavorites: $showFavorites,
                        showImport: $showImport,
                        showCronometerImport: $showCronometerImport,
                        onDeleteAllData: deleteAllData
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $weightGoalEditor) { mode in
                switch mode {
                case .edit:
                    WeightGoalSettingsView(existingGoal: activeWeightGoal)
                case .configure:
                    WeightGoalSettingsView(replacesExisting: activeWeightGoal != nil)
                }
            }
            .sheet(isPresented: $showTemplates) { TemplatesListView() }
            .sheet(isPresented: $showFavorites) { FavoritesListView() }
            .sheet(isPresented: $showImport) { CSVImportView() }
            .sheet(isPresented: $showCronometerImport) { CronometerImportView() }
        }
        .onAppear {
            _ = GoalService.settings(context: context)
        }
    }

    private func deleteAllData() {
        try? context.delete(model: Food.self)
        try? context.delete(model: Recipe.self)
        try? context.delete(model: LogEntry.self)
        try? context.delete(model: WeightEntry.self)
        try? context.delete(model: BodyFatEntry.self)
        try? context.delete(model: WeightGoal.self)
        try? context.delete(model: DailyHealthSnapshot.self)
        try? context.delete(model: MealTemplate.self)
        try? context.delete(model: FavoriteMeal.self)
        try? context.delete(model: UserSettings.self)
        ProgressPhotoService.deleteAll(context: context)
        context.insert(UserSettings())
        try? context.save()
    }
}

private struct SettingsFormContent: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var healthKit: HealthKitService
    @Bindable var settings: UserSettings
    let activeWeightGoal: WeightGoal?
    @Binding var appearanceMode: String
    @Binding var preferredWeightUnit: String
    @Binding var weightGoalEditor: WeightGoalEditorMode?
    @Binding var showTemplates: Bool
    @Binding var showFavorites: Bool
    @Binding var showImport: Bool
    @Binding var showCronometerImport: Bool
    let onDeleteAllData: () -> Void
    @State private var showDeleteAllConfirm = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }

            Section {
                Text(HealthKitCopy.settingsDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if healthKit.isAvailable {
                    Button("Authorize HealthKit") {
                        Task { await healthKit.requestAuthorization(context: context) }
                    }
                    Button("Sync Today") {
                        Task { await healthKit.sync(for: Date(), context: context) }
                    }
                    Button("Sync Last 30 Days") {
                        let end = Date()
                        let start = Calendar.current.date(byAdding: .day, value: -29, to: end)!
                        Task { await healthKit.sync(from: start, to: end, context: context) }
                    }
                    if let message = healthKit.lastSyncMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("HealthKit is not available on this device.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("HealthKit")
            } footer: {
                Text("You can change HealthKit access in the Health app. Weight from HealthKit fills the diary; a newer manual save wins until a later HealthKit sample arrives. This app does not use CareKit.")
            }

            Section {
                Picker("Weight", selection: $preferredWeightUnit) {
                    Text("Ounces").tag(ServingUnitType.ounces.rawValue)
                    Text("Grams").tag(ServingUnitType.grams.rawValue)
                }
            } header: {
                Text("Units")
            } footer: {
                Text("Used for AI photo estimates. Logging units are unchanged.")
            }

            Section("Macro Targets") {
                Toggle("Use Percentage Split", isOn: $settings.usePercentageMode)
                    .onChange(of: settings.usePercentageMode) { _, enabled in
                        if enabled {
                            settings.applyPercentageTargets()
                        }
                        save()
                    }
                if settings.usePercentageMode {
                    Picker("Preset", selection: presetBinding) {
                        ForEach(MacroSplitPreset.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    percentRow("Protein", percent: settings.proteinPercent, grams: settings.dailyProtein)
                    percentRow("Carbs", percent: settings.carbsPercent, grams: settings.dailyCarbs)
                    percentRow("Fat", percent: settings.fatPercent, grams: settings.dailyFat)
                    NumericStepperField(title: "Protein %", value: percentBinding(\.proteinPercent), range: 5...70, step: 1, suffix: "%", format: "%.0f")
                    NumericStepperField(title: "Carbs %", value: percentBinding(\.carbsPercent), range: 5...70, step: 1, suffix: "%", format: "%.0f")
                    NumericStepperField(title: "Fat %", value: percentBinding(\.fatPercent), range: 5...70, step: 1, suffix: "%", format: "%.0f")
                }
                NumericStepperField(title: "Calories", value: caloriesBinding, range: 500...10000, step: 50, suffix: "kcal")
                if !settings.usePercentageMode {
                    NumericStepperField(title: "Protein", value: macroBinding(\.dailyProtein), range: 0...500, step: 5, suffix: "g")
                    NumericStepperField(title: "Carbs", value: macroBinding(\.dailyCarbs), range: 0...1000, step: 5, suffix: "g")
                    NumericStepperField(title: "Fat", value: macroBinding(\.dailyFat), range: 0...500, step: 5, suffix: "g")
                }
                Picker("Progress Display", selection: $settings.macroDisplayModeRaw) {
                    ForEach(MacroDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .onChange(of: settings.macroDisplayModeRaw) { _, _ in save() }
                Toggle("Weekly Calorie Budget", isOn: $settings.weeklyBudgetEnabled)
                    .onChange(of: settings.weeklyBudgetEnabled) { _, _ in save() }
                Picker("Week Starts On", selection: $settings.weekStartDay) {
                    ForEach(WeekStartDay.allCases) { day in
                        Text(day.displayName).tag(day)
                    }
                }
                .onChange(of: settings.weekStartDayRaw) { _, _ in save() }
            }

            Section {
                NumericStepperField(
                    title: "Daily Step Target",
                    value: Binding(
                        get: { Double(settings.dailyStepTarget) },
                        set: {
                            settings.dailyStepTarget = Int($0)
                            save()
                        }
                    ),
                    range: 1000...50_000,
                    step: 500,
                    suffix: "steps",
                    format: "%.0f"
                )
            } header: {
                Text("Steps")
            } footer: {
                Text("Step counts shown in the diary are imported from HealthKit.")
            }

            Section("Weight Goal") {
                if activeWeightGoal != nil {
                    Button("Edit Weight Goal") { weightGoalEditor = .edit }
                    Button("Configure Weight Goal") { weightGoalEditor = .configure }
                } else {
                    Button("Configure Weight Goal") { weightGoalEditor = .configure }
                }
                if let goal = activeWeightGoal {
                    LabeledContent("Type", value: goal.goalType.displayName)
                    LabeledContent("Start", value: "\(goal.startWeightLbs.formatted()) lbs")
                    LabeledContent("Goal", value: "\(goal.goalWeightLbs.formatted()) lbs")
                    LabeledContent("Started", value: goal.startDate.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Target Date", value: goal.targetDate.formatted(date: .abbreviated, time: .omitted))
                }
                NavigationLink("Progress Photos") {
                    ProgressPhotosView()
                }
            }

            Section {
                heightEditor
                Picker("Sex", selection: sexBinding) {
                    Text("Not set").tag(Optional<BiologicalSex>.none)
                    ForEach(BiologicalSex.allCases) { sex in
                        Text(sex.displayName).tag(Optional(sex))
                    }
                }
                .onChange(of: settings.biologicalSexRaw) { _, _ in save() }
                if settings.birthYear != nil {
                    NumericStepperField(
                        title: "Birth year",
                        value: birthYearBinding,
                        range: 1920...Double(Calendar.current.component(.year, from: Date()) - 10),
                        step: 1,
                        format: "%.0f"
                    )
                } else {
                    Button("Set Birth Year") {
                        settings.birthYear = Calendar.current.component(.year, from: Date()) - 30
                        save()
                    }
                }
            } header: {
                Text("Body profile")
            } footer: {
                if settings.hasCompleteBodyProfile {
                    Text("Used for AI body-fat estimates.")
                } else {
                    Text("Used for AI body-fat estimates. Set height, sex, and birth year before estimating.")
                }
            }

            Section("AI") {
                NavigationLink("AI API Keys") {
                    AIAPIKeysSettingsView()
                }
            }

            Section("Food Database") {
                Button("Meal Templates") { showTemplates = true }
                Button("Favorite Meals") { showFavorites = true }
                Button("Import CSV") { showImport = true }
                Button("Import from Cronometer") { showCronometerImport = true }
            }

            Section("Data") {
                Button("Delete All Data", role: .destructive) { showDeleteAllConfirm = true }
            }

            Section("About") {
                LabeledContent("Food Lookup", value: "Requires Internet")
                LabeledContent("Storage", value: "Local Only")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Delete All Data?", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("Delete All Data", role: .destructive) { onDeleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes foods, recipes, diary entries, weights, photos, and settings on this device. This cannot be undone.")
        }
        .onDisappear { save() }
    }

    private var presetBinding: Binding<MacroSplitPreset> {
        Binding(
            get: { settings.macroSplitPreset },
            set: {
                settings.macroSplitPreset = $0
                if $0 != .custom {
                    settings.proteinPercent = $0.proteinPercent
                    settings.carbsPercent = $0.carbsPercent
                    settings.fatPercent = $0.fatPercent
                }
                settings.applyPercentageTargets()
                save()
            }
        )
    }

    private var caloriesBinding: Binding<Double> {
        Binding(
            get: { settings.dailyCalories },
            set: {
                settings.dailyCalories = $0
                if settings.usePercentageMode {
                    settings.applyPercentageTargets()
                }
                save()
            }
        )
    }

    private func percentBinding(_ keyPath: ReferenceWritableKeyPath<UserSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                settings.macroSplitPreset = .custom
                settings.applyPercentageTargets()
                save()
            }
        )
    }

    private func macroBinding(_ keyPath: ReferenceWritableKeyPath<UserSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                save()
            }
        )
    }

    private func save() {
        settings.normalizeDefaults()
        try? context.save()
    }

    private var sexBinding: Binding<BiologicalSex?> {
        Binding(
            get: { settings.biologicalSex },
            set: {
                settings.biologicalSex = $0
                save()
            }
        )
    }

    private var birthYearBinding: Binding<Double> {
        Binding(
            get: {
                Double(settings.birthYear ?? Calendar.current.component(.year, from: Date()) - 30)
            },
            set: {
                settings.birthYear = Int($0)
                save()
            }
        )
    }

    @ViewBuilder
    private var heightEditor: some View {
        if let heightInches = settings.heightInches, heightInches > 0 {
            let total = Int(heightInches.rounded())
            HStack {
                Text("Height")
                Spacer()
                Picker("Feet", selection: Binding(
                    get: { total / 12 },
                    set: { feet in
                        let inches = total % 12
                        settings.heightInches = Double(feet * 12 + inches)
                        save()
                    }
                )) {
                    ForEach(4...7, id: \.self) { feet in
                        Text("\(feet) ft").tag(feet)
                    }
                }
                .labelsHidden()
                Picker("Inches", selection: Binding(
                    get: { total % 12 },
                    set: { inches in
                        let feet = total / 12
                        settings.heightInches = Double(feet * 12 + inches)
                        save()
                    }
                )) {
                    ForEach(0..<12, id: \.self) { inches in
                        Text("\(inches) in").tag(inches)
                    }
                }
                .labelsHidden()
            }
        } else {
            Button("Set Height") {
                settings.heightInches = 70
                save()
            }
        }
    }

    @ViewBuilder
    private func percentRow(_ label: String, percent: Double, grams: Double) -> some View {
        LabeledContent(label, value: "\(Int(percent))% → \(grams.formatted(.number.precision(.fractionLength(0))))g")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct WeightGoalSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var existingGoal: WeightGoal?
    var replacesExisting: Bool = false

    @State private var goalType: GoalType = .lose
    @State private var startWeight = ""
    @State private var goalWeight = ""
    @State private var startDate = Date()
    @State private var targetDate = Calendar.current.date(byAdding: .month, value: 3, to: Date())!
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Goal Type", selection: $goalType) {
                    ForEach(GoalType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                HStack {
                    Text("Start Weight (lbs)")
                    Spacer()
                    DecimalPadTextField(text: $startWeight, placeholder: "0")
                        .frame(width: 100, height: 36)
                }
                HStack {
                    Text("Goal Weight (lbs)")
                    Spacer()
                    DecimalPadTextField(text: $goalWeight, placeholder: "0")
                        .frame(width: 100, height: 36)
                }
                DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                DatePicker("Target Date", selection: $targetDate, displayedComponents: .date)

                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(existingGoal == nil ? "Configure Weight Goal" : "Edit Weight Goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveGoal() }
                }
            }
            .onAppear { loadExisting() }
        }
    }

    private func loadExisting() {
        guard !replacesExisting else { return }
        guard let existing = existingGoal ?? GoalService.activeGoal(context: context) else { return }
        goalType = existing.goalType
        startWeight = formatWeight(existing.startWeightLbs)
        goalWeight = formatWeight(existing.goalWeightLbs)
        startDate = existing.startDate
        targetDate = existing.targetDate
    }

    private func saveGoal() {
        guard let start = parseWeight(startWeight) else {
            saveError = "Enter a valid start weight."
            return
        }
        guard let goal = parseWeight(goalWeight) else {
            saveError = "Enter a valid goal weight."
            return
        }

        let startDay = Calendar.current.startOfDay(for: startDate)
        if !replacesExisting, let existing = existingGoal ?? GoalService.activeGoal(context: context) {
            existing.goalType = goalType
            existing.startWeightLbs = start
            existing.goalWeightLbs = goal
            existing.startDate = startDay
            existing.targetDate = targetDate
            existing.isActive = true
        } else {
            let all = (try? context.fetch(FetchDescriptor<WeightGoal>())) ?? []
            for old in all {
                old.isActive = false
            }
            context.insert(WeightGoal(
                goalType: goalType,
                startWeightLbs: start,
                goalWeightLbs: goal,
                startDate: startDay,
                targetDate: targetDate
            ))
        }

        do {
            try context.save()
            dismiss()
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
        }
    }

    private func parseWeight(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    private func formatWeight(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(value)
    }
}

struct TemplatesListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var selectedDate: Date = Date()

    var body: some View {
        NavigationStack {
            List(FoodService.allTemplates(context: context)) { template in
                Button(template.name) {
                    DiaryService.applyTemplate(template, to: selectedDate, context: context)
                    dismiss()
                }
            }
            .navigationTitle("Templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct FavoritesListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var selectedDate: Date = Date()

    var body: some View {
        NavigationStack {
            List(FoodService.allFavorites(context: context)) { favorite in
                Button(favorite.name) {
                    DiaryService.applyFavorite(favorite, to: selectedDate, context: context)
                    dismiss()
                }
            }
            .navigationTitle("Favorites")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension MealTemplate: Identifiable {}
extension FavoriteMeal: Identifiable {}

struct AIAPIKeysSettingsView: View {
    @State private var selectedProvider = AIProviderStore.selected
    @State private var apiKey = ""
    @State private var isSaved = false
    @State private var showKey = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: selectedProvider) { _, newValue in
                    AIProviderStore.selected = newValue
                    loadKeyForSelectedProvider()
                    showKey = false
                    isSaved = false
                    errorMessage = nil
                }
            } header: {
                Text("Active provider")
            } footer: {
                Text("In-app food estimates, menu estimates, and recipe import use this provider’s key.")
            }

            Section {
                HStack {
                    Text(selectedProvider.displayName)
                    Spacer()
                    Text(KeychainStore.hasKey(for: selectedProvider) ? "Key saved" : "Not set")
                        .foregroundStyle(.secondary)
                }

                if showKey {
                    SecureField(selectedProvider.keyPlaceholder, text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Key") {
                        saveKey()
                    }
                } else {
                    Button(KeychainStore.hasKey(for: selectedProvider) ? "Edit Key" : "Add Key") {
                        apiKey = KeychainStore.get(selectedProvider.keychainAccount) ?? ""
                        showKey = true
                    }
                }

                if KeychainStore.hasKey(for: selectedProvider) {
                    Button("Remove Key", role: .destructive) {
                        KeychainStore.delete(selectedProvider.keychainAccount)
                        if selectedProvider.usesStandingAgents {
                            CursorStandingAgents.clearAll()
                        }
                        apiKey = ""
                        showKey = false
                        isSaved = false
                    }
                }

                if selectedProvider.usesStandingAgents, KeychainStore.hasKey(for: selectedProvider) {
                    Button("Reset Standing Agents") {
                        CursorStandingAgents.clearAll()
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text(selectedProvider.settingsFooter)
            }

            if let url = selectedProvider.dashboardURL {
                Section {
                    Link(selectedProvider.dashboardLinkTitle, destination: url)
                }
            }

            Section("Saved keys") {
                ForEach(AIProvider.allCases) { provider in
                    HStack {
                        Text(provider.displayName)
                        Spacer()
                        Text(KeychainStore.hasKey(for: provider) ? "Saved" : "—")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isSaved {
                Section {
                    Text("Key saved.")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("AI API Keys")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedProvider = AIProviderStore.selected
            loadKeyForSelectedProvider()
        }
    }

    private func loadKeyForSelectedProvider() {
        apiKey = KeychainStore.get(selectedProvider.keychainAccount) ?? ""
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                KeychainStore.delete(selectedProvider.keychainAccount)
                if selectedProvider.usesStandingAgents {
                    CursorStandingAgents.clearAll()
                }
            } else {
                try KeychainStore.set(trimmed, account: selectedProvider.keychainAccount)
                if selectedProvider.usesStandingAgents {
                    CursorStandingAgents.clearAll()
                }
            }
            AIProviderStore.selected = selectedProvider
            apiKey = trimmed
            showKey = false
            isSaved = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
