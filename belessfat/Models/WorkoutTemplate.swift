import Foundation
import SwiftData

@Model
final class WorkoutTemplate {
    var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \WorkoutTemplateExercise.template)
    var exercises: [WorkoutTemplateExercise]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.exercises = []
    }

    var sortedExercises: [WorkoutTemplateExercise] {
        exercises.sorted { $0.sortOrder < $1.sortOrder }
    }
}

@Model
final class WorkoutTemplateExercise {
    var id: UUID
    var sortOrder: Int
    var exercise: Exercise?
    var template: WorkoutTemplate?

    init(exercise: Exercise, sortOrder: Int) {
        self.id = UUID()
        self.exercise = exercise
        self.sortOrder = sortOrder
    }
}
