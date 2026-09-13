import SwiftUI
import SwiftData

struct ExerciseSearchView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let onSelect: (Exercise) -> Void

    @State private var query = ""
    @State private var results: [SearchItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private enum SearchItem: Identifiable {
        case local(Exercise)
        case remote(WgerClient.SearchResult)

        var id: String {
            switch self {
            case .local(let exercise):
                return "local-\(exercise.id.uuidString)"
            case .remote(let result):
                return "wger-\(result.id)"
            }
        }

        var name: String {
            switch self {
            case .local(let exercise):
                return exercise.name
            case .remote(let result):
                return result.name
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                if isSearching {
                    HStack {
                        ProgressView()
                        Text(isSearching && results.isEmpty ? "Loading exercise catalog…" : "Searching…")
                    }
                }
                ForEach(results) { result in
                    Button {
                        selectResult(result)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(result.name)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await performSearch(newValue)
                }
            }
        }
    }

    private func performSearch(_ text: String) async {
        guard text.count >= 2 else {
            results = []
            return
        }
        let needle = text.lowercased()
        let localMatches = WorkoutService.allExercises(context: context)
            .filter { $0.name.lowercased().contains(needle) }
            .map { SearchItem.local($0) }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let remote = try await WgerClient.search(query: text)
            var seen = Set(localMatches.map(\.name))
            var merged = localMatches
            for result in remote where !seen.contains(result.name) {
                seen.insert(result.name)
                merged.append(.remote(result))
            }
            results = merged
        } catch {
            errorMessage = error.localizedDescription
            results = localMatches
        }
    }

    private func selectResult(_ item: SearchItem) {
        switch item {
        case .local(let exercise):
            onSelect(exercise)
            dismiss()
        case .remote(let result):
            Task {
                do {
                    let exercise = try await WorkoutService.cacheExercise(from: result, context: context)
                    onSelect(exercise)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
