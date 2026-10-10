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
                    // raw coordinates aren't useful read aloud
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(selectedLabel(destination))
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
                    .accessibilityElement(children: .combine)
                }
                ForEach(viewModel.suggestions) { suggestion in
                    let isSelected = suggestion.id == viewModel.selectedSuggestionID
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
                            if isSelected {
                                Group {
                                    if viewModel.isResolving {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                    }
                                }
                                .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .minimumTapTarget()
                    }
                    .tint(.primary)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue(isSelected && viewModel.isResolving ? "Loading details" : "")
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
        // VoiceOver doesn't read changes outside the focused row, so say them out loud
        .onChange(of: viewModel.selectedDestination) { _, destination in
            guard let destination else { return }
            AccessibilityNotification.Announcement(selectedLabel(destination)).post()
        }
        .onChange(of: viewModel.problem) { _, problem in
            guard let problem else { return }
            AccessibilityNotification.Announcement(problemMessage(problem)).post()
        }
        .task { await viewModel.start() }
    }

    @ViewBuilder
    private func problemView(_ problem: SearchProblem) -> some View {
        switch problem {
        case .suggestionsUnavailable:
            Label(problemMessage(problem), systemImage: "wifi.exclamationmark")
        case .lookupFailed(let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                Label(problemMessage(problem), systemImage: "exclamationmark.triangle")
                Button("Try again") { viewModel.select(suggestion) }
                    .minimumTapTarget()
                    .accessibilityHint("Looks up \(suggestion.title) again")
            }
        }
    }

    private func problemMessage(_ problem: SearchProblem) -> String {
        switch problem {
        case .suggestionsUnavailable:
            "Couldn't load suggestions. Check your connection and keep typing."
        case .lookupFailed(let suggestion):
            "Couldn't get details for \(suggestion.title)."
        }
    }

    private func selectedLabel(_ destination: Destination) -> String {
        ["Selected destination: \(destination.name)", destination.address]
            .compactMap { $0 }
            .joined(separator: ", ")
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
