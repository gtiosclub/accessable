import SwiftUI

struct DestinationSearchView: View {
    @State private var viewModel: DestinationSearchViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: DestinationSearchViewModel(services: services))
    }

    var body: some View {
        List {
            if let problem = viewModel.problem {
                Section {
                    problemView(problem)
                }
            }

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
                if viewModel.isSearching && viewModel.suggestions.isEmpty {
                    HStack(spacing: 12) {
                        // new identity per query; List can redisplay a reused spinner as blank
                        ProgressView()
                            .id(viewModel.trimmedQuery)
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(viewModel.suggestions) { suggestion in
                    Button {
                        viewModel.select(suggestion)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion.title)
                                    .font(.headline)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if suggestion.id == viewModel.selectedSuggestionID {
                                if viewModel.isResolving {
                                    ProgressView()
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .minimumTapTarget()
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
        // autocorrect rewrites place names like "Ferst" into real words
        .autocorrectionDisabled()
        .onChange(of: viewModel.query) { viewModel.queryChanged() }
        .navigationTitle("Destination")
        .overlay {
            if viewModel.showsNoResults {
                ContentUnavailableView.search(text: viewModel.trimmedQuery)
            }
        }
        .task { await viewModel.start() }
    }

    @ViewBuilder
    private func problemView(_ problem: SearchProblem) -> some View {
        switch problem {
        case .suggestionsUnavailable:
            Label("Couldn't load suggestions. Check your connection and keep typing.", systemImage: "wifi.exclamationmark")
        case .lookupFailed(let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't get details for \(suggestion.title).", systemImage: "exclamationmark.triangle")
                Button("Try again") { viewModel.select(suggestion) }
                    .minimumTapTarget()
            }
        }
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
