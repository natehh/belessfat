import SwiftUI
import SwiftData

struct LabelCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    let barcode: String?
    let selectedDate: Date
    let defaultMeal: MealCategory
    var logImmediately: Bool = true
    var onFoodSaved: ((Food) -> Void)? = nil
    let onDone: () -> Void

    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var labelPrefill: ParsedLabelNutrition?
    @State private var showCamera = false
    @State private var showReviewForm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo of Nutrition Label", systemImage: "camera")
                    }
                    if isProcessing {
                        ProgressView("Reading label...")
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Photos are used for OCR only and are not saved to your library.")
                }
            }
            .navigationTitle("Scan Label")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                LabelCameraPicker { image in
                    Task { await processImage(image) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showReviewForm) {
                if let labelPrefill {
                    CustomFoodFormView(
                        barcode: barcode,
                        labelPrefill: labelPrefill,
                        logImmediately: logImmediately,
                        selectedDate: selectedDate,
                        defaultMeal: defaultMeal,
                        onFoodSaved: { food in
                            onFoodSaved?(food)
                            if !logImmediately {
                                dismiss()
                            }
                        },
                        onDone: {
                            dismiss()
                            onDone()
                        }
                    )
                }
            }
        }
    }

    private func processImage(_ image: UIImage) async {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }
        do {
            let parsed = try await LabelOCRService.parseLabel(from: image)
            labelPrefill = parsed
            showReviewForm = true
        } catch {
            errorMessage = "Could not read the label. Try again with better lighting."
        }
    }
}
