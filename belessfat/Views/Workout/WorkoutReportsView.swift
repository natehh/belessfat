import SwiftUI
import SwiftData
import Charts

struct WorkoutReportsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \UserSettings.id) private var settingsQuery: [UserSettings]
    @State private var timeframe: ReportTimeframe = .week
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
    @State private var customEnd = Date()
    @State private var selectedExercise: Exercise?

    private var settings: UserSettings {
        settingsQuery.first ?? GoalService.settings(context: context)
    }

    private var includeToday: Bool {
        settings.effectiveWorkoutReportsIncludeToday
    }

    private var range: (start: Date, end: Date) {
        timeframe.dateRange(customStart: customStart, customEnd: customEnd, includeToday: includeToday)
    }

    private var rows: [WorkoutReportService.DailyWorkoutRow] {
        WorkoutReportService.dailyRows(from: range.start, to: range.end, context: context)
    }

    private var summary: WorkoutReportService.PeriodSummary {
        WorkoutReportService.periodSummary(rows: rows)
    }

    private var loggedExercises: [Exercise] {
        WorkoutService.loggedExercises(from: range.start, to: range.end, context: context)
    }

    private var exerciseTrend: [WorkoutReportService.ExerciseTrendPoint] {
        guard let selectedExercise else { return [] }
        return WorkoutReportService.exerciseTrend(
            exercise: selectedExercise,
            from: range.start,
            to: range.end,
            context: context
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    timeframePicker
                    summaryCard
                    sessionsChart
                    caloriesChart
                    exerciseTrendSection
                }
                .padding()
            }
            .navigationTitle("Workout Reports")
            .onAppear {
                if selectedExercise == nil {
                    selectedExercise = loggedExercises.first
                }
            }
            .onChange(of: loggedExercises.map(\.id)) { _, _ in
                if selectedExercise == nil || !loggedExercises.contains(where: { $0.id == selectedExercise?.id }) {
                    selectedExercise = loggedExercises.first
                }
            }
        }
    }

    private var timeframePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Timeframe", selection: $timeframe) {
                ForEach(ReportTimeframe.allCases) { tf in
                    Text(tf.rawValue).tag(tf)
                }
            }
            .pickerStyle(.segmented)
            if timeframe == .custom {
                DatePicker("Start", selection: $customStart, displayedComponents: .date)
                DatePicker("End", selection: $customEnd, displayedComponents: .date)
            } else {
                Toggle("Include today", isOn: includeTodayBinding)
                Text(timeframe.rangeLabel(start: range.start, end: range.end))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var includeTodayBinding: Binding<Bool> {
        Binding(
            get: { settings.effectiveWorkoutReportsIncludeToday },
            set: { newValue in
                settings.workoutReportsIncludeToday = newValue
                try? context.save()
            }
        )
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Period Summary")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                summaryTile(label: "Sessions", value: "\(summary.totalSessions)", unit: "total", color: .orange)
                summaryTile(label: "Avg / Day", value: summary.avgSessionsPerDay.formatted(.number.precision(.fractionLength(1))), unit: "sessions", color: .blue)
                summaryTile(label: "Minutes", value: summary.avgMinutesPerDay.formatted(.number.precision(.fractionLength(0))), unit: "avg/day", color: .green)
                summaryTile(label: "Calories", value: summary.avgCaloriesPerDay.formatted(.number.precision(.fractionLength(0))), unit: "avg/day", color: .red)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func summaryTile(label: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionsChart: some View {
        chartSection(title: "Sessions", subtitle: "Workouts per day") {
            Chart(rows) { row in
                BarMark(
                    x: .value("Date", row.date, unit: .day),
                    y: .value("Sessions", row.sessionCount)
                )
                .foregroundStyle(.orange.gradient)
            }
            .chartYScale(domain: 0...(max(rows.map(\.sessionCount).max() ?? 1, 1)))
            .frame(height: 180)
        }
    }

    private var caloriesChart: some View {
        chartSection(title: "Calories Burned", subtitle: "Estimated from logged workouts") {
            Chart(rows) { row in
                LineMark(
                    x: .value("Date", row.date, unit: .day),
                    y: .value("Calories", row.totalCalories)
                )
                .foregroundStyle(.red)
                PointMark(
                    x: .value("Date", row.date, unit: .day),
                    y: .value("Calories", row.totalCalories)
                )
                .foregroundStyle(.red)
            }
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private var exerciseTrendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exercise Trends")
                .font(.headline)
            if loggedExercises.isEmpty {
                Text("Log strength training to see exercise trends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Exercise", selection: $selectedExercise) {
                    ForEach(loggedExercises, id: \.id) { exercise in
                        Text(exercise.name).tag(exercise as Exercise?)
                    }
                }
                if let selectedExercise {
                    chartSection(title: selectedExercise.name, subtitle: "Max weight & volume") {
                        Chart(exerciseTrend) { point in
                            if let maxWeight = point.maxWeight {
                                LineMark(
                                    x: .value("Date", point.date, unit: .day),
                                    y: .value("Weight", maxWeight)
                                )
                                .foregroundStyle(.blue)
                                PointMark(
                                    x: .value("Date", point.date, unit: .day),
                                    y: .value("Weight", maxWeight)
                                )
                                .foregroundStyle(.blue)
                            }
                        }
                        .frame(height: 180)
                    }
                    chartSection(title: "Volume", subtitle: "Sets × reps × weight (lbs)") {
                        Chart(exerciseTrend) { point in
                            BarMark(
                                x: .value("Date", point.date, unit: .day),
                                y: .value("Volume", point.totalVolume)
                            )
                            .foregroundStyle(.purple.gradient)
                        }
                        .frame(height: 140)
                    }
                }
            }
        }
    }

    private func chartSection<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
