import SwiftUI

struct MacroProgressView: View {
    let totals: MacroTotals
    let targets: GoalService.MacroTargets
    let mode: MacroDisplayMode

    var body: some View {
        VStack(spacing: 12) {
            MacroBar(label: "Calories", current: totals.calories, target: targets.calories, unit: "kcal", color: .orange, mode: mode)
            MacroBar(label: "Protein", current: totals.protein, target: targets.protein, unit: "g", color: .blue, mode: mode)
            MacroBar(label: "Carbs", current: totals.carbs, target: targets.carbs, unit: "g", color: .green, mode: mode)
            MacroBar(label: "Fat", current: totals.fat, target: targets.fat, unit: "g", color: .purple, mode: mode)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MacroBar: View {
    let label: String
    let current: Double
    let target: Double
    let unit: String
    let color: Color
    let mode: MacroDisplayMode

    private var progress: Double {
        MacroCalculator.progress(current: current, target: target)
    }

    private var detailText: String {
        switch mode {
        case .remaining:
            let remaining = MacroCalculator.remaining(current: current, target: target)
            return String(format: "%.0f %@ left", remaining, unit)
        case .percent:
            return String(format: "%.0f%%", MacroCalculator.percentComplete(current: current, target: target))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * min(progress, 1))
                }
            }
            .frame(height: 8)
            Text("\(Int(current)) / \(Int(target)) \(unit)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct WeeklyBudgetBar: View {
    let consumed: Double
    let cap: Double
    var weekLabel: String? = nil

    private var progress: Double {
        guard cap > 0 else { return 0 }
        return min(consumed / cap, 1.5)
    }

    private var percentComplete: Int {
        guard cap > 0 else { return 0 }
        return Int((consumed / cap) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Weekly Calories")
                    .font(.subheadline.weight(.medium))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(percentComplete)% of target")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(consumed > cap ? .red : .primary)
                    Text("\(Int(max(cap - consumed, 0))) left this week")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let weekLabel {
                Text(weekLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(consumed > cap ? .red : .teal)
                        .frame(width: geo.size.width * min(progress, 1))
                }
            }
            .frame(height: 8)
            Text("\(Int(consumed)) / \(Int(cap)) kcal")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct WeeklyStepsBar: View {
    let steps: Int
    let cap: Int
    var weekLabel: String? = nil

    private var progress: Double {
        guard cap > 0 else { return 0 }
        return min(Double(steps) / Double(cap), 1.5)
    }

    private var percentComplete: Int {
        guard cap > 0 else { return 0 }
        return Int((Double(steps) / Double(cap)) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Weekly Steps")
                    .font(.subheadline.weight(.medium))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(percentComplete)% of target")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(steps >= cap ? .green : .primary)
                    Text("\(max(cap - steps, 0)) left this week")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let weekLabel {
                Text(weekLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(steps >= cap ? .green : .blue)
                        .frame(width: geo.size.width * min(progress, 1))
                }
            }
            .frame(height: 8)
            Text("\(steps) / \(cap)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct StepProgressBar: View {
    let steps: Int
    let target: Int

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(Double(steps) / Double(target), 1.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Steps", systemImage: "figure.walk")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(max(target - steps, 0)) left today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(steps >= target ? .green : .blue)
                        .frame(width: geo.size.width * min(progress, 1))
                }
            }
            .frame(height: 8)
            Text("\(steps) / \(target)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct GoalProgressCard: View {
    let goal: WeightGoal
    let metrics: GoalMetrics
    let currentWeight: Double
    var onEdit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weight Goal")
                    .font(.headline)
                Spacer()
                if let onEdit {
                    Button("Edit", action: onEdit)
                        .font(.subheadline)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weight progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: metrics.progressPercent, total: 100)
                    Text("\(metrics.progressPercent.formatted(.number.precision(.fractionLength(1))))%")
                        .font(.caption2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Time elapsed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: metrics.timePercent, total: 100)
                    Text("\(metrics.timePercent.formatted(.number.precision(.fractionLength(1))))%")
                        .font(.caption2)
                }
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("Current")
                    Text("\(currentWeight.formatted(.number.precision(.fractionLength(1)))) lbs")
                        .fontWeight(.semibold)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Goal")
                    Text("\(goal.goalWeightLbs.formatted(.number.precision(.fractionLength(1)))) lbs")
                        .fontWeight(.semibold)
                }
            }
            if let weekly = metrics.weeklyChangeLbs {
                Text("Weekly change: \(weekly.formatted(.number.precision(.fractionLength(2)))) lbs/week")
                    .font(.caption)
            }
            if let pct = metrics.weeklyPercentBodyWeight {
                Text("Weekly % body weight: \(pct.formatted(.number.precision(.fractionLength(2))))%")
                    .font(.caption)
            }
            if let finish = metrics.projectedFinishDate {
                Text("Est. finish: \(finish.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Started: \(goal.startDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Target date: \(goal.targetDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
