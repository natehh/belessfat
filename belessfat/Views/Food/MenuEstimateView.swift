import SwiftUI
import SwiftData
import PhotosUI
import UIKit

private enum MenuPhase {
    case compose
    case chooseItems(restaurant: String, items: [MenuItemChoice])
    case needsInput(reason: String, restaurant: String, items: [MenuItemChoice])
    case review(restaurant: String, items: [MacroEstimate], back: MenuPhaseBox)
}

/// Holds the previous menu step so a review can return without a recursive phase.
private struct MenuPhaseBox {
    var compose: Bool
    var choose: (restaurant: String, items: [MenuItemChoice])?
    var needs: (reason: String, restaurant: String, items: [MenuItemChoice])?

    static var compose: MenuPhaseBox { MenuPhaseBox(compose: true, choose: nil, needs: nil) }

    static func choose(restaurant: String, items: [MenuItemChoice]) -> MenuPhaseBox {
        MenuPhaseBox(compose: false, choose: (restaurant, items), needs: nil)
    }

    static func needs(reason: String, restaurant: String, items: [MenuItemChoice]) -> MenuPhaseBox {
        MenuPhaseBox(compose: false, choose: nil, needs: (reason, restaurant, items))
    }

    var phase: MenuPhase {
        if let choose {
            return .chooseItems(restaurant: choose.restaurant, items: choose.items)
        }
        if let needs {
            return .needsInput(reason: needs.reason, restaurant: needs.restaurant, items: needs.items)
        }
        return .compose
    }
}

struct MenuEstimateView: View {
    @Environment(\.dismiss) private var dismiss
    let selectedDate: Date
    let defaultMeal: MealCategory
    let onDone: () -> Void

    @State private var menuURL = ""
    @State private var requestedItems = ""
    @State private var pastedMenu = ""
    @State private var phase: MenuPhase = .compose
    @State private var replyText = ""
    @State private var promptCopied = false
    @State private var importError: String?
    @State private var isEstimating = false
    @State private var estimateStatus = ""
    @State private var hasAPIKey = AIAssistant.hasConfiguredKey
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [UIImage] = []
    @State private var isLoadingPhotos = false
    @State private var showCamera = false

    private let photoLimit = 8

    private var trimmedURL: String {
        menuURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRequest: String {
        requestedItems.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            switch phase {
            case .review(let restaurant, let items, let back):
                MacroEstimateReviewView(
                    title: "Menu Estimates",
                    brand: restaurant,
                    items: items,
                    showsSelection: true,
                    selectedDate: selectedDate,
                    defaultMeal: defaultMeal,
                    onCancel: { phase = back.phase },
                    onFinished: {
                        dismiss()
                        onDone()
                    }
                )
            default:
                composeForm
            }
        }
    }

    private var composeForm: some View {
        Form {
            switch phase {
            case .compose:
                composeSections
            case .chooseItems(let restaurant, let items):
                chooseSections(restaurant: restaurant, items: items)
            case .needsInput(let reason, let restaurant, let items):
                needsSections(reason: reason, restaurant: restaurant, items: items)
            case .review:
                EmptyView()
            }

            clipboardSections
        }
        .navigationTitle("Estimate Menu")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(phaseIsCompose ? "Cancel" : "Back") {
                    if phaseIsCompose {
                        dismiss()
                    } else {
                        phase = .compose
                        replyText = ""
                        promptCopied = false
                    }
                }
            }
        }
        .disabled(isEstimating)
        .overlay { estimatingOverlay }
        .alert("Estimate Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            hasAPIKey = AIAssistant.hasConfiguredKey
        }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            LabelCameraPicker { image in
                appendPhoto(image)
            }
        }
    }

    private var phaseIsCompose: Bool {
        if case .compose = phase { return true }
        return false
    }

    @ViewBuilder
    private var composeSections: some View {
        Section {
            TextField("https://…", text: $menuURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
            addPhotosButton
            takePhotoButton
            if !photos.isEmpty {
                photoThumbnailStrip
            }
            TextField("Notes or dishes to estimate", text: $requestedItems, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Menu")
        } footer: {
            Text("Add photos of the menu or the dishes, then notes if you already know what you want. Nothing is sent until you tap the button. Leave the notes blank to get a list and pick from it.")
        }

        if hasAPIKey {
            Section {
                Button {
                    Task { await startLookup() }
                } label: {
                    Label(trimmedRequest.isEmpty ? "Find Menu Items" : "Estimate These Items", systemImage: "sparkles")
                }
                .disabled(!canStartCompose || isEstimating || isLoadingPhotos)
            } header: {
                Text("In-app estimate")
            }
        }
    }

    private var canStartCompose: Bool {
        !trimmedURL.isEmpty || !trimmedRequest.isEmpty || !photos.isEmpty
    }

    private var addPhotosButton: some View {
        PhotosPicker(
            selection: $photoItems,
            maxSelectionCount: photoLimit,
            matching: .images
        ) {
            Label(
                photos.isEmpty ? "Add Photos" : "\(photos.count) photo\(photos.count == 1 ? "" : "s")",
                systemImage: "photo.on.rectangle"
            )
        }
    }

    private var takePhotoButton: some View {
        Button {
            showCamera = true
        } label: {
            Label("Take Photo", systemImage: "camera")
        }
        .disabled(photos.count >= photoLimit || isLoadingPhotos)
    }

    private var photoThumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                removePhoto(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.borderless)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func chooseSections(restaurant: String, items: [MenuItemChoice]) -> some View {
        Section {
            if !restaurant.isEmpty {
                Text(restaurant)
                    .font(.headline)
            }
            ForEach(items) { item in
                Button {
                    toggleItem(item.id)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .foregroundStyle(.primary)
                            if !item.description.isEmpty {
                                Text(item.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Choose items")
                Spacer()
                Button(items.allSatisfy(\.isSelected) ? "Clear" : "Select All") {
                    setAllItemsSelected(!items.allSatisfy(\.isSelected))
                }
                .font(.caption)
            }
        }

        if hasAPIKey {
            Section {
                Button {
                    Task { await estimateSelected() }
                } label: {
                    Label("Estimate Selected", systemImage: "sparkles")
                }
                .disabled(!items.contains(where: \.isSelected) || isEstimating)
            }
        }
    }

    @ViewBuilder
    private func needsSections(reason: String, restaurant: String, items: [MenuItemChoice]) -> some View {
        Section {
            Text(reason)
            if !restaurant.isEmpty {
                Text(restaurant)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Menu not readable")
        } footer: {
            Text("Add screenshots or paste the dish names and descriptions. The estimate uses those instead of the page.")
        }

        Section {
            addPhotosButton
            takePhotoButton
            if !photos.isEmpty {
                photoThumbnailStrip
            }
            TextEditor(text: $pastedMenu)
                .frame(minHeight: 120)
        } header: {
            Text("Photos or pasted menu")
        }

        if hasAPIKey {
            Section {
                Button {
                    Task { await estimateFromFallback(items: items, restaurant: restaurant) }
                } label: {
                    Label("Estimate from This", systemImage: "sparkles")
                }
                .disabled((photos.isEmpty && pastedMenu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && items.isEmpty && trimmedRequest.isEmpty) || isEstimating || isLoadingPhotos)
            }
        }

        if !items.isEmpty {
            Section("Items already chosen") {
                ForEach(items.filter(\.isSelected)) { item in
                    Text(item.name)
                }
            }
        }
    }

    @ViewBuilder
    private var clipboardSections: some View {
        Section {
            Text("1. Copy the prompt.")
            Text("2. Paste it into your AI app. Attach menu screenshots there if the prompt asks for them.")
            Text("3. Paste the reply below.")
        } header: {
            Text(hasAPIKey ? "Clipboard fallback" : "How it works")
        }

        Section("Prompt") {
            Text(currentPrompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                AIMacroEstimateService.copyPromptToClipboard(currentPrompt)
                promptCopied = true
            } label: {
                Label(promptCopied ? "Prompt Copied" : "Copy Prompt", systemImage: promptCopied ? "checkmark" : "doc.on.doc")
            }
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
                Task { await importReply() }
            } label: {
                Label("Import Reply", systemImage: "square.and.arrow.down")
            }
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEstimating)
        } header: {
            Text("AI Reply")
        } footer: {
            Text("You can paste the whole reply. It doesn’t have to be JSON-only.")
        }
    }

    private var currentPrompt: String {
        switch phase {
        case .compose:
            if trimmedRequest.isEmpty {
                return AIMacroEstimateService.discoverPrompt(menuURL: trimmedURL, photoCount: photos.count)
            }
            return AIMacroEstimateService.estimatePrompt(
                menuURL: trimmedURL.isEmpty ? nil : trimmedURL,
                restaurant: nil,
                requestedItemsText: trimmedRequest,
                items: [],
                pastedText: nil
            )
        case .chooseItems(let restaurant, let items):
            return AIMacroEstimateService.estimatePrompt(
                menuURL: trimmedURL.isEmpty ? nil : trimmedURL,
                restaurant: restaurant,
                requestedItemsText: nil,
                items: items.filter(\.isSelected),
                pastedText: nil
            )
        case .needsInput(_, let restaurant, let items):
            return AIMacroEstimateService.estimatePrompt(
                menuURL: trimmedURL.isEmpty ? nil : trimmedURL,
                restaurant: restaurant,
                requestedItemsText: trimmedRequest.isEmpty ? nil : trimmedRequest,
                items: items,
                pastedText: pastedMenu
            )
        case .review:
            return ""
        }
    }

    @ViewBuilder
    private var estimatingOverlay: some View {
        if isEstimating {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView()
                    Text(estimateStatus.isEmpty ? "Estimating…" : estimateStatus)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func toggleItem(_ id: UUID) {
        guard case .chooseItems(let restaurant, var items) = phase else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected.toggle()
        phase = .chooseItems(restaurant: restaurant, items: items)
    }

    private func setAllItemsSelected(_ selected: Bool) {
        guard case .chooseItems(let restaurant, var items) = phase else { return }
        for index in items.indices {
            items[index].isSelected = selected
        }
        phase = .chooseItems(restaurant: restaurant, items: items)
    }

    private func startLookup() async {
        if trimmedRequest.isEmpty {
            let images = photos
            await run(images: images) { onStatus in
                try await AIAssistant.lookupMenu(menuURL: trimmedURL, images: images, onStatus: onStatus)
            }
        } else {
            let images = photos
            await run(images: images) { onStatus in
                try await AIAssistant.estimateMenu(
                    menuURL: trimmedURL.isEmpty ? nil : trimmedURL,
                    restaurant: nil,
                    requestedItemsText: trimmedRequest,
                    items: [],
                    pastedText: nil,
                    images: images,
                    onStatus: onStatus
                )
            }
        }
    }

    private func estimateSelected() async {
        guard case .chooseItems(let restaurant, let items) = phase else { return }
        let selected = items.filter(\.isSelected)
        let images = photos
        await run(images: images) { onStatus in
            try await AIAssistant.estimateMenu(
                menuURL: trimmedURL.isEmpty ? nil : trimmedURL,
                restaurant: restaurant,
                requestedItemsText: nil,
                items: selected,
                pastedText: nil,
                images: images,
                onStatus: onStatus
            )
        }
    }

    private func estimateFromFallback(items: [MenuItemChoice], restaurant: String) async {
        await run(images: photos) { onStatus in
            try await AIAssistant.estimateMenu(
                menuURL: trimmedURL.isEmpty ? nil : trimmedURL,
                restaurant: restaurant,
                requestedItemsText: trimmedRequest.isEmpty ? nil : trimmedRequest,
                items: items.filter(\.isSelected),
                pastedText: pastedMenu,
                images: photos,
                onStatus: onStatus
            )
        }
    }

    private func importReply() async {
        do {
            let response = try AIMacroEstimateService.parseMenu(replyText)
            apply(response)
            replyText = ""
        } catch {
            importError = error.localizedDescription
        }
    }

    private func run(
        images: [UIImage],
        _ work: @escaping (@escaping @Sendable (String) -> Void) async throws -> MenuAIResponse
    ) async {
        guard AIAssistant.hasConfiguredKey else {
            importError = AIAssistant.AssistantError.missingAPIKey.localizedDescription
            return
        }
        isEstimating = true
        estimateStatus = "Sending to AI…"
        defer {
            isEstimating = false
            estimateStatus = ""
        }
        do {
            let response = try await work { status in
                Task { @MainActor in
                    estimateStatus = status
                }
            }
            apply(response)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func apply(_ response: MenuAIResponse) {
        promptCopied = false
        switch response {
        case .items(let restaurant, let items):
            phase = .chooseItems(restaurant: restaurant, items: items)
        case .estimates(let restaurant, let items):
            phase = .review(restaurant: restaurant, items: items, back: backBox)
        case .needsMenu(let restaurant, let reason):
            let pending = pendingItems
            phase = .needsInput(reason: reason, restaurant: restaurant, items: pending)
        }
    }

    private var backBox: MenuPhaseBox {
        switch phase {
        case .compose:
            return .compose
        case .chooseItems(let restaurant, let items):
            return .choose(restaurant: restaurant, items: items)
        case .needsInput(let reason, let restaurant, let items):
            return .needs(reason: reason, restaurant: restaurant, items: items)
        case .review(_, _, let back):
            return back
        }
    }

    private var pendingItems: [MenuItemChoice] {
        switch phase {
        case .chooseItems(_, let items):
            return items.filter(\.isSelected)
        case .needsInput(_, _, let items):
            return items
        case .compose, .review:
            return []
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }
        var loaded: [UIImage] = []
        for item in items.prefix(photoLimit) {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                loaded.append(image)
            }
        }
        photos = loaded
    }

    private func appendPhoto(_ image: UIImage) {
        guard photos.count < photoLimit else { return }
        photos.append(image)
    }

    private func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
    }
}

struct MacroEstimateReviewView: View {
    @Environment(\.modelContext) private var context
    let title: String
    let brand: String?
    let showsSelection: Bool
    let selectedDate: Date
    let defaultMeal: MealCategory
    let onCancel: () -> Void
    let onFinished: () -> Void

    @State private var items: [MacroEstimate]
    @State private var meal: MealCategory

    init(
        title: String,
        brand: String?,
        items: [MacroEstimate],
        showsSelection: Bool,
        selectedDate: Date,
        defaultMeal: MealCategory,
        onCancel: @escaping () -> Void,
        onFinished: @escaping () -> Void
    ) {
        self.title = title
        self.brand = brand
        self.showsSelection = showsSelection
        self.selectedDate = selectedDate
        self.defaultMeal = defaultMeal
        self.onCancel = onCancel
        self.onFinished = onFinished
        _items = State(initialValue: items)
        _meal = State(initialValue: defaultMeal)
    }

    private var chosen: [MacroEstimate] {
        showsSelection ? items.filter(\.isSelected) : items
    }

    private var canSave: Bool {
        !chosen.isEmpty && chosen.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        Form {
            if let brand, !brand.isEmpty {
                Section {
                    Text(brand)
                        .font(.headline)
                }
            }
            Section {
                ForEach($items) { $item in
                    HStack(alignment: .top, spacing: 12) {
                        if showsSelection {
                            Button {
                                item.isSelected.toggle()
                            } label: {
                                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.macroLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if item.listed {
                                Text("From the menu")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if !item.notes.isEmpty {
                                Text(item.notes)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        NavigationLink {
                            MacroEstimateEditor(estimate: $item)
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Tap the pencil to change a name, serving, or macros before saving.")
            }

            Section {
                Picker("Meal", selection: $meal) {
                    ForEach(MealCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
            } footer: {
                Text("The meal is used when you save and log.")
            }

            Section {
                Button("Save") { save(log: false) }
                    .disabled(!canSave)
                Button("Save & Log") { save(log: true) }
                    .disabled(!canSave)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back", action: onCancel)
            }
        }
    }

    private func save(log: Bool) {
        let trimmedBrand = brand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let brandValue = (trimmedBrand?.isEmpty == false) ? trimmedBrand : nil
        for item in chosen {
            let description = item.servingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let food = FoodService.saveCustomFood(
                name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                brand: brandValue,
                barcode: nil,
                serving: FoodService.CustomServingDefinition(
                    amount: 1,
                    unit: .serving,
                    gramWeight: nil,
                    description: description.isEmpty ? "1 serving" : description
                ),
                calories: item.calories,
                protein: item.protein,
                carbs: item.carbs,
                fat: item.fat,
                isAlcohol: false,
                context: context
            )
            if log {
                DiaryService.addEntry(
                    food: food,
                    quantity: 1,
                    unit: .serving,
                    meal: meal,
                    date: selectedDate,
                    context: context
                )
            }
        }
        onFinished()
    }
}

private struct MacroEstimateEditor: View {
    @Binding var estimate: MacroEstimate
    @State private var caloriesText = ""
    @State private var proteinText = ""
    @State private var carbsText = ""
    @State private var fatText = ""

    var body: some View {
        Form {
            TextField("Name", text: $estimate.name)
            TextField("Serving", text: $estimate.servingDescription)
            numberField("Calories", text: $caloriesText)
            numberField("Protein (g)", text: $proteinText)
            numberField("Carbs (g)", text: $carbsText)
            numberField("Fat (g)", text: $fatText)
            if !estimate.notes.isEmpty {
                Section("Notes") {
                    Text(estimate.notes)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Edit Estimate")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            caloriesText = numberString(estimate.calories)
            proteinText = numberString(estimate.protein)
            carbsText = numberString(estimate.carbs)
            fatText = numberString(estimate.fat)
        }
        .onChange(of: caloriesText) { _, newValue in apply(newValue) { estimate.calories = $0 } }
        .onChange(of: proteinText) { _, newValue in apply(newValue) { estimate.protein = $0 } }
        .onChange(of: carbsText) { _, newValue in apply(newValue) { estimate.carbs = $0 } }
        .onChange(of: fatText) { _, newValue in apply(newValue) { estimate.fat = $0 } }
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            DecimalPadTextField(text: text, placeholder: "0")
                .frame(width: 90, height: 36)
        }
    }

    private func apply(_ text: String, write: (Double) -> Void) {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        if let value = Double(cleaned) {
            write(value)
        }
    }

    private func numberString(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }
}
