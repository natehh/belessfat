import SwiftUI
import SwiftData
import MessageUI

private struct FoodShareDraft: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let filename: String
    let fileURL: URL
}

private struct ShareFileModifier: ViewModifier {
    var suggestedName: String
    var makeDocument: () -> FoodShareDocument

    @State private var draft: FoodShareDraft?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let document = makeDocument()
                        guard let data = FoodShareService.fileData(for: document),
                              let fileURL = FoodShareService.fileURL(for: document, suggestedName: suggestedName) else { return }
                        draft = FoodShareDraft(
                            name: suggestedName,
                            data: data,
                            filename: FoodShareService.filename(for: suggestedName),
                            fileURL: fileURL
                        )
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
            .sheet(item: $draft) { draft in
                if MFMessageComposeViewController.canSendText() {
                    FoodShareMessageComposer(draft: draft) {
                        self.draft = nil
                    }
                } else {
                    ShareSheet(items: [FoodShareActivityItem(url: draft.fileURL)])
                }
            }
    }
}

extension View {
    func shareFile(
        suggestedName: String,
        makeDocument: @escaping () -> FoodShareDocument
    ) -> some View {
        modifier(ShareFileModifier(suggestedName: suggestedName, makeDocument: makeDocument))
    }
}

private struct FoodShareMessageComposer: UIViewControllerRepresentable {
    let draft: FoodShareDraft
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.body = draft.name
        let attached = controller.addAttachmentData(
            draft.data,
            typeIdentifier: FoodShareService.typeIdentifier,
            filename: draft.filename
        )
        if !attached {
            controller.body = draft.name
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        var onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
            onFinish()
        }
    }
}

private final class FoodShareActivityItem: NSObject, UIActivityItemSource {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        FoodShareService.typeIdentifier
    }
}

struct FoodShareImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let document: FoodShareDocument

    @State private var resolvedCatalog: [Int: Food] = [:]
    @State private var missingCatalog: Set<Int> = []
    @State private var isResolving = false

    var body: some View {
        NavigationStack {
            List {
                if let food = document.food {
                    Section {
                        Text(food.displayName)
                        LabeledContent("Calories", value: "\(Int(food.caloriesPerServing.rounded()))")
                        LabeledContent("Protein", value: "\(food.proteinPerServing.formatted(.number.precision(.fractionLength(0...1)))) g")
                        LabeledContent("Carbs", value: "\(food.carbsPerServing.formatted(.number.precision(.fractionLength(0...1)))) g")
                        LabeledContent("Fat", value: "\(food.fatPerServing.formatted(.number.precision(.fractionLength(0...1)))) g")
                    } header: {
                        Text("Custom food")
                    } footer: {
                        Text("This will be added as a new food, even if you already have one with the same name.")
                    }
                }

                if let recipe = document.recipe {
                    Section {
                        LabeledContent("Servings", value: recipe.servings.formatted(.number.precision(.fractionLength(0...2))))
                        LabeledContent("Ingredients", value: "\(recipe.ingredients.count)")
                    } header: {
                        Text(recipe.name)
                    }

                    if !recipe.customFoods.isEmpty {
                        Section {
                            ForEach(recipe.customFoods) { food in
                                Text(food.displayName)
                            }
                        } header: {
                            Text("Custom foods")
                        } footer: {
                            Text("These will be added as new foods and used in the recipe.")
                        }
                    }

                    let catalogIngredients = recipe.ingredients.enumerated().filter { $0.element.catalog != nil }
                    if !catalogIngredients.isEmpty {
                        Section {
                            ForEach(catalogIngredients, id: \.offset) { index, ingredient in
                                HStack {
                                    Text(ingredient.catalog?.displayName ?? "Food")
                                    Spacer()
                                    catalogStatus(index)
                                }
                            }
                        } header: {
                            Text("From the food database")
                        } footer: {
                            Text("These use the matching USDA or barcode foods already available in the app.")
                        }
                    }

                    if !missingCatalog.isEmpty {
                        Section {
                            Text("Couldn't find every database food. Retry when you're online.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(document.food != nil ? "Add Food" : "Add Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!canAdd)
                }
            }
            .task { await resolveCatalog() }
        }
    }

    private var canAdd: Bool {
        if document.food != nil { return true }
        guard document.recipe != nil else { return false }
        return !isResolving && missingCatalog.isEmpty
    }

    @ViewBuilder
    private func catalogStatus(_ index: Int) -> some View {
        if resolvedCatalog[index] != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if missingCatalog.contains(index) {
            Button("Retry") {
                Task { await resolveCatalog(onlyMissing: true) }
            }
            .font(.caption)
        } else {
            ProgressView()
        }
    }

    private func add() {
        FoodShareService.importDocument(document, catalogFoods: resolvedCatalog, context: context)
        dismiss()
    }

    private func resolveCatalog(onlyMissing: Bool = false) async {
        guard let ingredients = document.recipe?.ingredients else { return }
        isResolving = true
        defer { isResolving = false }
        for (index, ingredient) in ingredients.enumerated() {
            guard let catalog = ingredient.catalog else { continue }
            if onlyMissing, !missingCatalog.contains(index) { continue }
            if resolvedCatalog[index] != nil { continue }
            missingCatalog.remove(index)
            if let food = await FoodShareService.resolveCatalog(catalog, context: context) {
                resolvedCatalog[index] = food
            } else {
                missingCatalog.insert(index)
            }
        }
    }
}
