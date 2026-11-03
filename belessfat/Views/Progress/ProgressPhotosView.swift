import SwiftUI
import SwiftData
import UIKit
import PhotosUI

struct ProgressPhotosView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\ProgressPhoto.date, order: .reverse), SortDescriptor(\ProgressPhoto.createdAt, order: .reverse)])
    private var photos: [ProgressPhoto]

    @State private var showAddSheet = false
    @State private var bodyFatEstimateRequest: BodyFatEstimateRequest?
    @State private var compareMode = false
    @State private var selectedForCompare: [ProgressPhoto] = []
    @State private var showCompare = false
    @State private var detailPhoto: ProgressPhoto?
    @State private var saveError: String?

    private var groupedPhotos: [(date: Date, photos: [ProgressPhoto])] {
        let grouped = Dictionary(grouping: photos) { DateHelpers.startOfDay($0.date) }
        return grouped.keys.sorted(by: >).map { date in
            (date, grouped[date]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    "No Progress Photos",
                    systemImage: "camera",
                    description: Text("Take a new photo or choose one from your library. New camera photos stay in the app only.")
                )
            } else {
                List {
                    ForEach(groupedPhotos, id: \.date) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                                ForEach(group.photos) { photo in
                                    ProgressPhotoThumbnail(photo: photo, isSelected: selectedForCompare.contains(where: { $0.id == photo.id }))
                                        .onTapGesture { handleTap(photo) }
                                        .contextMenu {
                                            Button("View") { detailPhoto = photo }
                                            Button("Estimate Body Fat") {
                                                openBodyFatEstimate(date: group.date, photos: group.photos)
                                            }
                                            Button("Delete", role: .destructive) { deletePhoto(photo) }
                                        }
                                }
                            }
                            .padding(.vertical, 4)
                        } header: {
                            HStack(spacing: 8) {
                                Text(group.date.formatted(date: .abbreviated, time: .omitted))
                                Spacer(minLength: 8)
                                HStack(spacing: 6) {
                                    if let weight = ProgressPhotoService.weightSummary(for: group.date, context: context) {
                                        Text(weight)
                                    }
                                    if let bf = group.photos.compactMap(\.bodyFatPercent).first {
                                        Text("\(bf.formatted(.number.precision(.fractionLength(1))))% BF")
                                    }
                                }
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                if !compareMode {
                                    Button {
                                        openBodyFatEstimate(date: group.date, photos: group.photos)
                                    } label: {
                                        Label(
                                            group.photos.compactMap(\.bodyFatPercent).first == nil
                                                ? "Estimate Body Fat"
                                                : "Re-estimate Body Fat",
                                            systemImage: "sparkles"
                                        )
                                        .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(
                                        group.photos.compactMap(\.bodyFatPercent).first == nil
                                            ? "Estimate body fat for this day"
                                            : "Re-estimate body fat for this day"
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Progress Photos")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if photos.count >= 2 {
                    Button(compareMode ? "Done" : "Compare") {
                        toggleCompareMode()
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if compareMode, selectedForCompare.count == 2 {
                    Button("View") { showCompare = true }
                }
                if !compareMode {
                    Menu {
                        Button("Add Photo") { showAddSheet = true }
                        if let latest = groupedPhotos.first {
                            Button("Estimate Body Fat (Latest Day)") {
                                openBodyFatEstimate(date: latest.date, photos: latest.photos)
                            }
                        }
                        Button("Estimate Body Fat…") {
                            openBodyFatEstimate(date: nil, photos: [])
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                } else {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddProgressPhotoSheet()
        }
        .sheet(item: $bodyFatEstimateRequest) { request in
            AIBodyFatEstimateView(
                persistToDate: request.persistToDate,
                initialPhotos: request.photos
            )
        }
        .sheet(item: $detailPhoto) { photo in
            ProgressPhotoDetailView(
                photo: photo,
                onDelete: {
                    deletePhoto(photo)
                    detailPhoto = nil
                },
                onEstimateBodyFat: {
                    let day = DateHelpers.startOfDay(photo.date)
                    let dayPhotos = ProgressPhotoService.photos(for: day, context: context)
                    detailPhoto = nil
                    openBodyFatEstimate(date: day, photos: dayPhotos)
                }
            )
        }
        .fullScreenCover(isPresented: $showCompare) {
            if selectedForCompare.count == 2 {
                let sorted = selectedForCompare.sorted {
                    if $0.date != $1.date { return $0.date < $1.date }
                    return $0.createdAt < $1.createdAt
                }
                ProgressPhotoCompareView(before: sorted[0], after: sorted[1])
            }
        }
        .alert("Could Not Save Photo", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func handleTap(_ photo: ProgressPhoto) {
        if compareMode {
            toggleSelection(photo)
        } else {
            detailPhoto = photo
        }
    }

    private func toggleCompareMode() {
        compareMode.toggle()
        selectedForCompare = []
    }

    private func toggleSelection(_ photo: ProgressPhoto) {
        if let index = selectedForCompare.firstIndex(where: { $0.id == photo.id }) {
            selectedForCompare.remove(at: index)
            return
        }
        guard selectedForCompare.count < 2 else { return }
        selectedForCompare.append(photo)
    }

    private func deletePhoto(_ photo: ProgressPhoto) {
        ProgressPhotoService.delete(photo, context: context)
        selectedForCompare.removeAll { $0.id == photo.id }
    }

    private func openBodyFatEstimate(date: Date?, photos: [ProgressPhoto]) {
        bodyFatEstimateRequest = BodyFatEstimateRequest(
            persistToDate: date.map { DateHelpers.startOfDay($0) },
            photos: photos
        )
    }
}

private struct BodyFatEstimateRequest: Identifiable {
    let id = UUID()
    let persistToDate: Date?
    let photos: [ProgressPhoto]
}

private struct ProgressPhotoThumbnail: View {
    let photo: ProgressPhoto
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ProgressPhotoImage(photo: photo)
                .aspectRatio(3 / 4, contentMode: .fill)
                .frame(minHeight: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .tint)
                    .padding(6)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
            }
        }
    }
}

struct ProgressPhotoImage: View {
    let photo: ProgressPhoto

    var body: some View {
        if let uiImage = UIImage(contentsOfFile: ProgressPhotoService.imageURL(for: photo).path) {
            Image(uiImage: uiImage)
                .resizable()
        } else {
            Color.secondary.opacity(0.2)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct ProgressPhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let photo: ProgressPhoto
    let onDelete: () -> Void
    var onEstimateBodyFat: (() -> Void)? = nil

    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressPhotoImage(photo: photo)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    LabeledContent("Date", value: photo.date.formatted(date: .abbreviated, time: .omitted))
                    if let weight = ProgressPhotoService.weightForEstimate(on: photo.date, context: context) {
                        LabeledContent("Weight", value: weight.label)
                    }
                    if let bodyFatLabel = photo.bodyFatLabel {
                        LabeledContent("Body fat", value: bodyFatLabel)
                    }
                    LabeledContent("Taken", value: photo.createdAt.formatted(date: .abbreviated, time: .shortened))

                    if onEstimateBodyFat != nil {
                        Button {
                            onEstimateBodyFat?()
                        } label: {
                            Label(
                                photo.bodyFatPercent == nil ? "Estimate Body Fat" : "Re-estimate Body Fat",
                                systemImage: "sparkles"
                            )
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Progress Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) { showDeleteConfirm = true }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct ProgressPhotoCompareView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let before: ProgressPhoto
    let after: ProgressPhoto

    var body: some View {
        NavigationStack {
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    compareColumn(photo: before, title: "Earlier")
                    compareColumn(photo: after, title: "Later")
                }
                .padding()
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func compareColumn(photo: ProgressPhoto, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ProgressPhotoImage(photo: photo)
                .aspectRatio(3 / 4, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(photo.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
            if let weight = ProgressPhotoService.weightSummary(for: photo.date, context: context) {
                Text(weight)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let bodyFatLabel = photo.bodyFatLabel {
                Text(bodyFatLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AddProgressPhotoSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var initialDate: Date = Date()

    @State private var photoDate: Date
    @State private var showCamera = false
    @State private var selectedLibraryItem: PhotosPickerItem?
    @State private var alsoEstimateBodyFat = false
    @State private var saveError: String?
    @State private var bodyFatAfterSaveRequest: BodyFatEstimateRequest?

    init(initialDate: Date = Date()) {
        self.initialDate = initialDate
        _photoDate = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $photoDate, displayedComponents: .date)
                }
                Section {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    PhotosPicker(selection: $selectedLibraryItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                    }
                } footer: {
                    Text("New camera photos are stored in the app only and are not saved to your photo library. Library photos are copied into the app.")
                }
                Section {
                    Toggle("Also estimate body fat", isOn: $alsoEstimateBodyFat)
                } footer: {
                    Text("After saving, opens AI body-fat estimate for this day’s photos (requires body profile in Settings).")
                }
            }
            .navigationTitle("Add Progress Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                LabelCameraPicker { image in
                    savePhoto(image)
                }
            }
            .onChange(of: selectedLibraryItem) { _, newItem in
                guard let newItem else { return }
                Task { await importLibraryPhoto(newItem) }
            }
            .sheet(item: $bodyFatAfterSaveRequest, onDismiss: { dismiss() }) { request in
                AIBodyFatEstimateView(
                    persistToDate: request.persistToDate,
                    initialPhotos: request.photos
                )
            }
            .alert("Could Not Save Photo", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func savePhoto(_ image: UIImage) {
        do {
            _ = try ProgressPhotoService.savePhoto(image, for: photoDate, context: context)
            if alsoEstimateBodyFat {
                let day = DateHelpers.startOfDay(photoDate)
                bodyFatAfterSaveRequest = BodyFatEstimateRequest(
                    persistToDate: day,
                    photos: ProgressPhotoService.photos(for: day, context: context)
                )
            } else {
                dismiss()
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func importLibraryPhoto(_ item: PhotosPickerItem) async {
        defer { selectedLibraryItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            saveError = "Could not load the selected photo."
            return
        }
        savePhoto(image)
    }
}

struct DiaryProgressPhotoCapture: View {
    let date: Date

    var body: some View {
        AddProgressPhotoSheet(initialDate: date)
    }
}
