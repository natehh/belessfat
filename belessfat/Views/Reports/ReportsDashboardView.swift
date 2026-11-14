import SwiftUI
import SwiftData
import Charts

private struct GoalCardData {
    let goal: WeightGoal
    let current: Double
    let metrics: GoalMetrics
    let ahead: Double
}

struct ReportsDashboardView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var healthKit: HealthKitService
    @ObservedObject private var calorieTracking = CalorieTrackingDays.shared
    @Query(sort: \UserSettings.id) private var settingsQuery: [UserSettings]
    @Query(sort: \WeightGoal.startDate) private var weightGoals: [WeightGoal]
    @State private var timeframe: ReportTimeframe = .week
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
    @State private var customEnd = Date()
    @State private var showComparison = false
    @State private var showExport = false
    @State private var tdeeMethodologyExpanded = false
    @State private var tdeeDaysExpanded = false
    @State private var tdeeExclusionSnapshot: Set<Date> = []
    @State private var calorieChartDate: Date?
    @State private var macroChartDate: Date?
    @State private var weightChartDate: Date?
    @State private var bodyFatChartDate: Date?
    @State private var stepsChartDate: Date?
    @State private var activeCaloriesChartDate: Date?
    @State private var showWeightGoalMarkers = false

    private var settings: UserSettings {
        settingsQuery.first ?? GoalService.settings(context: context)
    }

    private var includeToday: Bool {
        settings.effectiveFoodReportsIncludeToday
    }

    private var range: (start: Date, end: Date) {
        timeframe.dateRange(customStart: customStart, customEnd: customEnd, includeToday: includeToday)
    }

    @State private var rows: [ReportService.DailyReportRow] = []
    @State private var averages: ReportService.DailyReportRow?
    @State private var comparison: ReportService.PeriodComparison?
    @State private var tdee: TDEECalculator.Result?
    @State private var goalCard: GoalCardData?
    @State private var weightSeries: [WeightEntry] = []
    @State private var weightMA: [(date: Date, value: Double)] = []
    @State private var bodyFatSeries: [BodyFatSample] = []
    @State private var bodyFatMA: [(date: Date, value: Double)] = []
    @State private var weeklyRows: [ReportService.WeeklySummaryRow] = []

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        timeframePicker
                        if let avg = averages {
                            averagesCard(avg)
                        }
                        if let tdee {
                            tdeeCard(tdee)
                        }
                        if let goalCard {
                            goalProgressCard(goalCard)
                        }
                        if showComparison {
                            if let comparison {
                                comparisonCard(comparison)
                            } else {
                                comparisonUnavailableCard
                            }
                        }
                        if !weeklyRows.isEmpty {
                            weeklySummaryTable
                        }
                        if !weightGoals.isEmpty {
                            Toggle("Show weight goal changes", isOn: $showWeightGoalMarkers)
                                .font(.subheadline)
                        }
                        calorieChart
                            .id("reportsCharts")
                        macroChart
                        weightChart
                        bodyFatChart
                        stepsChart
                        activeCaloriesChart
                    }
                    .padding()
                }
                .navigationTitle("Reports")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Export CSV") { showExport = true }
                            if healthKit.isAvailable {
                                Button("Sync Health Data for Period") {
                                    Task {
                                        await healthKit.sync(from: range.start, to: range.end, context: context)
                                        recompute()
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showComparison.toggle()
                        } label: {
                            Label(
                                "Compare",
                                systemImage: showComparison ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle"
                            )
                        }
                    }
                }
                .sheet(isPresented: $showExport) {
                    CSVExportView(rows: rows)
                }
                .onAppear { recompute() }
                .onChange(of: timeframe) { _, _ in recompute() }
                .onChange(of: customStart) { _, _ in recompute() }
                .onChange(of: customEnd) { _, _ in recompute() }
                .onChange(of: showComparison) { _, _ in recompute() }
                .onChange(of: calorieTracking.manualExclusions) { _, _ in recompute() }
                #if DEBUG
                .task {
                    guard AppStoreScreenshotSeeder.isEnabled,
                          AppStoreScreenshotSeeder.requestedScreen == "reportscharts" else { return }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    withAnimation {
                        proxy.scrollTo("reportsCharts", anchor: .top)
                    }
                }
                #endif
            }
        }
    }

    private func recompute() {
        let r = range
        let newRows = ReportService.dailyRows(from: r.start, to: r.end, context: context)
        rows = newRows
        averages = ReportService.averages(rows: newRows)

        if showComparison {
            let days = newRows.count
            if let prevEnd = Calendar.current.date(byAdding: .day, value: -1, to: r.start),
               let prevStart = Calendar.current.date(byAdding: .day, value: -(days - 1), to: prevEnd) {
                let previous = ReportService.dailyRows(from: prevStart, to: prevEnd, context: context)
                comparison = ReportService.comparePeriods(current: newRows, previous: previous)
            } else {
                comparison = nil
            }
        } else {
            comparison = nil
        }

        // Plot only weights in the selected range, but compute the MA with prior
        // lookback so the first days of a short window still use a full 7 weigh-ins.
        let weights = GoalService.weightEntries(from: r.start, to: r.end, context: context)
        weightSeries = weights
        let maLookbackStart = Calendar.current.date(byAdding: .day, value: -180, to: r.start) ?? r.start
        let weightsForMA = GoalService.weightEntries(from: maLookbackStart, to: r.end, context: context)
        let rangeStart = DateHelpers.startOfDay(r.start)
        weightMA = MacroCalculator.movingAverage(entries: weightsForMA)
            .filter { DateHelpers.startOfDay($0.date) >= rangeStart }

        let bodyFat = GoalService.bodyFatSamples(from: r.start, to: r.end, context: context)
        bodyFatSeries = bodyFat
        let bodyFatForMA = GoalService.bodyFatSamples(from: maLookbackStart, to: r.end, context: context)
        bodyFatMA = MacroCalculator.movingAverage(
            points: bodyFatForMA.map { (date: $0.date, value: $0.percent) }
        )
        .filter { DateHelpers.startOfDay($0.date) >= rangeStart }

        if let goal = GoalService.activeGoal(context: context) {
            let entries = GoalService.weightEntries(from: goal.startDate, to: Date(), context: context)
            let current = entries.last?.weightLbs ?? goal.startWeightLbs
            let metrics = GoalService.goalMetrics(currentWeight: current, goal: goal, entries: entries)
            goalCard = GoalCardData(
                goal: goal,
                current: current,
                metrics: metrics,
                ahead: metrics.progressPercent - metrics.timePercent
            )
        } else {
            goalCard = nil
        }

        let summaryEnd = includeToday ? DateHelpers.startOfDay(Date()) : (Calendar.current.date(byAdding: .day, value: -1, to: DateHelpers.startOfDay(Date())) ?? DateHelpers.startOfDay(Date()))
        if let anchor = ReportService.weeklySummaryAnchorDate(context: context) {
            weeklyRows = ReportService.weeklySummaryRows(
                from: anchor,
                to: summaryEnd,
                weekStartsOn: settings.weekStartDay,
                context: context
            )
        } else {
            weeklyRows = []
        }

        recomputeTDEE()
    }

    private func recomputeTDEE() {
        tdee = TDEECalculator.estimate(context: context)
    }

    private func currentExcludedDays(in report: TDEECalculator.Result) -> Set<Date> {
        Set(report.days.filter { !$0.isIncluded }.map(\.date))
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
            get: { settings.effectiveFoodReportsIncludeToday },
            set: { newValue in
                settings.foodReportsIncludeToday = newValue
                try? context.save()
                recompute()
            }
        )
    }

    private func averagesCard(_ avg: ReportService.DailyReportRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily Averages")
                .font(.headline)
            Text("Typical day in this period")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                averageTile(label: "Calories", value: "\(Int(avg.calories))", unit: "kcal", color: .orange)
                averageTile(
                    label: "Net Calories",
                    value: "\(Int(avg.netCalories))",
                    unit: "kcal",
                    color: avg.netCalories < 0 ? .green : .primary
                )
                averageTile(
                    label: "Protein",
                    value: avg.protein.formatted(.number.precision(.fractionLength(0))),
                    unit: "g",
                    color: .blue
                )
                averageTile(
                    label: "Carbs",
                    value: avg.carbs.formatted(.number.precision(.fractionLength(0))),
                    unit: "g",
                    color: .green
                )
                averageTile(
                    label: "Fat",
                    value: avg.fat.formatted(.number.precision(.fractionLength(0))),
                    unit: "g",
                    color: .purple
                )
                averageTile(label: "Steps", value: "\(avg.steps)", unit: "steps", color: .cyan)
                if let weight = avg.weight {
                    averageTile(
                        label: "Weight",
                        value: weight.formatted(.number.precision(.fractionLength(1))),
                        unit: "lbs",
                        color: .indigo
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func averageTile(label: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var weeklySummaryTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weekly Summary")
                .font(.headline)
            Text("Averages by week from your goal start (or earliest data). Weight Δ % is week over week; the total row averages those weekly values.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    weeklySummaryHeader
                    ForEach(Array(weeklyRows.enumerated()), id: \.element.id) { index, row in
                        weeklySummaryRowView(row, striped: index.isMultiple(of: 2))
                    }
                    if let totals = ReportService.weeklySummaryTotals(from: weeklyRows) {
                        weeklySummaryTotalsRow(totals)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.separator), lineWidth: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var weeklySummaryHeader: some View {
        HStack(spacing: 0) {
            weeklyHeaderCell("Week #", width: 72, color: Color(.systemGray4))
            weeklyHeaderCell("Week Of", width: 92, color: Color(.systemGray5))
            weeklyHeaderCell("Steps Avg", width: 88, color: Color.cyan.opacity(0.35))
            weeklyHeaderCell("Calorie Avg", width: 92, color: Color.orange.opacity(0.35))
            weeklyHeaderCell("Weight Avg", width: 88, color: Color.pink.opacity(0.35))
            weeklyHeaderCell("Body Fat Avg", width: 96, color: Color.indigo.opacity(0.35))
            weeklyHeaderCell("Weight Δ %", width: 88, color: Color.yellow.opacity(0.4))
        }
    }

    private func weeklySummaryRowView(_ row: ReportService.WeeklySummaryRow, striped: Bool) -> some View {
        let base = striped ? Color(.tertiarySystemBackground) : Color(.systemBackground)
        return HStack(spacing: 0) {
            weeklyBodyCell("Week \(row.weekNumber)", width: 72, background: Color(.systemGray5).opacity(0.55))
            weeklyBodyCell(
                row.weekOf.formatted(.dateTime.month(.defaultDigits).day().year()),
                width: 92,
                background: base
            )
            weeklyBodyCell(
                row.stepsAverage.map { Int($0.rounded()).formatted() } ?? "—",
                width: 88,
                background: Color.cyan.opacity(striped ? 0.18 : 0.10)
            )
            weeklyBodyCell(
                row.calorieAverage.map { Int($0.rounded()).formatted() } ?? "—",
                width: 92,
                background: Color.orange.opacity(striped ? 0.22 : 0.12)
            )
            weeklyBodyCell(
                row.weightAverage.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—",
                width: 88,
                background: Color.pink.opacity(striped ? 0.20 : 0.10)
            )
            weeklyBodyCell(
                row.bodyFatAverage.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                width: 96,
                background: Color.indigo.opacity(striped ? 0.20 : 0.10)
            )
            weeklyBodyCell(
                weightChangeLabel(row.weightChangePercent),
                width: 88,
                background: Color.yellow.opacity(striped ? 0.28 : 0.14)
            )
        }
    }

    private func weeklySummaryTotalsRow(_ row: ReportService.WeeklySummaryRow) -> some View {
        HStack(spacing: 0) {
            weeklyBodyCell("Total", width: 72, background: Color(.systemGray4), bold: true)
            weeklyBodyCell("—", width: 92, background: Color(.systemGray5), bold: true)
            weeklyBodyCell(
                row.stepsAverage.map { Int($0.rounded()).formatted() } ?? "—",
                width: 88,
                background: Color.cyan.opacity(0.4),
                bold: true
            )
            weeklyBodyCell(
                row.calorieAverage.map { Int($0.rounded()).formatted() } ?? "—",
                width: 92,
                background: Color.orange.opacity(0.4),
                bold: true
            )
            weeklyBodyCell(
                row.weightAverage.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—",
                width: 88,
                background: Color.pink.opacity(0.4),
                bold: true
            )
            weeklyBodyCell(
                row.bodyFatAverage.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                width: 96,
                background: Color.indigo.opacity(0.4),
                bold: true
            )
            weeklyBodyCell(
                weightChangeLabel(row.weightChangePercent),
                width: 88,
                background: Color.yellow.opacity(0.5),
                bold: true
            )
        }
    }

    private func weeklyHeaderCell(_ title: String, width: CGFloat, color: Color) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(width: width, height: 44)
            .background(color)
    }

    private func weeklyBodyCell(_ text: String, width: CGFloat, background: Color, bold: Bool = false) -> some View {
        Text(text)
            .font(bold ? .caption.weight(.semibold).monospacedDigit() : .caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: width, height: 34)
            .background(background)
    }

    private func weightChangeLabel(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        let formatted = abs(percent).formatted(.number.precision(.fractionLength(2)))
        if percent > 0 { return "+\(formatted)%" }
        if percent < 0 { return "-\(formatted)%" }
        return "0.00%"
    }

    private func goalProgressCard(_ data: GoalCardData) -> some View {
        let goal = data.goal
        let current = data.current
        let metrics = data.metrics
        let ahead = data.ahead

        return VStack(alignment: .leading, spacing: 12) {
            Text("Weight Goal Progress")
                .font(.headline)
            HStack(spacing: 16) {
                goalMetricColumn(title: "Weight", percent: metrics.progressPercent, color: .blue)
                goalMetricColumn(title: "Time", percent: metrics.timePercent, color: .orange)
            }
            Text(ahead >= 0
                 ? "\(abs(ahead).formatted(.number.precision(.fractionLength(1))))% ahead of schedule"
                 : "\(abs(ahead).formatted(.number.precision(.fractionLength(1))))% behind schedule")
                .font(.subheadline)
                .foregroundStyle(ahead >= 0 ? .green : .red)
            HStack {
                VStack(alignment: .leading) {
                    Text("Start")
                    Text("\(goal.startWeightLbs.formatted()) lbs")
                        .fontWeight(.semibold)
                }
                Spacer()
                VStack {
                    Text("Current")
                    Text("\(current.formatted()) lbs")
                        .fontWeight(.semibold)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Goal")
                    Text("\(goal.goalWeightLbs.formatted()) lbs")
                        .fontWeight(.semibold)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func goalMetricColumn(title: String, percent: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(0, percent / 100) * 120, height: 12)
            }
            .frame(width: 120)
            Text("\(percent.formatted(.number.precision(.fractionLength(1))))%")
                .font(.caption2)
        }
    }

    private func comparisonCard(_ c: ReportService.PeriodComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("vs Previous Period")
                .font(.headline)
            Text("Daily averages compared to the prior \(rows.count)-day period")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Calories Δ", value: deltaText(c.caloriesDelta, unit: "kcal"))
            LabeledContent("Protein Δ", value: deltaText(c.proteinDelta, unit: "g"))
            LabeledContent("Steps Δ", value: deltaText(c.stepsDelta, unit: ""))
            if let w = c.weightDelta {
                LabeledContent("Weight Δ", value: deltaText(w, unit: "lbs"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var comparisonUnavailableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("vs Previous Period")
                .font(.headline)
            Text("Not enough data to compare. Log food and weight across both periods, or widen the date range.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tdeeCard(_ report: TDEECalculator.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated TDEE")
                    .font(.headline)
                Spacer()
                if !report.usesAllDays {
                    Text("Some days excluded")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            if let tdee = report.estimate {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(tdee.estimatedTDEE.rounded()))")
                        .font(.largeTitle.weight(.bold))
                    Text("kcal/day to maintain weight")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if tdee.isProvisional {
                    Text("Estimate is still stabilizing — log food and weight regularly over the next week for a firmer number.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                VStack(spacing: 8) {
                    LabeledContent("You averaged") {
                        Text("\(Int(tdee.averageDailyCalories.rounded())) kcal eaten/day")
                    }
                    LabeledContent("Weight trend") {
                        Text(tdee.weightTrendLabel)
                    }
                    LabeledContent("Compared to maintenance") {
                        Text(tdee.eatVsBurnLabel)
                            .foregroundStyle(tdee.calorieGap > 50 ? .orange : (tdee.calorieGap < -50 ? .green : .primary))
                    }
                }
                .font(.subheadline)
            } else {
                Text("Not enough included days to estimate. Open How this is calculated and include more days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $tdeeMethodologyExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if let tdee = report.estimate {
                        Text("Uses the last \(tdee.lookbackDays) days (\(tdee.dayCount) days with food logged, \(tdee.weightEntryCount) weight logs).")
                    } else {
                        Text("Uses the last \(report.lookbackDays) days. Include at least 3 days with food and 2 weigh-ins.")
                    }
                    Text("Intake is the average of days with food logged (empty days are skipped, not counted as zero). Weight trend is a linear fit on 7-day smoothed weights, so a one-off weigh-in does not jump the number.")
                    Text("TDEE = average intake − (weight trend × 3,500 kcal/lb). As the 28-day window rolls forward, real changes show up over days rather than weeks.")
                    Text("Example: eating 2,000 kcal/day while losing 1 lb/week implies about 2,500 kcal/day maintenance.")
                    DisclosureGroup(isExpanded: $tdeeDaysExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Uncheck a day to leave that day’s food and weight out. New days start included, and days older than \(report.lookbackDays) drop off on their own.")
                            HStack {
                                Button("Reset") {
                                    TDEEExcludedDays.replace(with: tdeeExclusionSnapshot)
                                    recomputeTDEE()
                                }
                                .disabled(currentExcludedDays(in: report) == tdeeExclusionSnapshot)
                                Spacer()
                                Button("Select All") {
                                    TDEEExcludedDays.replace(with: [])
                                    recomputeTDEE()
                                }
                                .disabled(report.usesAllDays)
                            }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.primary)
                            ForEach(report.days) { day in
                                Button {
                                    TDEEExcludedDays.setIncluded(!day.isIncluded, day: day.date)
                                    recomputeTDEE()
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: day.isIncluded ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(day.isIncluded ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                                .foregroundStyle(.primary)
                                            Text(day.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.subheadline)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("Days used")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .onChange(of: tdeeDaysExpanded) { _, isExpanded in
                        if isExpanded {
                            tdeeExclusionSnapshot = TDEEExcludedDays.current()
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            } label: {
                Text("How this is calculated")
                    .font(.subheadline.weight(.medium))
            }

            Text("For reference only — your calorie targets in Settings are not changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func deltaText(_ value: Double, unit: String) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(value.formatted(.number.precision(.fractionLength(1)))) \(unit)"
    }

    private var calorieChart: some View {
        interactiveChartSection(
            title: "Calories",
            subtitle: "Total calories consumed per day"
        ) {
            if let date = calorieChartDate, let row = row(for: date) {
                chartTooltip(
                    date: date,
                    lines: [("Calories", "\(Int(row.calories)) kcal", .orange)]
                )
            }
        } chart: {
            Chart {
                ForEach(rows) { row in
                    BarMark(x: .value("Date", row.date, unit: .day), y: .value("Calories", row.calories))
                        .foregroundStyle(.orange.gradient)
                }
                weightGoalChangeMarks()
                if let date = calorieChartDate {
                    RuleMark(x: .value("Date", date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .interactiveDateSelection($calorieChartDate)
        }
    }

    private var macroChart: some View {
        interactiveChartSection(
            title: "Macros",
            subtitle: "Stacked grams per day (tooltip shows % of calories)"
        ) {
            if let date = macroChartDate, let row = row(for: date) {
                let pct = MacroCalculator.macroCaloriePercents(protein: row.protein, carbs: row.carbs, fat: row.fat)
                chartTooltip(
                    date: date,
                    lines: [
                        ("Protein", "\(row.protein.formatted(.number.precision(.fractionLength(0)))) g · \(pct.protein.formatted(.number.precision(.fractionLength(0))))%", .blue),
                        ("Carbs", "\(row.carbs.formatted(.number.precision(.fractionLength(0)))) g · \(pct.carbs.formatted(.number.precision(.fractionLength(0))))%", .green),
                        ("Fat", "\(row.fat.formatted(.number.precision(.fractionLength(0)))) g · \(pct.fat.formatted(.number.precision(.fractionLength(0))))%", .purple)
                    ]
                )
            }
        } chart: {
            Chart {
                ForEach(rows) { row in
                    BarMark(
                        x: .value("Date", row.date, unit: .day),
                        y: .value("Grams", row.protein)
                    )
                    .foregroundStyle(by: .value("Macro", "Protein"))
                    BarMark(
                        x: .value("Date", row.date, unit: .day),
                        y: .value("Grams", row.carbs)
                    )
                    .foregroundStyle(by: .value("Macro", "Carbs"))
                    BarMark(
                        x: .value("Date", row.date, unit: .day),
                        y: .value("Grams", row.fat)
                    )
                    .foregroundStyle(by: .value("Macro", "Fat"))
                }
                weightGoalChangeMarks()
                if let date = macroChartDate {
                    RuleMark(x: .value("Date", date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .chartForegroundStyleScale([
                "Protein": Color.blue,
                "Carbs": Color.green,
                "Fat": Color.purple
            ])
            .interactiveDateSelection($macroChartDate)
        } footer: {
            HStack(spacing: 14) {
                macroLegendItem("Protein", .blue)
                macroLegendItem("Carbs", .green)
                macroLegendItem("Fat", .purple)
            }
        }
    }

    private func macroLegendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }

    private var weightChart: some View {
        let weights = weightSeries
        let ma = weightMA
        let yDomain = weightChartYDomain(weights: weights, movingAverage: ma)
        return interactiveChartSection(
            title: "Weight",
            subtitle: "Logged weight and 7-day moving average"
        ) {
            if let date = weightChartDate {
                let logged = weights.first { DateHelpers.isSameDay($0.date, date) }
                let avg = ma.first { DateHelpers.isSameDay($0.date, date) }
                if logged != nil || avg != nil {
                    chartTooltip(
                        date: date,
                        lines: [
                            logged.map { ("Weight", "\($0.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs", Color.primary) },
                            avg.map { ("7-day avg", "\($0.value.formatted(.number.precision(.fractionLength(1)))) lbs", .orange) }
                        ].compactMap { $0 }
                    )
                }
            }
        } chart: {
            Chart {
                ForEach(weights, id: \.id) { entry in
                    PointMark(x: .value("Date", entry.date, unit: .day), y: .value("Weight", entry.weightLbs))
                }
                ForEach(ma, id: \.date) { point in
                    LineMark(x: .value("Date", point.date, unit: .day), y: .value("7-day MA", point.value))
                        .foregroundStyle(.orange)
                }
                weightGoalChangeMarks()
                if let date = weightChartDate {
                    RuleMark(x: .value("Date", date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .chartYScale(domain: yDomain)
            .interactiveDateSelection($weightChartDate)
        }
    }

    private var bodyFatChart: some View {
        let samples = bodyFatSeries
        let ma = bodyFatMA
        let yDomain = bodyFatChartYDomain(samples: samples, movingAverage: ma)
        return interactiveChartSection(
            title: "Body Fat",
            subtitle: "Logged body fat and 7-day moving average"
        ) {
            if let date = bodyFatChartDate {
                let logged = samples.first { DateHelpers.isSameDay($0.date, date) }
                let avg = ma.first { DateHelpers.isSameDay($0.date, date) }
                if logged != nil || avg != nil {
                    chartTooltip(
                        date: date,
                        lines: [
                            logged.map { ("Body fat", "\($0.percent.formatted(.number.precision(.fractionLength(1))))%", Color.primary) },
                            avg.map { ("7-day avg", "\($0.value.formatted(.number.precision(.fractionLength(1))))%", .orange) }
                        ].compactMap { $0 }
                    )
                }
            }
        } chart: {
            Chart {
                ForEach(samples) { sample in
                    PointMark(x: .value("Date", sample.date, unit: .day), y: .value("Body Fat", sample.percent))
                }
                ForEach(ma, id: \.date) { point in
                    LineMark(x: .value("Date", point.date, unit: .day), y: .value("7-day MA", point.value))
                        .foregroundStyle(.orange)
                }
                weightGoalChangeMarks()
                if let date = bodyFatChartDate {
                    RuleMark(x: .value("Date", date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .chartYScale(domain: yDomain)
            .interactiveDateSelection($bodyFatChartDate)
        }
    }

    private func bodyFatChartYDomain(
        samples: [BodyFatSample],
        movingAverage: [(date: Date, value: Double)]
    ) -> ClosedRange<Double> {
        let values = samples.map(\.percent) + movingAverage.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 15...30
        }
        return (minValue - 1)...(maxValue + 1)
    }

    private func weightChartYDomain(
        weights: [WeightEntry],
        movingAverage: [(date: Date, value: Double)]
    ) -> ClosedRange<Double> {
        let values = weights.map(\.weightLbs) + movingAverage.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 150...200
        }
        return (minValue - 1)...(maxValue + 1)
    }

    private var stepsChart: some View {
        interactiveChartSection(
            title: "Steps",
            subtitle: "Steps per day from HealthKit"
        ) {
            if let date = stepsChartDate, let row = row(for: date) {
                chartTooltip(
                    date: date,
                    lines: [("Steps", "\(row.steps)", .cyan)]
                )
            }
        } chart: {
            Chart {
                ForEach(rows) { row in
                    BarMark(x: .value("Date", row.date, unit: .day), y: .value("Steps", row.steps))
                        .foregroundStyle(.cyan.gradient)
                }
                weightGoalChangeMarks()
                if let date = stepsChartDate {
                    RuleMark(x: .value("Date", date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .interactiveDateSelection($stepsChartDate)
        }
    }

    private var activeCaloriesChart: some View {
        interactiveChartSection(
            title: "Active Calories",
            subtitle: "Active energy burned per day from HealthKit"
        ) {
            if let date = activeCaloriesChartDate, let row = row(for: date) {
                chartTooltip(
                    date: date,
                    lines: [("Active", "\(Int(row.activeCalories)) kcal", .red)]
                )
            }
        } chart: {
            Chart {
                ForEach(rows) { row in
                    LineMark(x: .value("Date", row.date, unit: .day), y: .value("Active", row.activeCalories))
                        .foregroundStyle(.red)
                        .symbol(Circle().strokeBorder(lineWidth: 2))
                }
                weightGoalChangeMarks()
                if let date = activeCaloriesChartDate {
                    RuleMark(x: .value("Date", date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .interactiveDateSelection($activeCaloriesChartDate)
        }
    }

    private var weightGoalMarkerDates: [Date] {
        let start = DateHelpers.startOfDay(range.start)
        let end = DateHelpers.startOfDay(range.end)
        var seen = Set<Date>()
        return weightGoals.compactMap { goal in
            let day = DateHelpers.startOfDay(goal.startDate)
            guard day >= start, day <= end, seen.insert(day).inserted else { return nil }
            return day
        }
    }

    @ChartContentBuilder
    private func weightGoalChangeMarks() -> some ChartContent {
        if showWeightGoalMarkers {
            ForEach(weightGoalMarkerDates, id: \.self) { day in
                RuleMark(x: .value("Weight goal", day, unit: .day))
                    .foregroundStyle(Color.indigo.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [1, 3]))
            }
        }
    }

    private func row(for date: Date) -> ReportService.DailyReportRow? {
        rows.first { DateHelpers.isSameDay($0.date, date) }
    }

    @ViewBuilder
    private func interactiveChartSection<ChartContent: View, Tooltip: View, Footer: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder tooltip: () -> Tooltip,
        @ViewBuilder chart: () -> ChartContent,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            footer()
            ZStack(alignment: .top) {
                chart()
                    .frame(height: 180)
                tooltip()
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func chartTooltip(date: Date, lines: [(String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption.weight(.semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text(line.0)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(line.1)
                        .fontWeight(.medium)
                        .foregroundStyle(line.2)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

private extension View {
    func interactiveDateSelection(_ selection: Binding<Date?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let plotFrame = geometry[proxy.plotAreaFrame]
                                let xPosition = value.location.x - plotFrame.origin.x
                                guard xPosition >= 0, xPosition <= plotFrame.width else {
                                    selection.wrappedValue = nil
                                    return
                                }
                                selection.wrappedValue = proxy.value(atX: xPosition, as: Date.self)
                            }
                            .onEnded { _ in
                                selection.wrappedValue = nil
                            }
                    )
            }
        }
    }
}

struct CSVExportView: View {
    @Environment(\.dismiss) private var dismiss
    let rows: [ReportService.DailyReportRow]
    @State private var options = CSVExporter.ExportOptions()
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Include") {
                    Toggle("Calories", isOn: $options.includeCalories)
                    Toggle("Protein", isOn: $options.includeProtein)
                    Toggle("Carbs", isOn: $options.includeCarbs)
                    Toggle("Fat", isOn: $options.includeFat)
                    Toggle("Weight", isOn: $options.includeWeight)
                    Toggle("Steps", isOn: $options.includeSteps)
                    Toggle("Active Calories", isOn: $options.includeActiveCalories)
                    Toggle("Net Calories", isOn: $options.includeNetCalories)
                }
                Picker("Aggregation", selection: $options.aggregation) {
                    ForEach(CSVExporter.ExportOptions.Aggregation.allCases, id: \.self) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
            }
            .navigationTitle("Export CSV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { export() }
                }
            }
            .sheet(item: $shareURL) { url in
                ShareSheet(items: [url])
            }
        }
    }

    private func export() {
        let csv = CSVExporter.export(options: options, dailyData: rows)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("belessfat-export.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        shareURL = url
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
