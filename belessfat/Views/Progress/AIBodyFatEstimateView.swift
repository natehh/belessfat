import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct AIBodyFatEstimateView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// When set, successful estimates are written onto all progress photos for this day.
    var persistToDate: Date?
    /// Prefill with existing progress photos (e.g. a day batch).
    var initialPhotos: [ProgressPhoto] = []
    var onFinished: (() -> Void)? = nil

    @State private var selectedProgressPhotos: [ProgressPhoto]
    @State private var adHocImages: [UIImage] = []
    @State private var showCamera = false
    @State private var selectedLibraryItem: PhotosPickerItem?
    @State private var showProgressPicker = false

    @State private var isEstimating = false
    @State private var estimateStatus = ""
    @State private var errorMessage: String?
    @State private var result: AIBodyFatEstimateResult?
    @State private var replyText = ""
    @State private var promptCopied = false
    @State private var displayedPrompt = ""
    @State private var hasAPIKey = AIAssistant.hasConfiguredKey

    init(
        persistToDate: Date? = nil,
        initialPhotos: [ProgressPhoto] = [],
        onFinished: (() -> Void)? = nil
    ) {
        self.persistToDate = persistToDate
        self.initialPhotos = initialPhotos
        self.onFinished = onFinished
        _selectedProgressPhotos = State(initialValue: Array(initialPhotos.prefix(4)))
    }

    private var settings: UserSettings {
        GoalService.settings(context: context)
    }

    private var estimateDate: Date {
        persistToDate
            ?? selectedProgressPhotos.first?.date
            ?? Date()
    }

    private var combinedImages: [UIImage] {
        let fromProgress = ProgressPhotoService.loadImages(for: selectedProgressPhotos)
        return Array((fromProgress + adHocImages).prefix(4))
    }

    private var canEstimate: Bool {
        !combinedImages.isEmpty && settings.hasCompleteBodyProfile
    }

    var body: some View {
        NavigationStack {
            Form {
                if !settings.hasCompleteBodyProfile {
                    Section {
                        Text("Add height, sex, and birth year in Settings → Body profile before estimating.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        showProgressPicker = true
                    } label: {
                        Label(
                            selectedProgressPhotos.isEmpty
                                ? "Choose Progress Photos"
                                : "Progress photos (\(selectedProgressPhotos.count))",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    .disabled(isEstimating)

                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .disabled(isEstimating || combinedImages.count >= 4)

                    PhotosPicker(selection: $selectedLibraryItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isEstimating || combinedImages.count >= 4)

                    if !adHocImages.isEmpty || !selectedProgressPhotos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(combinedImages.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 96)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        Text("\(combinedImages.count)/4 photos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Use up to 4 photos for one combined body-fat %. Prefer front and side angles.")
                }

                if hasAPIKey {
                    Section {
                        Button {
                            Task { await runInAppEstimate() }
                        } label: {
                            Label(
                                isEstimating ? "Estimating…" : "Estimate with AI",
                                systemImage: "sparkles"
                            )
                        }
                        .disabled(!canEstimate || isEstimating)
                        if isEstimating, !estimateStatus.isEmpty {
                            Text(estimateStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("In-app estimate")
                    } footer: {
                        Text("Uses your AI API key from Settings. Visual estimate only — not medical advice.")
                    }
                } else {
                    Section {
                        Text("Add an AI API key in Settings to estimate in-app. You can still use the clipboard flow below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("1. Select photos above.")
                    Text("2. Copy the prompt and paste it into your AI app with the same photos.")
                    Text("3. Paste the AI reply below and import.")
                } header: {
                    Text(hasAPIKey ? "Clipboard fallback" : "How it works")
                }

                Section("Prompt") {
                    if displayedPrompt.isEmpty {
                        Text("Tap Copy Prompt to build the prompt from your body profile and selected photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(displayedPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button {
                        prepareAndCopyPrompt()
                    } label: {
                        Label(
                            promptCopied ? "Prompt Copied" : "Copy Prompt",
                            systemImage: promptCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(!canEstimate || isEstimating)
                }

                Section {
                    TextEditor(text: $replyText)
                        .frame(minHeight: 100)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { replyText = first }
                    }
                    .buttonBorderShape(.capsule)
                    Button {
                        importReply()
                    } label: {
                        Label("Import Reply", systemImage: "square.and.arrow.down")
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEstimating)
                } header: {
                    Text("AI Reply")
                }

                if let result {
                    Section("Result") {
                        LabeledContent(
                            "Body fat",
                            value: "\(result.bodyFatPercent.formatted(.number.precision(.fractionLength(1))))%"
                        )
                        if let notes = result.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if persistToDate != nil {
                            Text("Saved to this day’s progress photos.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Ephemeral — not saved to progress photos.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Body Fat Estimate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onFinished?()
                        dismiss()
                    }
                }
            }
            .disabled(isEstimating && hasAPIKey)
            .overlay {
                if isEstimating, hasAPIKey {
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
            .fullScreenCover(isPresented: $showCamera) {
                LabelCameraPicker { image in
                    if adHocImages.count + selectedProgressPhotos.count < 4 {
                        adHocImages.append(image)
                    }
                }
            }
            .onChange(of: selectedLibraryItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadLibraryItem(newItem) }
            }
            .sheet(isPresented: $showProgressPicker) {
                ProgressPhotoMultiPicker(selection: $selectedProgressPhotos)
            }
            .onAppear {
                hasAPIKey = AIAssistant.hasConfiguredKey
                // Prefer the full day batch when persisting to a progress-photo date.
                if let date = persistToDate {
                    let dayPhotos = ProgressPhotoService.photos(for: date, context: context)
                    if !dayPhotos.isEmpty {
                        selectedProgressPhotos = Array(dayPhotos.prefix(4))
                        return
                    }
                }
                if selectedProgressPhotos.isEmpty, !initialPhotos.isEmpty {
                    selectedProgressPhotos = Array(initialPhotos.prefix(4))
                }
            }
        }
    }

    private func profileContext() throws -> AIBodyFatEstimateService.ProfileContext {
        try AIBodyFatEstimateService.makeProfileContext(
            settings: settings,
            date: estimateDate,
            context: context
        )
    }

    private func prepareAndCopyPrompt() {
        errorMessage = nil
        promptCopied = false
        do {
            let profile = try profileContext()
            let prompt = AIBodyFatEstimateService.prompt(
                profile: profile,
                imageCount: max(combinedImages.count, 1)
            )
            displayedPrompt = prompt
            AIBodyFatEstimateService.copyPromptToClipboard(
                profile: profile,
                imageCount: max(combinedImages.count, 1)
            )
            promptCopied = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importReply() {
        errorMessage = nil
        do {
            let parsed = try AIBodyFatEstimateService.parse(replyText)
            applyResult(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runInAppEstimate() async {
        errorMessage = nil
        isEstimating = true
        estimateStatus = "Preparing…"
        defer {
            isEstimating = false
            estimateStatus = ""
        }
        do {
            let profile = try profileContext()
            let images = combinedImages
            let parsed = try await AIAssistant.estimateBodyFat(
                images: images,
                profile: profile,
                onStatus: { status in
                    Task { @MainActor in
                        estimateStatus = status
                    }
                }
            )
            applyResult(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyResult(_ parsed: AIBodyFatEstimateResult) {
        result = parsed
        if let persistToDate {
            ProgressPhotoService.applyBodyFatEstimate(
                parsed.bodyFatPercent,
                toDate: persistToDate,
                context: context
            )
        } else if let day = selectedProgressPhotos.first.map({ DateHelpers.startOfDay($0.date) }),
                  !selectedProgressPhotos.isEmpty,
                  adHocImages.isEmpty {
            // Estimating only from existing progress photos → persist to that day.
            ProgressPhotoService.applyBodyFatEstimate(
                parsed.bodyFatPercent,
                toDate: day,
                context: context
            )
        }
    }

    private func loadLibraryItem(_ item: PhotosPickerItem) async {
        defer { selectedLibraryItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "Could not load the selected photo."
            return
        }
        if adHocImages.count + selectedProgressPhotos.count < 4 {
            adHocImages.append(image)
        }
    }
}

private struct ProgressPhotoMultiPicker: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: [ProgressPhoto]

    private var grouped: [(date: Date, photos: [ProgressPhoto])] {
        let photos = ProgressPhotoService.allPhotos(context: context)
        let dict = Dictionary(grouping: photos) { DateHelpers.startOfDay($0.date) }
        return dict.keys.sorted(by: >).map { ($0, dict[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.date) { group in
                    Section(group.date.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.photos) { photo in
                            Button {
                                toggle(photo)
                            } label: {
                                HStack {
                                    ProgressPhotoImage(photo: photo)
                                        .frame(width: 44, height: 58)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading) {
                                        Text(photo.createdAt.formatted(date: .omitted, time: .shortened))
                                        if let weight = photo.weightLabel {
                                            Text(weight).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selection.contains(where: { $0.id == photo.id }) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(!selection.contains(where: { $0.id == photo.id }) && selection.count >= 4)
                        }
                    }
                }
            }
            .navigationTitle("Progress Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ photo: ProgressPhoto) {
        if let index = selection.firstIndex(where: { $0.id == photo.id }) {
            selection.remove(at: index)
            return
        }
        // Prefer same-day batch: if selecting a different day, replace selection.
        if let first = selection.first,
           !DateHelpers.isSameDay(first.date, photo.date) {
            selection = [photo]
            return
        }
        guard selection.count < 4 else { return }
        selection.append(photo)
    }
}
