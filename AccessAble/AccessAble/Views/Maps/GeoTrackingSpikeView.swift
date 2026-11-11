#if DEBUG
import SwiftUI

/// AR-1 spike screen: device support, campus availability, and a live geo-tracking session logged to a CSV.
struct GeoTrackingSpikeView: View {
    @State private var viewModel = GeoTrackingSpikeViewModel()

    var body: some View {
        List {
            Section {
                HStack {
                    Button("Geo-tracking") { viewModel.start(.geo) }
                    Spacer()
                    Button("Switch test") { viewModel.start(.switchTest) }
                    Spacer()
                    Button("Stop", role: .destructive) { viewModel.stop() }
                        .disabled(viewModel.mode == .stopped)
                }
                .buttonStyle(.borderless)
                HStack {
                    TextField("Mark label, e.g. Tech Walkway", text: $viewModel.markLabel)
                    Button("Mark") { viewModel.mark() }
                        .disabled(viewModel.mode == .stopped)
                }
                if let url = viewModel.logURL {
                    ShareLink(item: url) { Label("Share log (\(viewModel.rowCount) rows)", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text("Hold the phone up facing buildings. Switch test runs world tracking like the camera screen, then switches to geo-tracking.")
            }

            rows("Session", viewModel.sessionRows)
            Section("Switch test") { Text(viewModel.switchResult) }
            rows("Availability", viewModel.availabilityRows)
            Section {
                Button("Check availability") { Task { await viewModel.checkAvailability() } }
            }
            rows("Device support", viewModel.supportRows)
        }
        .navigationTitle("Geo tracking spike")
        .onDisappear { viewModel.stop() }
        .task { await viewModel.checkAvailability() }
    }

    @ViewBuilder
    private func rows(_ title: String, _ rows: [GeoTrackingSpikeViewModel.Row]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { LabeledContent($0.label, value: $0.value) }
            }
        }
    }
}
#endif
