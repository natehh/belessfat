import SwiftUI

struct SwimSegmentsEditor: View {
    @Binding var poolLength: PoolLength
    @Binding var segments: [SwimSegmentDraft]

    private var totalLengths: Int {
        segments.reduce(0) { $0 + Int($1.lengths) }
    }

    var body: some View {
        Group {
        Section("Pool") {
            Picker("Length", selection: $poolLength) {
                ForEach(PoolLength.allCases) { length in
                    Text(length.displayName).tag(length)
                }
            }
            .pickerStyle(.segmented)
        }

        Section {
            ForEach($segments) { $segment in
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Stroke", selection: $segment.stroke) {
                        ForEach(SwimStroke.allCases) { stroke in
                            Text(stroke.displayName).tag(stroke)
                        }
                    }
                    NumericStepperField(
                        title: "Lengths",
                        value: $segment.lengths,
                        range: 0...500,
                        step: 1,
                        format: "%.0f"
                    )
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
            if totalLengths > 0 {
                Text("\(totalLengths) lengths · \(poolLength.distanceLabel(lengths: totalLengths)). Calories use each stroke’s effort and split your clock time by typical pace.")
            } else {
                Text("Log lengths per stroke so mixed sets stay on the record. Calories still use duration if you leave lengths at 0.")
            }
        }
        }
    }
}
