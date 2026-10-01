import SwiftUI

struct SwimSegmentsEditor: View {
    @Binding var unit: SwimDistanceUnit
    @Binding var segments: [SwimSegmentDraft]

    private var totalDistance: Double {
        segments.reduce(0) { $0 + $1.distance }
    }

    var body: some View {
        Group {
            Section("Distance") {
                Picker("Unit", selection: $unit) {
                    ForEach(SwimDistanceUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
            }

            Section {
                ForEach($segments) { $segment in
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Stroke", selection: $segment.stroke) {
                            ForEach(SwimStroke.allCases) { stroke in
                                Text(stroke.displayName).tag(stroke)
                            }
                        }
                        HStack {
                            Text("Distance")
                            DecimalPadTextField(text: $segment.distanceText, placeholder: "0")
                        }
                    }
                }
                .onDelete { offsets in
                    segments.remove(atOffsets: offsets)
                    if segments.isEmpty {
                        segments = [SwimSegmentDraft()]
                    }
                }

                Button {
                    segments.append(SwimSegmentDraft())
                } label: {
                    Label("Add Stroke", systemImage: "plus")
                }
            } header: {
                Text("Strokes")
            } footer: {
                if totalDistance > 0 {
                    Text("\(unit.format(totalDistance)). Calories use each stroke’s effort and split your clock time by typical pace.")
                } else {
                    Text("Enter a distance for each stroke. Calories still use duration if you leave distance blank.")
                }
            }
        }
    }
}
