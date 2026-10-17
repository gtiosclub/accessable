#if DEBUG
import SwiftUI

/// Developer screen listing the permission and the latest Core Location readings.
struct LocationDebugView: View {
    @State private var viewModel: LocationDebugViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: LocationDebugViewModel(services: services))
    }

    var body: some View {
        List {
            Section("Permission") {
                FieldRow(field: viewModel.permissionField)
            }

            Section("Latest reading") {
                FieldRow(field: viewModel.countField)
                if let sample = viewModel.latestSample {
                    // the age grows between readings, so it redraws on its own
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        FieldRow(field: viewModel.ageField(at: context.date))
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    ForEach(LocationDebugViewModel.fields(of: sample)) { FieldRow(field: $0) }
                } else {
                    Text("No readings yet")
                }
            }

            Section("Earlier readings") {
                // the newest is already under Latest reading; samples can repeat, so their position is the identity
                ForEach(Array(viewModel.recentSamples.dropFirst().enumerated()), id: \.offset) { _, sample in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(LocationDebugViewModel.fields(of: sample)) { FieldRow(field: $0) }
                    }
                    // one swipe per reading instead of one per field
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(LocationDebugViewModel.spokenSummary(of: sample))
                }
            }
        }
        .navigationTitle("Location readings")
        .task { await viewModel.start() }
    }
}

/// Reads as "label, value" with units spelled out.
private struct FieldRow: View {
    let field: LocationDebugViewModel.Field

    var body: some View {
        LabeledContent(field.label, value: field.value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(field.label)
            .accessibilityValue(field.spokenValue)
    }
}

#Preview {
    var services = AppServices.preview
    services.location = PlaceholderLocationProvider()
    return NavigationStack {
        LocationDebugView(services: services)
    }
}
#endif
