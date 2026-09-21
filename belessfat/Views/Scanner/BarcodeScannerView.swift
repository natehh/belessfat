import SwiftUI
import SwiftData
import AVFoundation
import Vision

struct BarcodeScannerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var network = NetworkMonitor.shared
    let selectedDate: Date
    var recipeMode: Bool = false
    var defaultMeal: MealCategory? = nil
    var onFoodPrepared: ((Food, Double, ServingUnitType) -> Void)?
    let onDone: () -> Void

    @State private var scannedBarcode: String?
    @State private var logFoodPresentation: LogFoodPresentation?
    @State private var quantityPresentation: FoodQuantityPresentation?
    @State private var isLookingUp = false
    @State private var errorMessage: String?
    @State private var showLabelCapture = false
    @State private var showManualAdd = false
    @State private var showNotFoundDialog = false

    private var loggingMeal: MealCategory {
        defaultMeal ?? DiaryService.mostRecentMeal(context: context)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView { code in
                    guard scannedBarcode == nil else { return }
                    scannedBarcode = code
                    Task { await lookup(code) }
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    if !network.isConnected {
                        Label("Internet required for barcode lookup", systemImage: "wifi.slash")
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if isLookingUp {
                        ProgressView("Looking up...")
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("Scan Barcode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $logFoodPresentation) { presentation in
                LogFoodSheet(
                    food: presentation.food,
                    defaultMeal: presentation.defaultMeal,
                    date: selectedDate,
                    initialQuantity: presentation.quantity,
                    initialUnit: presentation.unit
                ) {
                    dismiss()
                    onDone()
                }
            }
            .sheet(item: $quantityPresentation) { presentation in
                FoodQuantitySheet(food: presentation.food) { quantity, unit in
                    onFoodPrepared?(presentation.food, quantity, unit)
                    dismiss()
                }
            }
            .sheet(isPresented: $showLabelCapture) {
                LabelCaptureView(
                    barcode: scannedBarcode,
                    selectedDate: selectedDate,
                    defaultMeal: loggingMeal
                ) {
                    if recipeMode {
                        dismiss()
                    } else {
                        dismiss()
                        onDone()
                    }
                }
            }
            .sheet(isPresented: $showManualAdd) {
                CustomFoodFormView(
                    barcode: scannedBarcode,
                    logImmediately: !recipeMode,
                    selectedDate: selectedDate,
                    defaultMeal: loggingMeal,
                    onFoodSaved: recipeMode ? { food in
                        quantityPresentation = FoodQuantityPresentation(food: food)
                    } : nil,
                    onDone: {
                        dismiss()
                        onDone()
                    }
                )
            }
            .confirmationDialog("Product Not Found", isPresented: $showNotFoundDialog) {
                Button("Scan Nutrition Label") { showLabelCapture = true }
                Button("Enter Manually") { showManualAdd = true }
                Button("Cancel", role: .cancel) {
                    scannedBarcode = nil
                    errorMessage = nil
                }
            }
        }
    }

    private func lookup(_ barcode: String) async {
        isLookingUp = true
        errorMessage = nil
        do {
            if let food = try await FoodService.lookupBarcode(barcode, context: context) {
                let prepared = await FoodService.prepareForLogging(food, context: context)
                if recipeMode {
                    quantityPresentation = FoodQuantityPresentation(food: prepared)
                } else {
                    let amount = DiaryService.loggingAmount(for: prepared, context: context)
                    logFoodPresentation = LogFoodPresentation(
                        food: prepared,
                        defaultMeal: loggingMeal,
                        quantity: amount.quantity,
                        unit: amount.unit
                    )
                }
            } else {
                errorMessage = "Not found in database."
                showNotFoundDialog = true
            }
        } catch {
            errorMessage = "Lookup failed. Check internet connection."
        }
        isLookingUp = false
    }
}

struct FoodQuantityPresentation: Identifiable {
    let id = UUID()
    let food: Food
}

struct CameraPreviewView: UIViewControllerRepresentable {
    let onBarcode: (String) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onBarcode = onBarcode
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

final class CameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onBarcode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "barcode.scan")
    private var lastScan: Date = .distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastScan) > 1.5 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest { [weak self] request, _ in
            guard let results = request.results as? [VNBarcodeObservation],
                  let payload = results.first?.payloadStringValue else { return }
            self?.lastScan = Date()
            DispatchQueue.main.async {
                self?.onBarcode?(payload)
            }
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }
}
