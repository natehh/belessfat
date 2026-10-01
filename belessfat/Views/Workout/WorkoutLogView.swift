import SwiftUI
import SwiftData

struct WorkoutLogView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var healthKit: HealthKitService
    @Query(sort: \WorkoutSession.createdAt, order: .forward) private var allSessions: [WorkoutSession]
    @State private var selectedDate = Date()
    @State private var showAddWorkout = false
    @State private var showTemplates = false
    @State private var editingSession: WorkoutSession?

    private var sessions: [WorkoutSession] {
        allSessions.filter { DateHelpers.isSameDay($0.date, selectedDate) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions, id: \.id) { session in
                    Button {
                        editingSession = session
                    } label: {
                        WorkoutSessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    let toDelete = indexSet.map { sessions[$0] }
                    Task {
                        for session in toDelete {
                            await WorkoutService.deleteSession(session, healthKit: healthKit, context: context)
                        }
                    }
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Workouts",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Log a workout for this day.")
                    )
                }
            }
            .navigationTitle("Workout Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showTemplates = true
                    } label: {
                        Label("Templates", systemImage: "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddWorkout = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                dayPicker
            }
            .sheet(isPresented: $showAddWorkout) {
                AddWorkoutSheet(date: selectedDate)
            }
            .sheet(isPresented: $showTemplates) {
                WorkoutTemplateListView()
            }
            .sheet(item: $editingSession) { session in
                if session.workoutType == .strength {
                    StrengthWorkoutLogView(session: session)
                } else {
                    CardioWorkoutDetailView(session: session)
                }
            }
        }
    }

    private var isViewingToday: Bool {
        DateHelpers.isSameDay(selectedDate, Date())
    }

    private var dayPicker: some View {
        VStack(spacing: 4) {
            HStack {
                Button {
                    selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .labelsHidden()
                Spacer()
                Button {
                    selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
            if !isViewingToday {
                Button("Today") {
                    selectedDate = Date()
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct WorkoutSessionRow: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: session.workoutType.systemImage)
                    .foregroundStyle(.orange)
                Text(session.displayTitle)
                    .font(.headline)
                Spacer()
                if session.syncToHealthKit {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
            }
            HStack(spacing: 12) {
                if session.isInProgress {
                    Label("In progress", systemImage: "record.circle")
                        .foregroundStyle(.orange)
                } else {
                    Label(session.effectiveWorkoutEnd.formatted(date: .omitted, time: .shortened), systemImage: "calendar")
                    if session.durationMinutes > 0 {
                        Label("\(Int(session.durationMinutes.rounded())) min", systemImage: "clock")
                    }
                }
                if session.estimatedCalories > 0 {
                    Label("\(Int(session.estimatedCalories)) kcal", systemImage: "flame")
                }
                if session.estimatedSteps > 0 {
                    Label("\(session.estimatedSteps) steps", systemImage: "figure.walk")
                }
                if session.workoutType == .strength {
                    if session.isLive {
                        Label("\(session.completedSetCount)/\(session.setLogs.count) sets", systemImage: "number")
                    } else {
                        Label("\(session.setLogs.count) sets", systemImage: "number")
                    }
                }
                if session.workoutType == .swimming, let distance = session.swimDistanceLabel {
                    Label(distance, systemImage: "figure.pool.swim")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension WorkoutSession: Identifiable {}
