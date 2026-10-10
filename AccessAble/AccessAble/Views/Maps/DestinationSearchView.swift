import SwiftUI

struct DestinationSearchView: View {
    @State private var viewModel: DestinationSearchViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: DestinationSearchViewModel(services: services))
    }

    var body: some View {
        List {
            if let destination = viewModel.selectedDestination {
                Section("Selected") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(destination.name)
                            .font(.headline)
                        if let address = destination.address {
                            Text(address)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(coordinateText(destination.coordinate))
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
        .task { await viewModel.start() }
    }

    // 5 decimal places ≈ 1 m precision
    private func coordinateText(_ coordinate: GeoCoordinate) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(coordinate.latitude.formatted(format)), \(coordinate.longitude.formatted(format))"
    }
}

#Preview {
    var services = AppServices.preview
    services.destinationSearch = PlaceholderDestinationSearch()
    return NavigationStack {
        DestinationSearchView(services: services)
    }
}
