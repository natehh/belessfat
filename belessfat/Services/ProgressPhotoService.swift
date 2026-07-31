import Foundation
import SwiftData
import UIKit

@MainActor
enum ProgressPhotoService {
    enum StorageError: LocalizedError {
        case failedToEncodeImage

        var errorDescription: String? {
            switch self {
            case .failedToEncodeImage: return "Could not save the photo."
            }
        }
    }

    private static var photosDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("progress_photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func imageURL(for photo: ProgressPhoto) -> URL {
        photosDirectory.appendingPathComponent(photo.imageFilename)
    }

    static func allPhotos(context: ModelContext) -> [ProgressPhoto] {
        let descriptor = FetchDescriptor<ProgressPhoto>(
            sortBy: [
                SortDescriptor(\.date, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func photos(for date: Date, context: ModelContext) -> [ProgressPhoto] {
        let day = DateHelpers.startOfDay(date)
        return allPhotos(context: context).filter { DateHelpers.isSameDay($0.date, day) }
    }

    static func weightSnapshot(for date: Date, context: ModelContext) -> (weightLbs: Double?, weight7DayAvgLbs: Double?) {
        let day = DateHelpers.startOfDay(date)
        if let daily = GoalService.weightEntry(for: day, context: context)?.weightLbs {
            return (daily, nil)
        }
        if let average = GoalService.sevenDayAverageWeight(for: day, context: context) {
            return (nil, average)
        }
        return (nil, nil)
    }

    @discardableResult
    static func savePhoto(_ image: UIImage, for date: Date, context: ModelContext) throws -> ProgressPhoto {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let fileURL = photosDirectory.appendingPathComponent(filename)
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw StorageError.failedToEncodeImage
        }
        try data.write(to: fileURL, options: .atomic)

        let snapshot = weightSnapshot(for: date, context: context)
        let photo = ProgressPhoto(
            date: date,
            imageFilename: filename,
            weightLbs: snapshot.weightLbs,
            weight7DayAvgLbs: snapshot.weight7DayAvgLbs
        )
        context.insert(photo)
        try context.save()
        return photo
    }

    static func delete(_ photo: ProgressPhoto, context: ModelContext) {
        let url = imageURL(for: photo)
        try? FileManager.default.removeItem(at: url)
        context.delete(photo)
        try? context.save()
    }

    static func deleteAll(context: ModelContext) {
        let photos = allPhotos(context: context)
        for photo in photos {
            try? FileManager.default.removeItem(at: imageURL(for: photo))
            context.delete(photo)
        }
        try? context.save()
    }

    /// Effective weight for prompts: day snapshot, else closest prior weigh-in.
    static func weightForEstimate(on date: Date, context: ModelContext) -> (lbs: Double, label: String)? {
        let snapshot = weightSnapshot(for: date, context: context)
        if let daily = snapshot.weightLbs {
            return (daily, "\(daily.formatted(.number.precision(.fractionLength(1)))) lbs (logged that day)")
        }
        if let avg = snapshot.weight7DayAvgLbs {
            return (avg, "\(avg.formatted(.number.precision(.fractionLength(1)))) lbs (7-day average)")
        }
        if let prior = GoalService.mostRecentWeight(onOrBefore: date, context: context) {
            return (prior, "\(prior.formatted(.number.precision(.fractionLength(1)))) lbs (closest prior weigh-in)")
        }
        return nil
    }

    static func bodyFatPercent(for date: Date, context: ModelContext) -> Double? {
        photos(for: date, context: context).compactMap(\.bodyFatPercent).first
    }

    static func applyBodyFatEstimate(
        _ percent: Double,
        toDate date: Date,
        context: ModelContext
    ) {
        let dayPhotos = photos(for: date, context: context)
        guard !dayPhotos.isEmpty else { return }
        let now = Date()
        for photo in dayPhotos {
            photo.bodyFatPercent = percent
            photo.bodyFatEstimatedAt = now
        }
        try? context.save()
    }

    static func loadImages(for photos: [ProgressPhoto]) -> [UIImage] {
        photos.compactMap { photo in
            UIImage(contentsOfFile: imageURL(for: photo).path)
        }
    }
}
