import SwiftUI
import SwiftData
import PhotosUI
import UIKit

private struct ParsedEstimateItem: Identifiable {
    let id = UUID()
    let recipe: ParsedWebRecipe
}

struct AIFoodEstimateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let selectedDate: Date
    let defaultMeal: MealCategory
    let onDone: () -> Void

    @State private var foodNameHint = ""
    @State private var promptCopied = false
    @State private var replyText = ""
    @State private var importError: String?
    @State private var parsedReview: ParsedEstimateItem?
    @State private var showCamera = false
    @State private var selectedLibraryItem: PhotosPickerItem?
    @State private var isEstimating = false
    @State private var estimateStatus = ""
    @State private var hasAPIKey = AIAssistant.hasConfiguredKey
    @State private var screenshotPreviewImage: UIImage?

    private var trimmedFoodNameHint: String? {
        let trimmed = foodNameHint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var currentPrompt: String {
        AIFoodEstimateService.prompt(foodNameHint: trimmedFoodNameHint)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Chipotle chicken burrito bowl", text: $foodNameHint)
                        .textInputAutocapitalization(.sentences)
                        .disabled(isEstimating)
                        .onChange(of: foodNameHint) { _, _ in
                            promptCopied = false
                        }
                    if let screenshotPreviewImage {
                        Image(uiImage: screenshotPreviewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                } header: {
                    Text("Food name (optional)")
                } footer: {
                    Text("Tell the AI what this is if the photo alone isn’t clear. Included in the prompt for in-app and clipboard estimates.")
                }

                if hasAPIKey || screenshotPreviewImage != nil {
                    Section {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                        .disabled(isEstimating)

                        PhotosPicker(selection: $selectedLibraryItem, matching: .images) {
                            Label("Choose from Library", systemImage: "photo.on.rectangle")
                        }
                        .disabled(isEstimating)

                        if isEstimating, !estimateStatus.isEmpty {
                            Text(estimateStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("In-app estimate")
                    } footer: {
                        Text("Uses your AI API key from Settings. The AI identifies foods and amounts; you review USDA / Open Food Facts matches before saving.")
                    }
                } else {
                    Section {
                        Text("Add an AI API key in Settings to estimate from a photo in-app. You can still use the clipboard flow below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("1. Copy the prompt below.")
                    Text("2. Paste it into your AI app and attach a photo of the food.")
                    Text("3. Copy the AI reply, paste it into the box below, then import.")
                } header: {
                    Text(hasAPIKey ? "Clipboard fallback" : "How it works")
                } footer: {
                    Text("The AI should reply with JSON ingredients. You’ll match them to the food database and review before saving.")
                }

                Section("Prompt") {
                    Text(currentPrompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        AIFoodEstimateService.copyPromptToClipboard(foodNameHint: trimmedFoodNameHint)
                        promptCopied = true
                    } label: {
                        Label(
                            promptCopied ? "Prompt Copied" : "Copy Prompt",
                            systemImage: promptCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                }

                Section {
                    TextEditor(text: $replyText)
                        .frame(minHeight: 140)
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
                    Text("You can paste the whole AI reply — it doesn’t have to be JSON-only.")
                }
            }
            .navigationTitle("Estimate with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #if DEBUG
            .onAppear {
                if AppStoreScreenshotSeeder.isEnabled {
                    foodNameHint = "Chipotle chicken burrito bowl"
                    screenshotPreviewImage = AppStoreScreenshotSeeder.sampleMealImage()
                    hasAPIKey = true
                }
            }
            #endif
            .disabled(isEstimating)
            .overlay {
                if isEstimating {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(estimateStatus.isEmpty ? "Estimating with AI…" : estimateStatus)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .alert("Import Failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .fullScreenCover(isPresented: $showCamera) {
                LabelCameraPicker { image in
                    Task { await estimateFromPhoto(image) }
                }
            }
            .onChange(of: selectedLibraryItem) { _, newItem in
                guard let newItem else { return }
                Task { await estimateFromLibrary(newItem) }
            }
            .sheet(item: $parsedReview) { item in
                NavigationStack {
                    RecipeImportReviewView(
                        parsed: item.recipe,
                        selectedDate: selectedDate,
                        defaultMeal: defaultMeal,
                        mode: .mealEstimate,
                        onFinished: { _ in
                            parsedReview = nil
                            dismiss()
                            onDone()
                        }
                    )
                }
            }
            .onAppear {
                hasAPIKey = AIAssistant.hasConfiguredKey
            }
        }
    }

    private func importReply() async {
        do {
            let draft = try AIFoodEstimateService.parse(replyText)
            await matchAndReview(draft)
        } catch {
            let detail = error.localizedDescription
            importError = "\(detail) If Paste didn’t work, tap the text box and paste manually."
        }
    }

    private func estimateFromLibrary(_ item: PhotosPickerItem) async {
        defer { selectedLibraryItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            importError = "Could not load the selected photo."
            return
        }
        await estimateFromPhoto(image)
    }

    private func estimateFromPhoto(_ image: UIImage) async {
        guard AIAssistant.hasConfiguredKey else {
            importError = AIAssistant.AssistantError.missingAPIKey.localizedDescription
            return
        }
        isEstimating = true
        estimateStatus = "Preparing photo…"
        defer {
            isEstimating = false
            estimateStatus = ""
        }
        do {
            let draft = try await AIAssistant.estimateFood(
                from: image,
                foodNameHint: trimmedFoodNameHint,
                onStatus: { status in
                    Task { @MainActor in
                        estimateStatus = status
                    }
                }
            )
            await matchAndReview(draft)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func matchAndReview(_ draft: AIRecipeImportDraft) async {
        isEstimating = true
        estimateStatus = "Matching foods…"
        defer {
            isEstimating = false
            estimateStatus = ""
        }
        let parsed = await AIRecipeImportService.matchIngredients(draft, context: context)
        var recipe = parsed
        ServingConverter.applyPreferredWeightUnit(to: &recipe.ingredients)
        parsedReview = ParsedEstimateItem(recipe: recipe)
    }
}
