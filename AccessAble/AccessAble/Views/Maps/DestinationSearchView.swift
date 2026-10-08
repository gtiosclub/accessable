import MapKit
import SwiftUI

struct DestinationSearchView: View {
    @State private var viewModel = DestinationSearchViewModel()

    var body: some View {
        List {
            if let place = viewModel.selectedPlace {
                Section("Selected") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name ?? "Unnamed place")
                            .font(.headline)
                        Text(coordinateText(place.location.coordinate))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section {
                ForEach(viewModel.suggestions) { suggestion in
                    Button {
                        viewModel.select(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggestion.title)
                                .font(.headline)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                    .accessibilityHint("Selects this destination")
                }
            }
        }
        .searchable(
            text: $viewModel.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search for a place or address"
        )
        .onChange(of: viewModel.query) { viewModel.queryChanged() }
        .navigationTitle("Destination")
    }

    private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(coordinate.latitude.formatted(format)), \(coordinate.longitude.formatted(format))"
    }
}

#Preview {
    NavigationStack {
        DestinationSearchView()
    }
}
