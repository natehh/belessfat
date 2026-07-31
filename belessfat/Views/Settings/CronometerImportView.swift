import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct CronometerImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var preview: CronometerImporter.ImportPreview?
    @State private var dailyOptions = CronometerImporter.ImportOptions()
    @State private var biometricsOptions = CronometerImporter.BiometricsImportOptions()
    @State private var message = ""
    @State private var isError = false
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Import Cronometer exports: Daily Summary (dailysummary.csv) for calories/macros, or Biometrics (biometrics.csv) for weight. The file type is detected automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose CSV File") { showImporter = true }
                }

                if let preview {
                    previewSection(preview)
                    optionsSection(preview)
                    importSection(preview)
                }

                if !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(isError ? .red : .primary)
                    }
                }
            }
            .navigationTitle("Cronometer Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .data]
            ) { result in
                switch result {
                case .success(let url):
                    loadCSV(from: url)
                case .failure(let error):
                    showMessage(error.localizedDescription, error: true)
                }
            }
        }
    }

    @ViewBuilder
    private func previewSection(_ preview: CronometerImporter.ImportPreview) -> some View {
        Section("Preview") {
            switch preview {
            case .dailySummary(let data):
                LabeledContent("File type", value: "Daily Summary")
                LabeledContent("Days with calories", value: "\(data.rows.count)")
                dateRangeRow(data.dateRange)
                if let sample = data.rows.first, let last = data.rows.last {
                    LabeledContent("Sample day", value: "\(Int(sample.calories)) kcal on \(formatted(sample.date))")
                    if sample.date != last.date {
                        LabeledContent("Latest day", value: "\(Int(last.calories)) kcal on \(formatted(last.date))")
                    }
                }
            case .biometrics(let data):
                LabeledContent("File type", value: "Biometrics (Weight)")
                LabeledContent("Weight entries", value: "\(data.rows.count)")
                dateRangeRow(data.dateRange)
                if let sample = data.rows.first, let last = data.rows.last {
                    LabeledContent("Sample", value: "\(sample.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs on \(formatted(sample.date))")
                    if sample.date != last.date {
                        LabeledContent("Latest", value: "\(last.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs on \(formatted(last.date))")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func optionsSection(_ preview: CronometerImporter.ImportPreview) -> some View {
        Section("Options") {
            switch preview {
            case .dailySummary:
                Toggle("Skip days that already have food logged", isOn: $dailyOptions.skipDaysWithExistingEntries)
                Toggle("Replace previous Cronometer imports", isOn: $dailyOptions.replacePreviousCronometerImports)
            case .biometrics:
                Toggle("Skip days that already have weight logged", isOn: $biometricsOptions.skipDaysWithExistingWeight)
            }
        }
    }

    @ViewBuilder
    private func importSection(_ preview: CronometerImporter.ImportPreview) -> some View {
        let count = importCount(preview)
        Section {
            Button {
                runImport(preview)
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Text(importButtonTitle(preview, count: count))
                }
            }
            .disabled(isImporting || count == 0)
        }
    }

    private func dateRangeRow(_ range: ClosedRange<Date>?) -> some View {
        Group {
            if let range {
                LabeledContent("Date range", value: "\(formatted(range.lowerBound)) – \(formatted(range.upperBound))")
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func importCount(_ preview: CronometerImporter.ImportPreview) -> Int {
        switch preview {
        case .dailySummary(let data): return data.rows.count
        case .biometrics(let data): return data.rows.count
        }
    }

    private func importButtonTitle(_ preview: CronometerImporter.ImportPreview, count: Int) -> String {
        switch preview {
        case .dailySummary:
            return "Import \(count) Days"
        case .biometrics:
            return "Import \(count) Weight Entries"
        }
    }

    private func loadCSV(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            showMessage("Could not access the selected file.", error: true)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            showMessage("Could not read the selected file.", error: true)
            return
        }

        do {
            preview = try CronometerImporter.preview(from: csv)
            message = ""
            isError = false
        } catch {
            preview = nil
            showMessage(error.localizedDescription, error: true)
        }
    }

    private func runImport(_ preview: CronometerImporter.ImportPreview) {
        isImporting = true
        defer { isImporting = false }

        do {
            switch preview {
            case .dailySummary(let data):
                let result = try CronometerImporter.importDailySummary(data.rows, options: dailyOptions, context: context)
                var parts = ["Imported \(result.imported) days."]
                if result.skippedExisting > 0 {
                    parts.append("Skipped \(result.skippedExisting) days with existing food logs.")
                }
                if result.replaced > 0 {
                    parts.append("Replaced \(result.replaced) previous Cronometer entries.")
                }
                showMessage(parts.joined(separator: " "), error: false)
            case .biometrics(let data):
                let result = try CronometerImporter.importBiometrics(data.rows, options: biometricsOptions, context: context)
                var parts = ["Imported \(result.imported) weight entries."]
                if result.skippedExisting > 0 {
                    parts.append("Skipped \(result.skippedExisting) days with existing weight.")
                }
                showMessage(parts.joined(separator: " "), error: false)
            }
        } catch {
            showMessage(error.localizedDescription, error: true)
        }
    }

    private func showMessage(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
