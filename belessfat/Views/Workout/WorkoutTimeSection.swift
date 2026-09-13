import SwiftUI

struct WorkoutTimeSection: View {
    @Binding var workoutEndAt: Date
    let durationMinutes: Double
    let syncToHealthKit: Bool
    let includesSteps: Bool

    var body: some View {
        Section {
            DatePicker("End Time", selection: $workoutEndAt, displayedComponents: [.date, .hourAndMinute])
            LabeledContent("Start Time") {
                Text(startTime, format: .dateTime.hour().minute())
                    .foregroundStyle(.secondary)
            }
            if syncToHealthKit && includesSteps {
                Text("Steps are written to HealthKit for the \(Int(durationMinutes)) minutes before this time. Set the end time to when the workout finished so it doesn't overlap with steps your phone is counting now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if syncToHealthKit {
                Text("Calories are written to HealthKit for the \(Int(durationMinutes)) minutes before this end time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Workout Time")
        }
    }

    private var startTime: Date {
        workoutEndAt.addingTimeInterval(-durationMinutes * 60)
    }
}
